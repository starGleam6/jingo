/**
 * @file JinGoCore.mm
 * @brief JinGoCore - Standalone core service with Xray + TUN + routing
 * @details setuid root executable that runs as an independent process.
 *          The JinGo GUI app launches and controls this via stdin/stdout IPC.
 *
 *          Architecture (similar to FlClash's FlClashCore):
 *          - JinGoCore: root-privileged process managing Xray/TUN/routes/DNS
 *          - JinGo: unprivileged GUI app controlling JinGoCore via IPC
 *
 * Commands (read from stdin as single-line JSON):
 *   {"action":"start",    "config":"<xray JSON>", "serverAddr":"1.2.3.4:443"}
 *   {"action":"stop"}
 *   {"action":"status"}
 *   {"action":"version"}
 *   {"action":"stats"}
 *   {"action":"quit"}
 */

#import <Foundation/Foundation.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>
#include <signal.h>
#include <sys/stat.h>

#include <fcntl.h>

#include "superray.h"

static int g_debugFd = -1;

static void debugLog(const char* fmt, ...) {
    if (g_debugFd < 0) return;
    char buf[4096];
    va_list args;
    va_start(args, fmt);
    int len = vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    if (len > 0) write(g_debugFd, buf, len);
}

static bool g_running = true;
static bool g_xrayRunning = false;
static bool g_tunRunning = false;
static std::string g_instanceID;
static std::string g_tunHandle;
static std::string g_lastError;

// 排除路由：保存 TUN 启动前的原始网关和接口
static std::string g_originalGateway;
static std::string g_originalInterface;

// 验证 IP 地址格式（仅允许数字和点号，防止命令注入）
static bool isValidIPv4(const std::string& s) {
    if (s.empty() || s.size() > 15) return false;
    for (char c : s) {
        if (c != '.' && (c < '0' || c > '9')) return false;
    }
    return true;
}

// 验证网络接口名（仅允许字母数字，防止命令注入）
static bool isValidInterfaceName(const std::string& s) {
    if (s.empty() || s.size() > 16) return false;
    for (char c : s) {
        if (!isalnum(c)) return false;
    }
    return true;
}

// 需要排除的国内 DNS 服务器
static const char* g_bypassHosts[] = {
    "223.5.5.5",     // AliDNS
    "223.6.6.6",     // AliDNS
    "119.29.29.29",  // DNSPod
    nullptr
};

// 检测原始默认网关和接口（必须在 TUN 启动前调用）
static void detectOriginalGateway() {
    g_originalGateway.clear();
    g_originalInterface.clear();

    FILE* pipe = popen("route -n get default 2>/dev/null", "r");
    if (!pipe) return;

    char buf[256];
    while (fgets(buf, sizeof(buf), pipe)) {
        std::string line(buf);
        auto gwPos = line.find("gateway:");
        if (gwPos != std::string::npos) {
            gwPos += 8;
            while (gwPos < line.size() && line[gwPos] == ' ') gwPos++;
            while (gwPos < line.size() && line[gwPos] != '\n' && line[gwPos] != ' ')
                g_originalGateway += line[gwPos++];
        }
        auto ifPos = line.find("interface:");
        if (ifPos != std::string::npos) {
            ifPos += 10;
            while (ifPos < line.size() && line[ifPos] == ' ') ifPos++;
            while (ifPos < line.size() && line[ifPos] != '\n' && line[ifPos] != ' ')
                g_originalInterface += line[ifPos++];
        }
    }
    pclose(pipe);
    debugLog("[JinGoCore] Original gateway: %s, interface: %s\n",
             g_originalGateway.c_str(), g_originalInterface.c_str());
}

// 添加排除路由（TUN 启动后调用）
static void addBypassRoutes(const std::string& serverAddr) {
    if (g_originalGateway.empty()) return;

    // 提取服务器 IP（去掉端口）
    std::string serverIP = serverAddr;
    auto colonPos = serverIP.find(':');
    if (colonPos != std::string::npos)
        serverIP = serverIP.substr(0, colonPos);

    // 添加 VPN 服务器排除路由（验证 IP 格式防止命令注入）
    if (!serverIP.empty() && isValidIPv4(serverIP) && isValidIPv4(g_originalGateway)) {
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "route add -host %s %s >/dev/null 2>&1",
                 serverIP.c_str(), g_originalGateway.c_str());
        debugLog("[JinGoCore] Bypass route: %s\n", cmd);
        system(cmd);
    }

    // 添加国内 DNS 排除路由
    for (int i = 0; g_bypassHosts[i]; i++) {
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "route add -host %s %s >/dev/null 2>&1",
                 g_bypassHosts[i], g_originalGateway.c_str());
        debugLog("[JinGoCore] Bypass route: %s\n", cmd);
        system(cmd);
    }

    // 添加 interface-scoped default 路由，使 IP_BOUND_IF 生效
    // SuperRay_TUNStart 添加的 0/1 + 128.0/1 是全局路由，会覆盖 en0 的 default 路由，
    // 导致 freedom outbound 的 sockopt.interface (IP_BOUND_IF) 无法将流量路由到物理网卡。
    // 添加 -ifscope en0 的 default 路由后，IP_BOUND_IF=en0 的 socket 可以匹配到这条
    // scoped 路由，绕过 TUN 的全局路由，直连国内流量。
    if (!g_originalInterface.empty() && isValidInterfaceName(g_originalInterface) && isValidIPv4(g_originalGateway)) {
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "route add -ifscope %s default %s >/dev/null 2>&1",
                 g_originalInterface.c_str(), g_originalGateway.c_str());
        debugLog("[JinGoCore] Scoped default route: %s\n", cmd);
        system(cmd);
    }
}

// 清理排除路由
static void removeBypassRoutes() {
    for (int i = 0; g_bypassHosts[i]; i++) {
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "route delete -host %s >/dev/null 2>&1", g_bypassHosts[i]);
        system(cmd);
    }
    // 清理 scoped default 路由
    if (!g_originalInterface.empty() && isValidInterfaceName(g_originalInterface)) {
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "route delete -ifscope %s default >/dev/null 2>&1",
                 g_originalInterface.c_str());
        system(cmd);
    }
    // 不需要删除 VPN 服务器路由，TUN stop 会自动清理
}

static void signalHandler(int) {
    g_running = false;
}

// 转义 JSON 字符串中的特殊字符
static std::string escapeJsonString(const char* str) {
    if (!str) return "unknown";
    std::string result;
    for (const char* p = str; *p; ++p) {
        switch (*p) {
            case '"':  result += "\\\""; break;
            case '\\': result += "\\\\"; break;
            case '\n': result += "\\n"; break;
            case '\r': result += "\\r"; break;
            case '\t': result += "\\t"; break;
            default:   result += *p; break;
        }
    }
    return result;
}

static void respond(bool success, const char* data = nullptr, const char* error = nullptr) {
    if (success) {
        if (data)
            printf("{\"success\":true,\"data\":%s}\n", data);
        else
            printf("{\"success\":true}\n");
    } else {
        std::string escaped = escapeJsonString(error);
        printf("{\"success\":false,\"error\":\"%s\"}\n", escaped.c_str());
    }
    fflush(stdout);
}

// Simple JSON field extractor
static std::string jsonGetString(const std::string& json, const std::string& key) {
    std::string search = "\"" + key + "\":\"";
    auto pos = json.find(search);
    if (pos == std::string::npos) return "";
    pos += search.size();
    auto end = json.find('"', pos);
    if (end == std::string::npos) return "";
    return json.substr(pos, end - pos);
}

// Extract a possibly large JSON value (for "config" field that contains nested JSON)
static std::string jsonGetValue(const std::string& json, const std::string& key) {
    std::string search = "\"" + key + "\":";
    auto pos = json.find(search);
    if (pos == std::string::npos) return "";
    pos += search.size();

    // Skip whitespace
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t'))
        pos++;

    if (pos >= json.size()) return "";

    // If it starts with quote, extract string (with proper JSON unescape)
    if (json[pos] == '"') {
        pos++;
        std::string result;
        while (pos < json.size() && json[pos] != '"') {
            if (json[pos] == '\\' && pos + 1 < json.size()) {
                char esc = json[pos + 1];
                switch (esc) {
                    case 'n':  result += '\n'; break;
                    case 't':  result += '\t'; break;
                    case 'r':  result += '\r'; break;
                    case '\\': result += '\\'; break;
                    case '"':  result += '"';  break;
                    case '/':  result += '/';  break;
                    default:   result += esc;  break;
                }
                pos += 2;
            } else {
                result += json[pos];
                pos++;
            }
        }
        return result;
    }

    // If it starts with {, find matching }
    if (json[pos] == '{') {
        int depth = 0;
        size_t start = pos;
        while (pos < json.size()) {
            if (json[pos] == '{') depth++;
            else if (json[pos] == '}') { depth--; if (depth == 0) { pos++; break; } }
            else if (json[pos] == '"') {
                pos++;
                while (pos < json.size() && json[pos] != '"') {
                    if (json[pos] == '\\') pos++;
                    pos++;
                }
            }
            pos++;
        }
        return json.substr(start, pos - start);
    }

    return "";
}

static void stopAll() {
    // 清理排除路由
    removeBypassRoutes();

    if (g_tunRunning && !g_tunHandle.empty()) {
        char* result = SuperRay_TUNStop(g_tunHandle.c_str());
        if (result) SuperRay_Free(result);
        result = SuperRay_TUNDestroy(g_tunHandle.c_str());
        if (result) SuperRay_Free(result);
        g_tunRunning = false;
        g_tunHandle.clear();
    }

    if (g_xrayRunning) {
        char* result = SuperRay_StopAll();
        if (result) SuperRay_Free(result);
        g_xrayRunning = false;
        g_instanceID.clear();
    }
}

static bool startCore(const std::string& xrayConfig, const std::string& serverAddr) {
    // Stop existing if running
    stopAll();

    // Strip all newlines and tabs from config
    std::string cleanConfig;
    cleanConfig.reserve(xrayConfig.size());
    for (char c : xrayConfig) {
        if (c != '\n' && c != '\r' && c != '\t')
            cleanConfig += c;
    }

    @autoreleasepool {
        // Set asset directory for geo files
        // NSBundle mainBundle for a helper executable returns the parent app bundle,
        // so resourcePath should be Contents/Resources
        NSString* bundlePath = [[NSBundle mainBundle] resourcePath];
        debugLog( "[JinGoCore] resourcePath: %s\n", bundlePath ? [bundlePath UTF8String] : "(null)");

        // Verify geo files exist
        NSString* geoipPath = [bundlePath stringByAppendingPathComponent:@"dat/geoip.dat"];
        NSString* geositePath = [bundlePath stringByAppendingPathComponent:@"dat/geosite.dat"];
        BOOL geoipExists = [[NSFileManager defaultManager] fileExistsAtPath:geoipPath];
        BOOL geositeExists = [[NSFileManager defaultManager] fileExistsAtPath:geositePath];
        debugLog( "[JinGoCore] geoip.dat exists: %s, geosite.dat exists: %s\n",
                geoipExists ? "YES" : "NO", geositeExists ? "YES" : "NO");

        // If geo files not found in resourcePath, try dat subdirectory or parent Resources
        if (!geoipExists) {
            // Try Contents/Resources/dat/ explicitly
            NSString* execPath = [[NSBundle mainBundle] executablePath];
            NSString* macosDir = [execPath stringByDeletingLastPathComponent];
            NSString* contentsDir = [macosDir stringByDeletingLastPathComponent];
            NSString* altResourcePath = [contentsDir stringByAppendingPathComponent:@"Resources"];
            NSString* altGeoipPath = [altResourcePath stringByAppendingPathComponent:@"dat/geoip.dat"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:altGeoipPath]) {
                bundlePath = altResourcePath;
                debugLog( "[JinGoCore] Using alternative resourcePath: %s\n", [bundlePath UTF8String]);
            }
        }

        if (bundlePath) {
            NSString* datPath = [bundlePath stringByAppendingPathComponent:@"dat"];
            char* result = SuperRay_SetAssetDir([datPath UTF8String]);
            debugLog( "[JinGoCore] SetAssetDir result: %s\n", result ? result : "(null)");
            if (result) SuperRay_Free(result);
        }

        // Detect and bind to default interface to prevent routing loops
        char* ifResult = SuperRay_DetectInterfaces();
        if (ifResult) {
            // Parse default_interface from result
            NSString* jsonStr = [NSString stringWithUTF8String:ifResult];
            NSData* jsonData = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary* parsed = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
            NSString* defaultIf = parsed[@"data"][@"default_interface"];
            if (defaultIf) {
                char* bindResult = SuperRay_SetBindInterface([defaultIf UTF8String]);
                if (bindResult) SuperRay_Free(bindResult);
            }
            SuperRay_Free(ifResult);
        }

        // Start Xray
        // Redirect stdout to stderr to prevent Xray warnings from polluting IPC
        fflush(stdout);
        int savedStdout = dup(STDOUT_FILENO);
        dup2(STDERR_FILENO, STDOUT_FILENO);

        char* runResult = SuperRay_Run(cleanConfig.c_str());

        // Restore stdout
        fflush(stdout);
        dup2(savedStdout, STDOUT_FILENO);
        close(savedStdout);

        if (!runResult) {
            g_lastError = "SuperRay_Run returned NULL";
            return false;
        }

        // Save full response for error reporting
        std::string runResultStr(runResult);

        NSString* runJson = [NSString stringWithUTF8String:runResult];
        NSData* runData = [runJson dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary* runParsed = [NSJSONSerialization JSONObjectWithData:runData options:0 error:nil];
        SuperRay_Free(runResult);

        if (![runParsed[@"success"] boolValue]) {
            NSString* errorMsg = runParsed[@"error"];
            g_lastError = "SuperRay_Run failed: ";
            g_lastError += runResultStr;
            return false;
        }

        g_instanceID = [runParsed[@"data"][@"id"] UTF8String] ?: "";
        g_xrayRunning = true;

        // 在 TUN 启动前检测原始网关（之后要用来添加排除路由）
        detectOriginalGateway();

        // Create and start TUN
        debugLog( "[JinGoCore] Creating TUN for instance: %s\n", g_instanceID.c_str());
        char* tunResult = SuperRay_TUNCreate(g_instanceID.c_str());
        if (!tunResult) {
            debugLog( "[JinGoCore] TUNCreate returned NULL\n");
            return true; // Xray running but no TUN
        }

        debugLog( "[JinGoCore] TUNCreate result: %s\n", tunResult);
        NSString* tunJson = [NSString stringWithUTF8String:tunResult];
        NSData* tunData = [tunJson dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary* tunParsed = [NSJSONSerialization JSONObjectWithData:tunData options:0 error:nil];
        SuperRay_Free(tunResult);

        if ([tunParsed[@"success"] boolValue]) {
            g_tunHandle = g_instanceID;

            debugLog( "[JinGoCore] Starting TUN: server=%s\n", serverAddr.c_str());
            char* startResult = SuperRay_TUNStart(
                g_tunHandle.c_str(),
                serverAddr.c_str(),
                "10.255.0.1/24",  // TUN address
                "8.8.8.8:53",     // DNS
                1500              // MTU
            );
            if (startResult) {
                debugLog( "[JinGoCore] TUNStart result: %s\n", startResult);
                NSString* startJson = [NSString stringWithUTF8String:startResult];
                NSData* startData = [startJson dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary* startParsed = [NSJSONSerialization JSONObjectWithData:startData options:0 error:nil];
                SuperRay_Free(startResult);
                g_tunRunning = [startParsed[@"success"] boolValue];
                // TUN 启动成功后添加排除路由（国内 DNS + VPN 服务器）
                if (g_tunRunning) {
                    addBypassRoutes(serverAddr);
                }
            } else {
                debugLog( "[JinGoCore] TUNStart returned NULL\n");
            }
        } else {
            debugLog( "[JinGoCore] TUNCreate failed: %s\n", [tunJson UTF8String]);
        }
    }

    return true;
}

int main(int argc, char* argv[]) {
    if (argc > 1 && strcmp(argv[1], "--version") == 0) {
        char* ver = SuperRay_Version();
        if (ver) {
            printf("JinGoCore 1.0 (SuperRay %s)\n", ver);
            SuperRay_Free(ver);
        } else {
            printf("JinGoCore 1.0\n");
        }
        return 0;
    }

    signal(SIGINT, signalHandler);
    signal(SIGTERM, signalHandler);

    // Open debug log with POSIX write (no buffering, won't lose on kill)
    g_debugFd = open("/tmp/jingocore_debug.log", O_WRONLY | O_CREAT | O_APPEND, 0666);
    debugLog("[JinGoCore] Started, pid=%d, euid=%d\n", getpid(), geteuid());

    // Verify root privileges
    if (geteuid() != 0) {
        debugLog( "JinGoCore must run as root (setuid)\n");
        return 1;
    }

    // 将 real uid 也设为 0，否则 system() 调用的 /bin/sh 会降权
    // （macOS 的 shell 检测到 euid != uid 时会主动放弃 setuid 权限）
    setuid(0);

    // Set umask to 0 so that log files created by SuperRay are world-writable (0666)
    // This prevents permission conflicts when switching between TUN mode (root)
    // and Proxy mode (normal user)
    umask(0);

    char line[65536];
    while (g_running && fgets(line, sizeof(line), stdin)) {
        std::string input(line);
        if (!input.empty() && input.back() == '\n')
            input.pop_back();
        if (input.empty())
            continue;

        std::string action = jsonGetString(input, "action");
        debugLog("[JinGoCore] action=%s, input size=%zu\n", action.c_str(), input.size());

        if (action == "start") {
            std::string config = jsonGetValue(input, "config");
            debugLog("[JinGoCore] config size=%zu, config:\n%s\n", config.size(), config.c_str());
            std::string serverAddr = jsonGetString(input, "serverAddr");
            if (config.empty()) {
                respond(false, nullptr, "missing config");
            } else {
                bool ok = startCore(config, serverAddr);
                if (ok) {
                    std::string data = "{\"xray\":true,\"tun\":" +
                        std::string(g_tunRunning ? "true" : "false") + "}";
                    respond(true, data.c_str());
                } else {
                    respond(false, nullptr, g_lastError.c_str());
                }
            }
        } else if (action == "stop") {
            stopAll();
            respond(true);
        } else if (action == "status") {
            char data[256];
            snprintf(data, sizeof(data),
                "{\"xray\":%s,\"tun\":%s}",
                g_xrayRunning ? "true" : "false",
                g_tunRunning ? "true" : "false");
            respond(true, data);
        } else if (action == "version") {
            char* ver = SuperRay_Version();
            char data[128];
            snprintf(data, sizeof(data), "{\"version\":\"%s\"}", ver ? ver : "unknown");
            if (ver) SuperRay_Free(ver);
            respond(true, data);
        } else if (action == "stats") {
            @autoreleasepool {
                // 缓存统计数据，避免每次 IPC 请求都调用 SuperRay_GetXrayStats() CGo
                // 原因：CGo 调用会短暂锁定 Go 运行时调度器，频繁调用可能干扰 TUN 数据包处理 goroutine
                // 策略：每 3 秒刷新一次缓存，其余请求返回缓存值
                static std::string cachedStatsJson;
                static time_t lastStatsRefreshTime = 0;

                time_t now = time(nullptr);
                if (cachedStatsJson.empty() || now - lastStatsRefreshTime >= 3) {
                    char* stats = SuperRay_GetXrayStats();
                    if (stats) {
                        cachedStatsJson = stats;
                        SuperRay_Free(stats);
                    }
                    lastStatsRefreshTime = now;
                }

                if (!cachedStatsJson.empty()) {
                    printf("%s\n", cachedStatsJson.c_str());
                    fflush(stdout);
                } else {
                    respond(false, nullptr, "no stats available");
                }
            }
        } else if (action == "quit") {
            stopAll();
            respond(true);
            break;
        } else {
            respond(false, nullptr, "unknown action");
        }
    }

    stopAll();
    return 0;
}
