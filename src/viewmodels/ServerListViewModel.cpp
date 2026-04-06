/**
 * @file ServerListViewModel.cpp
 * @brief 服务器列表视图模型实现文件
 * @details 实现服务器列表的管理、筛选、排序和连接功能
 * @author JinGo VPN Team
 * @date 2025
 */

#include "ServerListViewModel.h"
#include "ServerListModel.h"
#include "panel/SubscriptionManager.h"
#include "core/VPNManager.h"
#include "core/XrayCBridge.h"
#include "core/ConfigManager.h"
#include "core/BundleConfig.h"
#include "core/Logger.h"
#include "utils/CountryUtils.h"
#include <QTimer>
#include <QTcpSocket>
#include <QElapsedTimer>
#include <QtConcurrent>
#include <QPointer>
#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QJsonParseError>
#include <QDateTime>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <memory>  // for std::shared_ptr
#include <QNetworkRequest>
#include <QUrl>
#include <algorithm>
#include <functional>
#include <cstdio>

// macOS/iOS: 延时测试桥接函数声明（实现在 VPNManagerHelper.mm）
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
extern void testServerLatencyViaExtension(const QString& address, int timeout, std::function<void(int)> callback);
#endif

// Android: 使用被保护的 socket 绕过 VPN 测试真正的延时
#ifdef Q_OS_ANDROID
extern "C" int Android_ProtectedTcpPing(const char* host, int port, int timeout_ms);
#endif

// 批量延迟测试（直接使用 SuperRay C API，符号由 libJinDoCore.a 提供）
extern "C" {
    char* SuperRay_BatchLatencyTest(const char* serversJSON, int concurrent, int count, int timeoutMs);
    char* SuperRay_BatchProxyLatencyTest(const char* serversJSON, int concurrent, int timeoutMs);
    void SuperRay_Free(char* ptr);
}

/**
 * @brief 构造函数
 * @param parent 父对象
 *
 * @details 初始化视图模型：
 * - 设置成员变量初始值
 * - 获取订阅管理器和VPN管理器的单例引用
 * - 从数据库加载已有的服务器列表
 *
 * @note 不自动连接订阅更新信号，避免死循环
 * @see loadServersFromManager()
 */
ServerListViewModel::ServerListViewModel(QObject* parent)
    : QObject(parent)
    , m_serverModel(new ServerListModel(this))  // 创建增量更新模型
    , m_selectedServer(nullptr)  // QPointer会自动初始化为nullptr
    , m_isLoading(false)
    , m_isUpdating(false)
    , m_isBatchTesting(false)
    , m_totalTestCount(0)
    , m_completedTestCount(0)
    , m_activeTestCount(0)
    , m_subscriptionManager(&SubscriptionManager::instance())
    , m_vpnManager(&VPNManager::instance())
{
    // 注意：不在此处连接 updateCompleted → serversChanged，
    // 因为 loadServersFromManager() 末尾的 applyFilter() 已经会 emit serversChanged()。
    // 双重 emit 会导致 QML 端服务器列表刷新 2 次。
    // 初始加载 - 从本地数据库加载已有的服务器
    loadServersFromManager();

    // 加载之前保存的测速结果
    loadSpeedTestResults();

    // 创建防抖计时器（300ms 防抖，避免 N 个订阅触发 N 次重载）
    m_reloadDebounceTimer = new QTimer(this);
    m_reloadDebounceTimer->setSingleShot(true);
    m_reloadDebounceTimer->setInterval(300);
    connect(m_reloadDebounceTimer, &QTimer::timeout, this, &ServerListViewModel::loadServersFromManager);

    // 监听单个订阅更新 — 防抖处理
    if (m_subscriptionManager) {
        connect(m_subscriptionManager, &SubscriptionManager::subscriptionUpdated,
                this, [this](Subscription* subscription) {
            Q_UNUSED(subscription);
            LOG_DEBUG("Subscription updated, debouncing server reload");
            m_reloadDebounceTimer->start();  // restart 防抖
        }, Qt::QueuedConnection);

        // 监听批量更新完成 — 立即重载一次
        connect(m_subscriptionManager, &SubscriptionManager::batchUpdateCompleted,
                this, [this](int successCount, int failedCount) {
            Q_UNUSED(successCount);
            Q_UNUSED(failedCount);
            LOG_INFO("Batch update completed, reloading servers from manager");
            m_reloadDebounceTimer->stop();  // 取消待执行的防抖
            loadServersFromManager();
        }, Qt::QueuedConnection);
    }

    // 连接VPNManager的状态变化信号，以便更新UI
    connect(m_vpnManager, &VPNManager::stateChanged,
            this, &ServerListViewModel::isConnectedChanged);
    connect(m_vpnManager, &VPNManager::stateChanged,
            this, &ServerListViewModel::connectionStateTextChanged);
    connect(m_vpnManager, &VPNManager::stateMessageChanged,
            this, &ServerListViewModel::connectionStateTextChanged);

    // 追踪最后已知的已连接服务器 ID
    // 订阅更新时 SubscriptionManager 会删除旧 Server 对象并创建新的，
    // 导致 VPNManager::m_currentServer (QPointer) 自动变 null，VPN 显示断开。
    // 通过持久记录 ID，可在更新后恢复指针。
    connect(m_vpnManager, &VPNManager::currentServerChanged, this, [this]() {
        if (m_vpnManager) {
            Server* current = m_vpnManager->currentServer();
            if (current) {
                m_lastConnectedServerId = current->id();
            }
        }
    });
    // 初始化时保存当前服务器 ID
    if (m_vpnManager && m_vpnManager->currentServer()) {
        m_lastConnectedServerId = m_vpnManager->currentServer()->id();
    }

    // --- 备用域名重试 ---
    loadAlterUrls();
    if (m_subscriptionManager) {
        connect(m_subscriptionManager, &SubscriptionManager::updateFailed,
                this, &ServerListViewModel::onSubscriptionUpdateFailed);
        connect(m_subscriptionManager, &SubscriptionManager::updateCompleted,
                this, &ServerListViewModel::onSubscriptionUpdateCompleted);
    }
}

/**
 * @brief 设置筛选文本
 * @param text 新的筛选文本
 *
 * @details 当筛选文本改变时：
 * - 更新m_filterText成员变量
 * - 发出filterTextChanged信号
 * - 重新应用筛选条件
 */
void ServerListViewModel::setFilterText(const QString& text)
{
    if (m_filterText != text) {
        m_filterText = text;
        emit filterTextChanged();
        applyFilter();
    }
}

/**
 * @brief 设置加载状态
 * @param loading 是否正在加载
 *
 * @details 当加载状态改变时发出isLoadingChanged信号
 */
void ServerListViewModel::setIsLoading(bool loading)
{
    if (m_isLoading != loading) {
        m_isLoading = loading;
        emit isLoadingChanged();
    }
}

/**
 * @brief 刷新服务器列表
 *
 * @details 刷新流程：
 * 1. 设置加载状态为true
 * 2. 使用QTimer异步触发订阅更新，避免阻塞UI线程
 * 3. 监听batchUpdateCompleted信号，更新完成后重新加载服务器列表
 *
 * @see loadServersFromManager()
 */
void ServerListViewModel::refreshServers()
{
    LOG_INFO("Manual refresh triggered - updating subscriptions from network");

    setIsLoading(true);

    // 从网络更新所有订阅，而不是只从内存缓存重载
    // batchUpdateCompleted 信号已在构造函数中连接到 loadServersFromManager()
    if (m_subscriptionManager) {
        m_subscriptionManager->updateAllSubscriptions();
    } else {
        LOG_ERROR("SubscriptionManager is null");
        setIsLoading(false);
    }
}

/**
 * @brief 选择服务器
 * @param server 要选择的服务器指针
 *
 * @details 当选中的服务器改变时发出selectedServerChanged信号
 * @note 使用QPointer安全持有，如果server被删除，QPointer会自动置空
 */
void ServerListViewModel::selectServer(Server* server)
{
    if (m_selectedServer.data() != server) {
        m_selectedServer = server;  // QPointer会安全地持有指针
        emit selectedServerChanged();
    }
}

/**
 * @brief 连接到服务器
 * @param server 要连接的服务器指针
 *
 * @details 连接流程：
 * 1. 检查服务器指针是否有效
 * 2. 选中该服务器
 * 3. 调用VPN管理器的connecting方法建立连接
 */
void ServerListViewModel::connectToServer(Server* server)
{
    if (!server) {
        LOG_WARNING("Cannot connect: no server specified");
        return;
    }

    LOG_INFO(QString("Connecting to server: %1").arg(server->name()));

    // 【关键修复】如果VPN已连接，selectServer会自动处理断开和重连
    // 不需要再调用connecting，否则会触发两次连接尝试
    bool alreadyConnected = m_vpnManager->isConnected();

    selectServer(server);

    // 只有在VPN未连接时才主动调用connecting
    if (!alreadyConnected) {
        m_vpnManager->connecting(server);
    }
}

/**
 * @brief 断开当前VPN连接
 *
 * @details 调用VPNManager的disconnect方法断开当前VPN连接
 */
void ServerListViewModel::disconnect()
{
    LOG_INFO("Disconnecting from VPN");
    m_vpnManager->disconnect();
}

/**
 * @brief 快速连接到当前选中的服务器
 *
 * @details 如果有选中的服务器，则连接到该服务器；否则不执行任何操作
 * @note 使用QPointer::data()安全获取指针，如果对象已删除则返回nullptr
 */
void ServerListViewModel::connectToSelected()
{
    Server* server = m_selectedServer.data();
    if (!server) {
        LOG_WARNING("Cannot connect: no server selected or server object deleted");
        return;
    }

    connectToServer(server);
}

/**
 * @brief 切换连接状态
 *
 * @details 如果当前已连接或正在连接，则断开；否则连接到选中的服务器
 */
void ServerListViewModel::toggleConnection()
{
    if (isConnected() || m_vpnManager->isConnecting()) {
        disconnect();
    } else {
        connectToSelected();
    }
}

/**
 * @brief 获取是否已连接到VPN
 * @return true表示已连接，false表示未连接
 */
bool ServerListViewModel::isConnected() const
{
    return m_vpnManager && m_vpnManager->isConnected();
}

/**
 * @brief 获取连接状态文本描述
 * @return 状态文本（如"已连接"、"正在连接"、"未连接"等）
 */
QString ServerListViewModel::connectionStateText() const
{
    if (!m_vpnManager) {
        return tr("Unknown");
    }
    return m_vpnManager->stateMessage();
}

/**
 * @brief 测试单个服务器延迟（连接页面使用）
 * @param serverId 要测试的服务器ID
 *
 * @details 使用 Xray_TCPPing / Xray_HTTPPing 测试单个服务器延迟：
 * - 在 TUN 模式下且 VPN 已连接时，通过 Extension 执行 TCP ping（macOS/iOS）
 * - Android VPN 已连接时使用 Android_ProtectedTcpPing 绕过 VPN
 * - 否则使用本地 TCP/HTTP ping 测试
 * - 测试完成后更新服务器的延迟值和可用性状态
 *
 * @note 此方法也作为批量测试 fallback 模式的底层调用
 */
void ServerListViewModel::testServerLatency(const QString& serverId)
{
    // Find server by ID
    Server* server = nullptr;
    for (const QPointer<Server>& serverPtr : m_allServers) {
        if (!serverPtr.isNull() && serverPtr->id() == serverId) {
            server = serverPtr.data();
            break;
        }
    }

    if (!server) {
        LOG_WARNING(QString("[ServerListViewModel] Server not found for ID: %1").arg(serverId));
        return;
    }

    // 使用QPointer安全地持有Server指针，防止对象被删除后访问
    QPointer<Server> serverPtr(server);

    // 标记为测试中
    server->setIsTestingSpeed(true);

    LOG_INFO(QString("[testServerLatency] Testing server: %1 (%2:%3)")
                 .arg(server->name())
                 .arg(server->address())
                 .arg(server->port()));

    // 获取测速方法配置
    ConfigManager& configManager = ConfigManager::instance();
    int timeout = configManager.testTimeout() * 1000; // 转换为毫秒

    // 获取测试参数
    QString address = server->address();
    int port = server->port();
    QString testAddress = QString("%1:%2").arg(address).arg(port);

#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    // iOS: VPN 已连接时，通过 Network Extension 执行延时测试
    // macOS: TUN 模式使用 JinGoCore（非 Network Extension），直接走 Xray_TCPPing
#if defined(Q_OS_IOS)
    bool useExtension = m_vpnManager && m_vpnManager->isConnected();
#else
    // macOS 不使用 Extension，TUN 流量走 Xray direct outbound 到服务器
    bool useExtension = false;
#endif
    if (useExtension) {
        LOG_INFO(QString("[testServerLatency] VPN connected, using Extension for test: %1").arg(testAddress));

        // 使用桥接函数调用 NetworkExtensionManager
        QPointer<ServerListViewModel> safeExtThis(this);
        testServerLatencyViaExtension(testAddress, timeout, [serverPtr, safeExtThis](int latency) {
            // 回调已经在主线程执行
            if (!serverPtr) {
                LOG_WARNING("Server object deleted during latency test");
                return;
            }
            if (!safeExtThis) return;

            if (latency > 0) {
                LOG_INFO(QString("Server %1 latency (via Extension): %2 ms")
                             .arg(serverPtr->name()).arg(latency));
                serverPtr->setLatency(latency);
                serverPtr->setIsAvailable(true);
            } else {
                LOG_WARNING(QString("Failed to test server %1 via Extension: latency=%2")
                                .arg(serverPtr->name()).arg(latency));
                serverPtr->setLatency(0);
                serverPtr->setIsAvailable(false);
            }

            serverPtr->setIsTestingSpeed(false);
            serverPtr->updateLastTested();
            emit safeExtThis->serverTestCompleted(serverPtr.data());

            // 如果是批量测试，更新进度
            safeExtThis->handleBatchTestProgress();
        });
        return;
    }
#endif

    // 非 TUN 模式或 VPN 未连接：使用本地 SuperRay 测试
    ConfigManager::LatencyTestMethod testMethod = configManager.latencyTestMethod();

    QString testMethodName = (testMethod == ConfigManager::TCPTest) ? "TCP" : "HTTP";
    LOG_INFO(QString("[testServerLatency] Test method: %1, timeout: %2ms")
                 .arg(testMethodName)
                 .arg(timeout));

    // 在后台线程执行测试
    // 使用 QPointer 安全地捕获 this，避免对象销毁后访问无效指针
    QPointer<ServerListViewModel> safeThis = this;
    auto future = QtConcurrent::run([serverPtr, testMethod, address, timeout, safeThis]() {
        QString serverName = serverPtr ? serverPtr->name() : "NULL";
        int latency = -1;

        // 检查VPN状态
        bool vpnConnected = safeThis && safeThis->m_vpnManager && safeThis->m_vpnManager->isConnected();

        if (testMethod == ConfigManager::TCPTest) {
            // ========== TCP 测试 ==========
            // TCP 连接到服务器测试延迟（需要地址和端口）
            int port = serverPtr ? serverPtr->port() : 0;
            LOG_INFO(QString("[TCP Test] Testing server %1 (%2:%3)").arg(serverName).arg(address).arg(port));

            // 验证地址有效性
            if (address.isEmpty() || port <= 0) {
                LOG_WARNING(QString("[TCP Test] Invalid address/port for server %1").arg(serverName));
                latency = -1;
            } else {
                QByteArray addressData = address.toUtf8();
#ifdef Q_OS_ANDROID
                // Android: 根据 VPN 连接状态选择测试方法
                if (vpnConnected) {
                    // VPN 已连接：使用被保护的 socket 绕过 VPN 测试真正的延时
                    LOG_INFO(QString("[TCP Test] VPN connected, using Android_ProtectedTcpPing"));
                    latency = Android_ProtectedTcpPing(addressData.constData(), port, timeout);
                } else {
                    // VPN 未连接：直接使用普通 TCP Ping
                    LOG_INFO(QString("[TCP Test] VPN not connected, using Xray_TCPPing"));
                    latency = Xray_TCPPing(addressData.constData(), port, timeout);
                }
#else
                // 其他平台：使用 Xray_TCPPing
                latency = Xray_TCPPing(addressData.constData(), port, timeout);
#endif
            }

            LOG_INFO(QString("[TCP Test] Server %1 result: %2 ms").arg(serverName).arg(latency));
        } else {
            // ========== HTTP 测试 (使用 SuperRay_HTTPPing) ==========
            // 服务器列表测试：总是直接测试目标服务器，不通过当前VPN代理
            // 这样可以准确测量每个服务器到互联网的延时
            QString testUrl = BundleConfig::instance().latencyTestUrl();
            QString proxyAddr = "";  // 直连测试，不使用代理

            LOG_INFO(QString("[HTTP Test] Testing %1 direct (no proxy) for server %2").arg(testUrl).arg(serverName));

            QByteArray urlData = testUrl.toUtf8();
            QByteArray proxyData = proxyAddr.toUtf8();
            latency = Xray_HTTPPing(urlData.constData(), proxyData.constData(), timeout);

            LOG_INFO(QString("[HTTP Test] Server %1 result: %2 ms").arg(serverName).arg(latency));
        }

        // 在主线程更新UI - 检查 ViewModel 是否仍然有效
        if (!safeThis) {
            LOG_WARNING("ServerListViewModel was destroyed during latency test");
            return;
        }
        QMetaObject::invokeMethod(safeThis.data(), [serverPtr, latency, safeThis]() {
            if (!safeThis) return;
            if (!serverPtr) {
                LOG_WARNING("Server object deleted during latency test");
                return;
            }

            if (latency > 0) {
                LOG_INFO(QString("Server %1 latency: %2 ms").arg(serverPtr->name()).arg(latency));
                serverPtr->setLatency(latency);
                serverPtr->setIsAvailable(true);
            } else {
                LOG_WARNING(QString("Failed to test server %1: ping returned %2")
                                .arg(serverPtr->name())
                                .arg(latency));
                serverPtr->setLatency(0);
                serverPtr->setIsAvailable(false);
            }

            serverPtr->setIsTestingSpeed(false);
            serverPtr->updateLastTested();
            emit safeThis->serverTestCompleted(serverPtr.data());

            // 如果是批量测试，更新进度
            safeThis->handleBatchTestProgress();

        }, Qt::QueuedConnection);
    });
    Q_UNUSED(future);
}

/**
 * @brief 测试服务器吞吐量（下载速度）
 * @param serverId 要测试的服务器ID
 *
 * @details 吞吐量测试实现：
 * - 如果当前 VPN 已连接到此服务器，使用现有代理测试
 * - 如果未连接，需要先连接到该服务器才能测试吞吐量
 * - 通过下载测试文件来测量实际下载速度
 * - iOS/macOS/Android 使用 QNetworkAccessManager（流量自动通过 TUN 隧道）
 * - Windows/Linux 使用 Xray_SpeedTest（通过 SOCKS5 代理）
 */
void ServerListViewModel::testServerThroughput(const QString& serverId)
{
    // Find server by ID
    Server* server = nullptr;
    for (const QPointer<Server>& serverPtr : m_allServers) {
        if (!serverPtr.isNull() && serverPtr->id() == serverId) {
            server = serverPtr.data();
            break;
        }
    }

    if (!server) {
        LOG_WARNING(QString("[testServerThroughput] Server not found for ID: %1").arg(serverId));
        return;
    }

    // 使用QPointer安全地持有Server指针
    QPointer<Server> serverPtr(server);

    // 标记为测试中
    server->setIsTestingSpeed(true);

    LOG_INFO(QString("[testServerThroughput] Testing server throughput: %1 (%2:%3)")
                 .arg(server->name())
                 .arg(server->address())
                 .arg(server->port()));

    // 检查 VPN 是否已连接（QML 端会先连接再调用此函数）
    if (!m_vpnManager || !m_vpnManager->isConnected()) {
        LOG_WARNING(QString("[testServerThroughput] VPN is not connected, cannot test throughput for server %1")
                        .arg(server->name()));
        server->setIsTestingSpeed(false);

        // 保存错误结果
        QVariantMap result;
        result["speed"] = "N/A";
        result["error"] = tr("VPN not connected");
        setSpeedTestResult(serverId, result);
        emit serverThroughputTestCompleted(server, -1);
        return;
    }


    // 获取速度测试 URL（使用 Cloudflare 或配置的 URL）
    QString speedTestBaseUrl = BundleConfig::instance().speedTestBaseUrl();
    // 默认下载 10MB 的文件进行测试
    QString downloadURL = speedTestBaseUrl + "10000000";

#if defined(Q_OS_WIN) || defined(Q_OS_LINUX)
    // ========== Windows/Linux: 使用 Xray_SpeedTest + SOCKS5 代理 ==========
    ConfigManager& configManager = ConfigManager::instance();
    int socksPort = configManager.localSocksPort();
    QString proxyAddr = QString("127.0.0.1:%1").arg(socksPort);

    LOG_INFO(QString("[testServerThroughput] Using Xray_SpeedTest with proxy: %1, URL: %2")
                 .arg(proxyAddr).arg(downloadURL));

    // 在后台线程执行测试
    QPointer<ServerListViewModel> safeThis = this;
    auto future = QtConcurrent::run([serverPtr, proxyAddr, downloadURL, safeThis]() {
        QString serverName = serverPtr ? serverPtr->name() : "NULL";
        QString serverId = serverPtr ? serverPtr->id() : "";
        double speedMbps = -1;

        LOG_INFO(QString("[testServerThroughput] Starting speed test for server %1").arg(serverName));

        // 调用 Xray_SpeedTest
        char resultBuffer[4096];
        QByteArray urlData = downloadURL.toUtf8();
        QByteArray proxyData = proxyAddr.toUtf8();

        int ret = Xray_SpeedTest(urlData.constData(), proxyData.constData(), 10, resultBuffer, sizeof(resultBuffer));

        if (ret == 0) {
            // 解析结果
            QString resultStr = QString::fromUtf8(resultBuffer);
            LOG_INFO(QString("[testServerThroughput] Speed test result: %1").arg(resultStr.left(200)));

            QJsonDocument doc = QJsonDocument::fromJson(resultStr.toUtf8());
            if (doc.isObject()) {
                QJsonObject obj = doc.object();
                if (obj.value("success").toBool()) {
                    QJsonObject data = obj.value("data").toObject();
                    speedMbps = data.value("speed_mbps").toDouble(-1);
                    if (speedMbps < 0) {
                        // 尝试其他字段名
                        speedMbps = data.value("download_mbps").toDouble(-1);
                    }
                }
            }
        } else {
            LOG_WARNING(QString("[testServerThroughput] Speed test failed for server %1").arg(serverName));
        }

        LOG_INFO(QString("[testServerThroughput] Server %1 throughput: %2 Mbps").arg(serverName).arg(speedMbps));

        // 在主线程更新UI
        if (!safeThis) {
            LOG_WARNING("ServerListViewModel was destroyed during throughput test");
            return;
        }
        QMetaObject::invokeMethod(safeThis.data(), [serverPtr, speedMbps, serverId, safeThis]() {
            if (!safeThis) return;
            if (!serverPtr) {
                LOG_WARNING("Server object deleted during throughput test");
                return;
            }

            serverPtr->setIsTestingSpeed(false);

            // 保存结果
            QVariantMap result;
            if (speedMbps > 0) {
                result["speed"] = QString::number(speedMbps, 'f', 2) + " Mbps";
                result["speedValue"] = speedMbps;
                LOG_INFO(QString("Server %1 throughput: %2 Mbps").arg(serverPtr->name()).arg(speedMbps));
            } else {
                result["speed"] = "Failed";
                result["error"] = "Speed test failed";
                LOG_WARNING(QString("Failed to test throughput for server %1").arg(serverPtr->name()));
            }

            safeThis->setSpeedTestResult(serverId, result);
            emit safeThis->serverThroughputTestCompleted(serverPtr.data(), speedMbps);

        }, Qt::QueuedConnection);
    });
    Q_UNUSED(future);
#else
    // ========== iOS/macOS/Android: 使用 QNetworkAccessManager ==========
    // TUN 模式下，Qt 的网络请求会自动通过系统 VPN 路由
    // Go 运行时（SuperRay）的 HTTP 请求可能不会通过 TUN 隧道
    LOG_INFO(QString("[testServerThroughput] Using QNetworkAccessManager (TUN mode), URL: %1").arg(downloadURL));

    QPointer<ServerListViewModel> safeThis = this;

    // 创建网络管理器（在主线程）
    QNetworkAccessManager* networkManager = new QNetworkAccessManager(this);

    // 使用 shared_ptr 避免内存泄漏
    auto timer = std::make_shared<QElapsedTimer>();
    timer->start();

    // 创建请求
    QUrl speedTestUrl(downloadURL);
    QNetworkRequest request(speedTestUrl);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    // 设置超时（Qt 5.15+ 支持）
    request.setTransferTimeout(30000);  // 30 秒超时

    // 发起 GET 请求
    QNetworkReply* reply = networkManager->get(request);

    // 使用 shared_ptr 跟踪下载的字节数，避免内存泄漏
    auto totalBytesReceived = std::make_shared<qint64>(0);

    // 连接进度信号（实时统计接收的字节数）
    connect(reply, &QNetworkReply::downloadProgress, this, [totalBytesReceived](qint64 bytesReceived, qint64 bytesTotal) {
        Q_UNUSED(bytesTotal);
        *totalBytesReceived = bytesReceived;
    });

    // 保存当前测试的服务器ID（lambda捕获）
    QString testServerId = serverId;
    QString testServerName = server->name();

    // 连接完成信号（明确捕获需要的变量，避免隐式捕获）
    connect(reply, &QNetworkReply::finished, this, [reply, networkManager, timer, totalBytesReceived, serverPtr, safeThis, testServerId, testServerName]() {
        double speedMbps = -1;
        qint64 elapsed = timer->elapsed();

        if (reply->error() == QNetworkReply::NoError) {
            qint64 bytesReceived = *totalBytesReceived;
            if (bytesReceived > 0 && elapsed > 0) {
                double elapsedSec = elapsed / 1000.0;
                speedMbps = (bytesReceived * 8.0) / (elapsedSec * 1000000.0);
            }
        } else {
            LOG_WARNING(QString("Speed test download failed: %1").arg(reply->errorString()));
        }

        // 清理 - shared_ptr 会自动释放内存
        reply->deleteLater();
        networkManager->deleteLater();

        if (!safeThis || !serverPtr) return;

        serverPtr->setIsTestingSpeed(false);

        QVariantMap result;
        if (speedMbps > 0) {
            result["speed"] = QString::number(speedMbps, 'f', 2) + " Mbps";
            result["speedValue"] = speedMbps;
            LOG_INFO(QString("Server %1 throughput: %2 Mbps").arg(testServerName).arg(speedMbps, 0, 'f', 2));
        } else {
            result["speed"] = "Failed";
            result["error"] = "Speed test failed";
        }

        safeThis->setSpeedTestResult(testServerId, result);
        emit safeThis->serverThroughputTestCompleted(serverPtr.data(), speedMbps);
    });
#endif
}

/**
 * @brief 处理批量测试进度更新
 *
 * @details 检查并更新批量测试进度，当所有测试完成时执行排序
 */
void ServerListViewModel::handleBatchTestProgress()
{
    if (!m_isBatchTesting) {
        return;
    }

    m_completedTestCount++;
    m_activeTestCount--;
    m_testingProgressText = tr("Testing %1 of %2 servers...")
        .arg(m_completedTestCount)
        .arg(m_totalTestCount);
    emit testingProgressTextChanged();

    LOG_DEBUG(QString("Batch test progress: %1/%2 (active: %3, pending: %4)")
        .arg(m_completedTestCount).arg(m_totalTestCount)
        .arg(m_activeTestCount).arg(m_pendingTestQueue.size()));

    // 从队列启动下一个测试
    while (m_activeTestCount < MAX_CONCURRENT_TESTS && !m_pendingTestQueue.isEmpty()) {
        QString serverId = m_pendingTestQueue.takeFirst();
        m_activeTestCount++;
        LOG_DEBUG(QString("[Batch Test] Starting next test for server ID: %1 (active: %2)")
            .arg(serverId).arg(m_activeTestCount));
        testServerLatency(serverId);
    }

    // 如果所有测试都完成了，执行排序
    if (m_completedTestCount >= m_totalTestCount) {
        LOG_INFO("所有服务器测试完成，开始排序...");

        // 按延迟排序
        std::sort(m_filteredServers.begin(), m_filteredServers.end(),
                  [](const QPointer<Server>& a, const QPointer<Server>& b) {
                      if (a.isNull()) return false;
                      if (b.isNull()) return true;

                      int latencyA = a->latency();
                      int latencyB = b->latency();

                      if (latencyA == 0 && latencyB == 0) return false;
                      if (latencyA == 0) return false;
                      if (latencyB == 0) return true;

                      return latencyA < latencyB;
                  });

        emit serversSorted();
        LOG_INFO("服务器列表已按延时排序");

        // 重置批量测试状态
        m_isBatchTesting = false;
        m_testingProgressText = tr("Completed! Tested %1 servers").arg(m_totalTestCount);
        emit isBatchTestingChanged();
        emit testingProgressTextChanged();
        emit allTestsCompleted();
    }
}

/**
 * @brief 批量测试所有服务器延迟（服务器列表页面使用）
 *
 * @details 使用 SuperRay 批量 API 测试所有服务器延迟：
 * - TCPTest 模式 → SuperRay_BatchLatencyTest
 * - HTTPTest 模式 → SuperRay_BatchProxyLatencyTest
 * 如果批量 API 失败，自动回退到逐个测试模式
 */
void ServerListViewModel::testAllServersLatency()
{
    LOG_INFO("========== testAllServersLatency() CALLED ==========");
    LOG_INFO(QString("Filtered servers count: %1").arg(m_filteredServers.count()));

    if (m_isBatchTesting) {
        LOG_WARNING("Batch testing already in progress, skipping");
        return;
    }

    if (m_filteredServers.isEmpty()) {
        LOG_WARNING("No servers to test");
        return;
    }

    // 检查VPN状态 - 如果VPN已连接，需要先断开
    // 因为网络请求会通过VPN隧道，无法测试其他服务器的真实延时
    bool vpnConnected = m_vpnManager && m_vpnManager->isConnected();

    if (vpnConnected) {
        LOG_INFO("[Batch Test] VPN is connected, disconnecting first...");
        // 等待 disconnected 信号确认断开后再测试，避免竞争
        connect(m_vpnManager, &VPNManager::disconnected,
                this, &ServerListViewModel::testAllServersLatency,
                static_cast<Qt::ConnectionType>(Qt::SingleShotConnection | Qt::QueuedConnection));
        m_vpnManager->disconnect();
        return;
    }

    // 统计有效服务器数量
    int serverCount = 0;
    for (const auto& server : m_filteredServers) {
        if (!server.isNull()) serverCount++;
    }

    // 初始化批量测试状态
    m_isBatchTesting = true;
    m_totalTestCount = serverCount;
    m_completedTestCount = 0;
    m_activeTestCount = 0;
    m_pendingTestQueue.clear();
    emit isBatchTestingChanged();

    // 标记所有服务器为测试中
    for (const auto& server : m_filteredServers) {
        if (!server.isNull()) {
            server->setIsTestingSpeed(true);
        }
    }

    // 更新进度文本（批量 API 无逐个进度，显示总数 + 旋转动画）
    m_testingProgressText = tr("Testing %1 servers...").arg(m_totalTestCount);
    emit testingProgressTextChanged();

    // 获取测速配置
    ConfigManager& configManager = ConfigManager::instance();
    ConfigManager::LatencyTestMethod testMethod = configManager.latencyTestMethod();
    int timeout = configManager.testTimeout() * 1000; // 转换为毫秒

    // 根据测试方法构建 JSON 并选择对应批量 API
    QByteArray serversJson;
    bool useTcpBatch = (testMethod == ConfigManager::TCPTest);

    if (useTcpBatch) {
        serversJson = serversToTcpTestJson();
    } else {
        serversJson = serversToProxyTestJson();
    }

    if (serversJson.isEmpty()) {
        LOG_ERROR("Failed to build servers JSON for batch test");
        m_isBatchTesting = false;
        emit isBatchTestingChanged();
        return;
    }

    LOG_INFO(QString("[Batch Test] Using %1 mode, %2 servers, timeout=%3ms")
        .arg(useTcpBatch ? "TCP" : "HTTP")
        .arg(m_totalTestCount)
        .arg(timeout));

    // 在后台线程执行阻塞的批量 API 调用
    QPointer<ServerListViewModel> safeThis = this;
    auto future = QtConcurrent::run([safeThis, serversJson, useTcpBatch, timeout]() {
        char* result = nullptr;

        if (useTcpBatch) {
            // TCP 批量测试：concurrent=10, count=1（单次 ping）
            result = SuperRay_BatchLatencyTest(serversJson.constData(), 10, 1, timeout);
        } else {
            // HTTP 代理批量测试：concurrent=5（每个服务器需启动临时 Xray，资源消耗较大）
            result = SuperRay_BatchProxyLatencyTest(serversJson.constData(), 5, timeout);
        }

        QByteArray resultJson;
        if (result) {
            resultJson = QByteArray(result);
            SuperRay_Free(result);
        }

        // 回到主线程处理结果
        if (!safeThis) {
            LOG_WARNING("ServerListViewModel was destroyed during batch test");
            return;
        }
        QMetaObject::invokeMethod(safeThis.data(), [safeThis, resultJson]() {
            if (!safeThis) return;

            if (resultJson.isEmpty()) {
                LOG_WARNING("[Batch Test] Batch API returned empty result, falling back to sequential test");
                safeThis->testAllServersLatencyFallback();
                return;
            }

            safeThis->handleBatchTestResults(resultJson);
        }, Qt::QueuedConnection);
    });
    Q_UNUSED(future);
}

/**
 * @brief 构建 TCP 批量测试的 JSON
 * @return JSON 字符串 [{"name":"...", "address":"...", "port":443}, ...]
 */
QByteArray ServerListViewModel::serversToTcpTestJson() const
{
    QJsonArray serversArray;
    for (const auto& serverPtr : m_filteredServers) {
        if (serverPtr.isNull()) continue;
        QJsonObject obj;
        obj["name"] = serverPtr->name();
        obj["address"] = serverPtr->address();
        obj["port"] = serverPtr->port();
        serversArray.append(obj);
    }
    return QJsonDocument(serversArray).toJson(QJsonDocument::Compact);
}

/**
 * @brief 构建代理 HTTP 批量测试的 JSON（需完整协议配置）
 * @return JSON 字符串，使用 SuperRay ServerInfo 格式（snake_case 字段名）
 *
 * @details SuperRay Go 端的 ServerInfo 结构体期望以下字段名：
 * name, protocol, address, port, uuid, alter_id, security, password, method,
 * flow, network, tls("tls"/"reality"/"none"), sni, alpn, fingerprint, path,
 * host, header_type, public_key, short_id
 *
 * 注意：Server::toJson() 使用 camelCase（如 alterId, tlsServerName），
 * 与 SuperRay 期望的 snake_case 不兼容，因此需要手动映射。
 */
QByteArray ServerListViewModel::serversToProxyTestJson() const
{
    QJsonArray serversArray;
    for (const auto& s : m_filteredServers) {
        if (s.isNull()) continue;

        QJsonObject obj;
        obj["name"]     = s->name();
        obj["protocol"] = s->protocol();
        obj["address"]  = s->address();
        obj["port"]     = s->port();

        // 协议认证字段
        if (!s->uuid().isEmpty())     obj["uuid"]     = s->uuid();
        if (s->alterId() >= 0)        obj["alter_id"] = s->alterId();
        if (!s->security().isEmpty()) obj["security"] = s->security();
        if (!s->password().isEmpty()) obj["password"] = s->password();
        if (!s->method().isEmpty())   obj["method"]   = s->method();
        if (!s->flow().isEmpty())     obj["flow"]     = s->flow();

        // 传输设置
        if (!s->network().isEmpty())    obj["network"]     = s->network();
        if (!s->path().isEmpty())       obj["path"]        = s->path();
        if (!s->host().isEmpty())       obj["host"]        = s->host();
        if (!s->headerType().isEmpty()) obj["header_type"] = s->headerType();

        // TLS 设置：SuperRay 期望 tls 字段为字符串 "tls"/"reality"/"none"
        Server::SecurityType secType = s->securityType();
        if (secType == Server::Reality) {
            obj["tls"] = QStringLiteral("reality");
        } else if (secType == Server::TLS || secType == Server::XTLS) {
            obj["tls"] = QStringLiteral("tls");
        } else if (s->isTLSEnabled()) {
            obj["tls"] = QStringLiteral("tls");
        } else {
            obj["tls"] = QStringLiteral("none");
        }

        if (!s->tlsServerName().isEmpty()) obj["sni"]         = s->tlsServerName();
        if (!s->alpn().isEmpty())          obj["alpn"]        = s->alpn();
        if (!s->fingerprint().isEmpty())   obj["fingerprint"] = s->fingerprint();

        // Reality 设置
        if (!s->realityPublicKey().isEmpty()) obj["public_key"] = s->realityPublicKey();
        if (!s->realityShortId().isEmpty())   obj["short_id"]   = s->realityShortId();

        serversArray.append(obj);
    }
    return QJsonDocument(serversArray).toJson(QJsonDocument::Compact);
}

/**
 * @brief 解析批量测试返回的 JSON 结果，更新 Server 对象的延时
 * @param resultJson 批量 API 返回的 JSON 字符串
 * @return 成功更新的服务器数量
 *
 * @details 批量 API 返回格式:
 * {"success":true,"data":{"results":[{"name":"...", "address":"...", "port":443, "latency_ms":123}, ...]}}
 * 通过 address:port 匹配回 Server 对象
 */
int ServerListViewModel::parseBatchTestResults(const QByteArray& resultJson)
{
    LOG_DEBUG(QString("[Batch Test] Raw result (%1 bytes): %2")
        .arg(resultJson.size())
        .arg(QString::fromUtf8(resultJson.left(500))));

    QJsonParseError parseError;
    QJsonDocument doc = QJsonDocument::fromJson(resultJson, &parseError);
    if (parseError.error != QJsonParseError::NoError) {
        LOG_ERROR(QString("[Batch Test] Failed to parse result JSON: %1").arg(parseError.errorString()));
        return 0;
    }

    // SuperRay 返回格式: {"code":0, "message":"success", "data":{"results":[...], "count":N}}
    QJsonObject root = doc.object();
    int code = root.value("code").toInt(-1);
    if (code != 0) {
        QString message = root.value("message").toString();
        LOG_ERROR(QString("[Batch Test] API returned error code=%1: %2").arg(code).arg(message));
        return 0;
    }

    QJsonObject data = root.value("data").toObject();
    QJsonArray results = data.value("results").toArray();

    if (results.isEmpty()) {
        LOG_WARNING("[Batch Test] No results in response");
        return 0;
    }

    LOG_INFO(QString("[Batch Test] Got %1 results from API").arg(results.size()));

    // 构建 address:port → Server* 的映射表，用于快速查找
    QHash<QString, QPointer<Server>> serverMap;
    for (const auto& serverPtr : m_filteredServers) {
        if (!serverPtr.isNull()) {
            QString key = QString("%1:%2").arg(serverPtr->address()).arg(serverPtr->port());
            serverMap[key] = serverPtr;
        }
    }

    int updatedCount = 0;
    for (const QJsonValue& val : results) {
        QJsonObject item = val.toObject();
        QString address = item.value("address").toString();
        int port = item.value("port").toInt();
        int latencyMs = item.value("latency_ms").toInt(-1);
        bool success = item.value("success").toBool(false);

        QString key = QString("%1:%2").arg(address).arg(port);
        auto it = serverMap.find(key);
        if (it == serverMap.end() || it->isNull()) {
            LOG_DEBUG(QString("[Batch Test] No matching server for %1").arg(key));
            continue;
        }

        Server* server = it->data();
        if (success && latencyMs > 0) {
            server->setLatency(latencyMs);
            server->setIsAvailable(true);
        } else {
            server->setLatency(0);
            server->setIsAvailable(false);
        }
        server->setIsTestingSpeed(false);
        server->updateLastTested();
        emit serverTestCompleted(server);
        updatedCount++;
    }

    LOG_INFO(QString("[Batch Test] Updated %1/%2 servers").arg(updatedCount).arg(results.size()));
    return updatedCount;
}

/**
 * @brief 处理批量测试结果：解析、排序、发送信号
 * @param resultJson 批量 API 返回的 JSON 字符串
 */
void ServerListViewModel::handleBatchTestResults(const QByteArray& resultJson)
{
    int updatedCount = parseBatchTestResults(resultJson);

    if (updatedCount == 0) {
        LOG_WARNING("[Batch Test] No servers updated from batch result, falling back to sequential test");
        testAllServersLatencyFallback();
        return;
    }

    // 将未被批量结果匹配到的服务器标记为不可用
    for (const auto& serverPtr : m_filteredServers) {
        if (!serverPtr.isNull() && serverPtr->isTestingSpeed()) {
            serverPtr->setLatency(0);
            serverPtr->setIsAvailable(false);
            serverPtr->setIsTestingSpeed(false);
            serverPtr->updateLastTested();
        }
    }

    // 按延迟排序
    std::sort(m_filteredServers.begin(), m_filteredServers.end(),
              [](const QPointer<Server>& a, const QPointer<Server>& b) {
                  if (a.isNull()) return false;
                  if (b.isNull()) return true;

                  int latencyA = a->latency();
                  int latencyB = b->latency();

                  if (latencyA == 0 && latencyB == 0) return false;
                  if (latencyA == 0) return false;
                  if (latencyB == 0) return true;

                  return latencyA < latencyB;
              });

    emit serversSorted();
    LOG_INFO("服务器列表已按延时排序");

    // 重置批量测试状态
    m_isBatchTesting = false;
    m_testingProgressText = tr("Completed! Tested %1 servers").arg(m_totalTestCount);
    emit isBatchTestingChanged();
    emit testingProgressTextChanged();
    emit allTestsCompleted();
}

void ServerListViewModel::cancelBatchTest()
{
    if (!m_isBatchTesting) {
        return;
    }

    LOG_INFO("[Batch Test] Cancelling batch test");

    // 清空待测试队列
    m_pendingTestQueue.clear();
    m_activeTestCount = 0;

    // 重置正在测试中的服务器状态
    for (const auto& serverPtr : m_filteredServers) {
        if (!serverPtr.isNull() && serverPtr->isTestingSpeed()) {
            serverPtr->setIsTestingSpeed(false);
        }
    }

    m_isBatchTesting = false;
    m_testingProgressText = tr("Test cancelled");
    emit isBatchTestingChanged();
    emit testingProgressTextChanged();
}

/**
 * @brief 保留原有逐个测试逻辑作为 fallback
 * @details 当批量 API 调用失败时自动回退到此方法，使用队列控制并发
 */
void ServerListViewModel::testAllServersLatencyFallback()
{
    LOG_INFO("[Batch Test Fallback] Starting sequential test fallback");

    // 如果已经不在批量测试状态了（可能被用户取消），直接返回
    if (!m_isBatchTesting) {
        // 重新初始化
        m_isBatchTesting = true;
        m_totalTestCount = 0;
        m_completedTestCount = 0;
        m_activeTestCount = 0;
        m_pendingTestQueue.clear();
        emit isBatchTestingChanged();
    }

    // 构建待测试队列
    m_pendingTestQueue.clear();
    m_totalTestCount = 0;
    m_completedTestCount = 0;
    m_activeTestCount = 0;

    for (const auto& server : m_filteredServers) {
        if (!server.isNull()) {
            m_pendingTestQueue.append(server->id());
            m_totalTestCount++;
        }
    }

    LOG_INFO(QString("[Batch Test Fallback] Starting sequential test for %1 servers (max concurrent: %2)")
        .arg(m_totalTestCount).arg(MAX_CONCURRENT_TESTS));

    // 更新进度文本
    m_testingProgressText = tr("Testing %1 of %2 servers...").arg(0).arg(m_totalTestCount);
    emit testingProgressTextChanged();

    // 启动初始批次的测试
    while (m_activeTestCount < MAX_CONCURRENT_TESTS && !m_pendingTestQueue.isEmpty()) {
        QString serverId = m_pendingTestQueue.takeFirst();
        m_activeTestCount++;
        testServerLatency(serverId);
    }
}

/**
 * @brief 按延迟排序服务器列表
 *
 * @details 先测试所有服务器的延迟，然后按延迟升序排序
 * @note 添加空指针检查，确保排序安全
 */
void ServerListViewModel::sortByLatency()
{
    LOG_INFO("========== sortByLatency() CALLED ==========");
    LOG_INFO(QString("Filtered servers count: %1").arg(m_filteredServers.count()));

    // 检查是否有服务器需要测试延迟（latency < 0 表示未测试）
    QList<QPointer<Server>> serversNeedTest;
    for (const auto& server : m_filteredServers) {
        if (!server.isNull() && server->latency() < 0) {
            serversNeedTest.append(server);
        }
    }

    // 如果所有服务器都已有延迟数据，直接排序
    if (serversNeedTest.isEmpty()) {
        LOG_INFO("All servers have latency data, sorting directly");

        // 按延迟排序：有效延迟 < 超时(0) < 未测试(-1)
        std::sort(m_filteredServers.begin(), m_filteredServers.end(),
                  [](const QPointer<Server>& a, const QPointer<Server>& b) {
                      if (a.isNull()) return false;
                      if (b.isNull()) return true;

                      int latencyA = a->latency();
                      int latencyB = b->latency();

                      // 未测试(-1) 排最后
                      if (latencyA < 0) return false;
                      if (latencyB < 0) return true;

                      // 超时(0) 排在有效延迟之后
                      if (latencyA == 0) return false;
                      if (latencyB == 0) return true;

                      // 有效延迟按从小到大排序
                      return latencyA < latencyB;
                  });

        emit serversSorted();
        return;
    }

    // 有服务器需要测试，进入批量测试模式
    LOG_INFO(QString("Need to test %1 servers, starting batch test").arg(serversNeedTest.count()));

    // 初始化批量测试状态
    m_isBatchTesting = true;
    m_totalTestCount = static_cast<int>(serversNeedTest.count());
    m_completedTestCount = 0;
    emit isBatchTestingChanged();

    // 更新进度文本
    m_testingProgressText = tr("Testing %1 of %2 servers...").arg(0).arg(m_totalTestCount);
    emit testingProgressTextChanged();

    // 只测试需要测试的服务器
    for (const auto& server : serversNeedTest) {
        if (!server.isNull()) {
            LOG_INFO(QString("Testing server: %1").arg(server->name()));
            testServerLatency(server->id());
        }
    }
}

/**
 * @brief 按名称排序服务器列表
 *
 * @details 使用std::sort对过滤后的服务器列表按名称字母顺序排序
 * @note 添加空指针检查，确保排序安全
 */
void ServerListViewModel::sortByName()
{
    std::sort(m_filteredServers.begin(), m_filteredServers.end(),
              [](const QPointer<Server>& a, const QPointer<Server>& b) {
                  // QPointer 空指针检查：空指针排在后面
                  if (a.isNull()) return false;
                  if (b.isNull()) return true;
                  return a->name() < b->name();
              });

    emit serversSorted();
}

/**
 * @brief 获取按距离排序的大洲列表
 * @return 按距离从近到远排序的大洲列表
 */
QStringList ServerListViewModel::getSortedContinents() const
{
    QString userCountryCode = ConfigManager::instance().userCountryCode();
    return CountryUtils::getSortedContinents(userCountryCode);
}

/**
 * @brief 手动添加服务器
 * @param jsonOrLink JSON配置字符串或分享链接
 * @return 成功返回服务器指针，失败返回nullptr
 *
 * @details 将添加请求委托给订阅管理器，添加成功后重新加载服务器列表
 */
Server* ServerListViewModel::addManualServer(const QString& jsonOrLink)
{
    Server* server = m_subscriptionManager->addServerManually(jsonOrLink);

    if (server) {
        loadServersFromManager();
    }

    return server;
}

/**
 * @brief 从数据库重新加载服务器列表（公开方法）
 * @details 供QML调用，不触发网络更新，只从本地SubscriptionManager的缓存中加载
 */
void ServerListViewModel::loadServersFromDatabase()
{
    LOG_INFO("loadServersFromDatabase: Reloading servers from local cache");
    // 直接调用内部的加载方法
    loadServersFromManager();
}

/**
 * @brief 从订阅管理器加载服务器
 *
 * @details 加载流程（增量更新模式）：
 * 1. 检查是否已在更新中（防重入）
 * 2. 设置加载状态
 * 3. 使用QTimer异步从订阅管理器获取所有服务器
 * 4. 使用 ServerListModel::updateServers() 进行增量更新
 * 5. 应用当前的筛选条件
 *
 * @note 使用 Server::id() 作为唯一标识符进行差异比较
 */
void ServerListViewModel::loadServersFromManager()
{
    if (m_isUpdating) {
        LOG_DEBUG("Already updating, skipping loadServersFromManager");
        return;
    }

    m_isUpdating = true;
    setIsLoading(true);

    // 开始刷新服务器列表，通知UI禁用连接按钮
    if (!m_isRefreshingServers) {
        m_isRefreshingServers = true;
        emit isRefreshingServersChanged();
        LOG_DEBUG("Server list refresh started, connection button disabled");
    }

    // 使用QTimer异步加载，避免在可能持有锁的情况下调用
    QTimer::singleShot(0, this, [this]() {
        // 第一步：从 SubscriptionManager 获取所有服务器
        QList<Server*> newServers;
        if (m_subscriptionManager) {
            newServers = m_subscriptionManager->getAllServers();
            LOG_INFO(QString("Loaded %1 servers from SubscriptionManager").arg(newServers.count()));
        } else {
            LOG_ERROR("SubscriptionManager is null");
        }

        // 第二步：使用增量更新模式更新模型
        // ServerListModel 会比较新旧列表，只更新变化的部分
        m_serverModel->updateServers(newServers);

        // 第三步：同步更新旧的 m_allServers 列表（兼容旧代码）
        m_allServers.clear();
        for (Server* server : newServers) {
            if (server) {
                m_allServers.append(QPointer<Server>(server));
            }
        }

        // 第四步：先清除加载标志，再应用过滤
        // 注意顺序：applyFilter() 会 emit serversChanged()，
        // QML 收到信号后会检查 isLoading，必须先置 false
        setIsLoading(false);
        m_isUpdating = false;

        applyFilter();

        // 【修复】订阅更新后恢复 VPN 当前服务器指针
        // SubscriptionManager 更新时会删除旧 Server 对象并创建新的，
        // 导致 VPNManager::m_currentServer (QPointer) 自动变 null，
        // 进而引起 VPN 连接状态显示断开或实际断开。
        if (m_vpnManager && m_vpnManager->isConnected()
                && !m_vpnManager->currentServer()
                && !m_lastConnectedServerId.isEmpty()) {
            Server* restoredServer = m_serverModel->serverById(m_lastConnectedServerId);
            if (restoredServer) {
                // 情况1：同 ID 的服务器仍在列表中，恢复指针即可，不需要重连
                LOG_INFO(QString("Restoring VPN current server pointer after subscription update: %1")
                             .arg(m_lastConnectedServerId));
                m_vpnManager->selectServer(restoredServer);
            } else if (m_serverModel->count() > 0) {
                // 情况2：原服务器已不在列表中（订阅内容完全替换），
                // VPN 仍处于连接态但已无对应服务器，自动切换到列表第一台服务器
                Server* fallbackServer = m_serverModel->serverAt(0);
                if (fallbackServer) {
                    LOG_INFO(QString("Previous server '%1' no longer available after subscription update, "
                                     "reconnecting to first available server: %2")
                                 .arg(m_lastConnectedServerId, fallbackServer->name()));
                    m_vpnManager->connecting(fallbackServer);
                }
            } else {
                LOG_WARNING(QString("Could not restore VPN server - no servers available after subscription update: %1")
                                .arg(m_lastConnectedServerId));
            }
        }
    });
}

/**
 * @brief 应用筛选条件
 *
 * @details 筛选逻辑：
 * - 如果filterText为空，显示所有服务器
 * - 否则，筛选出名称、地址或位置包含filterText的服务器
 * - 筛选后发出serversChanged信号
 *
 * @note 筛选是大小写不敏感的
 */
void ServerListViewModel::applyFilter()
{
    m_filteredServers.clear();

    if (m_filterText.isEmpty()) {
        // 【安全检查】过滤空 QPointer（对象已被删除）
        for (const QPointer<Server>& serverPtr : m_allServers) {
            if (!serverPtr.isNull()) {
                m_filteredServers.append(serverPtr);
            }
        }
    } else {
        QString filter = m_filterText.toLower();
        for (const QPointer<Server>& serverPtr : m_allServers) {
            // 【安全检查】确保 QPointer 有效再访问其属性
            if (!serverPtr.isNull()) {
                Server* server = serverPtr.data();
                if (server && (server->name().toLower().contains(filter) ||
                    server->address().toLower().contains(filter) ||
                    server->location().toLower().contains(filter))) {
                    m_filteredServers.append(serverPtr);
                }
            }
        }
    }

    LOG_INFO(QString("Filter applied: %1 servers shown (total: %2)")
        .arg(m_filteredServers.count())
        .arg(m_allServers.count()));
    emit serversChanged();
}

/**
 * @brief 设置服务器的速度测试结果
 * @param serverId 服务器ID
 * @param result 测试结果 {ip, speed, asn, isp, country}
 */
void ServerListViewModel::setSpeedTestResult(const QString& serverId, const QVariantMap& result)
{
    if (serverId.isEmpty()) {
        LOG_WARNING("Empty server ID, not saving speed test result");
        return;
    }
    m_speedTestResults[serverId] = result;

    // 自动保存到本地文件
    saveSpeedTestResults();

    emit speedTestResultsChanged();
}

/**
 * @brief 获取服务器的速度测试结果
 * @param serverId 服务器ID
 * @return 测试结果，如果没有则返回空 QVariantMap
 */
QVariantMap ServerListViewModel::getSpeedTestResult(const QString& serverId) const
{
    if (m_speedTestResults.contains(serverId)) {
        return m_speedTestResults[serverId].toMap();
    }
    return QVariantMap();
}

/**
 * @brief 清除所有速度测试结果
 */
void ServerListViewModel::clearSpeedTestResults()
{
    m_speedTestResults.clear();
    saveSpeedTestResults();  // 同步清除本地存储
    emit speedTestResultsChanged();
}

/**
 * @brief 保存测速结果到本地文件
 */
void ServerListViewModel::saveSpeedTestResults()
{
    QString dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dataDir);
    QString filePath = dataDir + "/speed_test_results.json";

    QJsonObject rootObj;
    for (auto it = m_speedTestResults.constBegin(); it != m_speedTestResults.constEnd(); ++it) {
        QJsonObject resultObj;
        QVariantMap resultMap = it.value().toMap();
        resultObj["ip"] = resultMap.value("ip").toString();
        resultObj["ipInfo"] = resultMap.value("ipInfo").toString();
        resultObj["speed"] = resultMap.value("speed").toString();
        resultObj["timestamp"] = QDateTime::currentSecsSinceEpoch();
        rootObj[it.key()] = resultObj;
    }

    QJsonDocument doc(rootObj);
    QFile file(filePath);
    if (file.open(QIODevice::WriteOnly)) {
        file.write(doc.toJson(QJsonDocument::Compact));
        file.close();
        LOG_INFO(QString("Speed test results saved to %1 (%2 entries)")
            .arg(filePath).arg(m_speedTestResults.size()));
    } else {
        LOG_ERROR("Failed to save speed test results: " + file.errorString());
    }
}

/**
 * @brief 从本地文件加载测速结果
 */
void ServerListViewModel::loadSpeedTestResults()
{
    QString dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QString filePath = dataDir + "/speed_test_results.json";

    QFile file(filePath);
    if (!file.exists()) {
        LOG_INFO("No saved speed test results found");
        return;
    }

    if (!file.open(QIODevice::ReadOnly)) {
        LOG_ERROR("Failed to open speed test results file: " + file.errorString());
        return;
    }

    QByteArray data = file.readAll();
    file.close();

    QJsonParseError parseError;
    QJsonDocument doc = QJsonDocument::fromJson(data, &parseError);
    if (parseError.error != QJsonParseError::NoError) {
        LOG_ERROR("Failed to parse speed test results: " + parseError.errorString());
        return;
    }

    QJsonObject rootObj = doc.object();
    m_speedTestResults.clear();

    for (auto it = rootObj.constBegin(); it != rootObj.constEnd(); ++it) {
        QString serverId = it.key();
        QJsonObject resultObj = it.value().toObject();
        QVariantMap resultMap;
        resultMap["ip"] = resultObj.value("ip").toString();
        resultMap["ipInfo"] = resultObj.value("ipInfo").toString();
        resultMap["speed"] = resultObj.value("speed").toString();
        m_speedTestResults[serverId] = resultMap;
    }

    LOG_INFO(QString("Loaded %1 cached speed test results").arg(m_speedTestResults.size()));
    emit speedTestResultsChanged();
}

/**
 * @brief 标记服务器列表刷新完成
 * @details 由QML在处理完serversChanged信号后调用，用于恢复连接按钮状态
 */
void ServerListViewModel::finishRefreshingServers()
{
    if (m_isRefreshingServers) {
        m_isRefreshingServers = false;
        emit isRefreshingServersChanged();
        LOG_DEBUG("Server list refresh completed, connection button enabled");
    }
}

// ==================== 备用域名重试 ====================

void ServerListViewModel::loadAlterUrls()
{
    m_alterUrls.clear();

    QString configPath = BundleConfig::instance().configFilePath();
    if (configPath.isEmpty()) {
        LOG_WARNING("BundleConfig configFilePath is empty, cannot load alterUrl");
        return;
    }

    QFile file(configPath);
    if (!file.open(QIODevice::ReadOnly)) {
        LOG_WARNING(QString("Cannot open bundle config file: %1").arg(configPath));
        return;
    }

    QByteArray data = file.readAll();
    file.close();

    QJsonParseError parseError;
    QJsonDocument doc = QJsonDocument::fromJson(data, &parseError);
    if (parseError.error != QJsonParseError::NoError) {
        LOG_WARNING(QString("Failed to parse bundle config JSON: %1").arg(parseError.errorString()));
        return;
    }

    QJsonObject root = doc.object();
    QJsonObject config = root.value("config").toObject();
    QJsonArray alterArray = config.value("alterUrl").toArray();

    for (const QJsonValue& val : alterArray) {
        QString url = val.toString().trimmed();
        if (!url.isEmpty()) {
            m_alterUrls.append(url);
        }
    }

    if (!m_alterUrls.isEmpty()) {
        LOG_INFO(QString("Loaded %1 alter URLs: %2").arg(m_alterUrls.size()).arg(m_alterUrls.join(", ")));
    }
}

void ServerListViewModel::onSubscriptionUpdateFailed(const QString& subscriptionId, const QString& error)
{
    if (m_alterUrls.isEmpty()) {
        return;
    }

    LOG_INFO(QString("Subscription update failed for %1: %2, trying alter URL...").arg(subscriptionId, error));
    tryNextAlterUrl(subscriptionId);
}

void ServerListViewModel::onSubscriptionUpdateCompleted(const QString& subscriptionId, bool success, int serverCount)
{
    if (success && serverCount > 0) {
        // 成功且有服务器 — 清除重试状态
        if (m_alterUrlRetryIndex.contains(subscriptionId)) {
            LOG_INFO(QString("Subscription %1 updated successfully via alter URL, clearing retry state").arg(subscriptionId));
            m_alterUrlRetryIndex.remove(subscriptionId);
            m_originalSubscriptionUrls.remove(subscriptionId);
        }
        return;
    }

    if (m_alterUrls.isEmpty()) {
        return;
    }

    // success == false 或 serverCount == 0 — 返回的不是正确格式的订阅
    LOG_INFO(QString("Subscription %1 update returned invalid content (success=%2, serverCount=%3), trying alter URL...")
                 .arg(subscriptionId).arg(success).arg(serverCount));
    tryNextAlterUrl(subscriptionId);
}

bool ServerListViewModel::tryNextAlterUrl(const QString& subscriptionId)
{
    if (!m_subscriptionManager) {
        return false;
    }

    Subscription* subscription = m_subscriptionManager->getSubscription(subscriptionId);
    if (!subscription) {
        LOG_WARNING(QString("Cannot find subscription %1 for alter URL retry").arg(subscriptionId));
        return false;
    }

    QString currentUrl = subscription->url();

    // 提取 panelUrl 的 host
    QString panelUrl = BundleConfig::instance().panelUrl();
    QUrl panelQUrl(panelUrl);
    QString panelHost = panelQUrl.host();

    if (panelHost.isEmpty()) {
        LOG_WARNING("panelUrl host is empty, cannot do alter URL retry");
        return false;
    }

    // 检查订阅 URL 是否包含 panelUrl 的 host（非面板订阅不做域名替换）
    QUrl currentQUrl(currentUrl);
    QString originalHost;

    // 首次重试时检查原始 URL
    if (m_originalSubscriptionUrls.contains(subscriptionId)) {
        QUrl origQUrl(m_originalSubscriptionUrls[subscriptionId]);
        originalHost = origQUrl.host();
    } else {
        originalHost = currentQUrl.host();
    }

    // 检查原始 host 是否为 panelUrl 的 host，或者为某个 alterUrl 的 host
    bool isPanelSubscription = (originalHost == panelHost);
    if (!isPanelSubscription) {
        for (const QString& alterUrl : m_alterUrls) {
            QUrl alterQUrl(alterUrl);
            if (originalHost == alterQUrl.host()) {
                isPanelSubscription = true;
                break;
            }
        }
    }

    if (!isPanelSubscription) {
        LOG_DEBUG(QString("Subscription %1 URL host '%2' is not panel host '%3', skipping alter URL retry")
                      .arg(subscriptionId, originalHost, panelHost));
        return false;
    }

    // 首次重试时，保存原始 URL
    if (!m_originalSubscriptionUrls.contains(subscriptionId)) {
        m_originalSubscriptionUrls[subscriptionId] = currentUrl;
    }

    // 取当前重试下标
    int retryIndex = m_alterUrlRetryIndex.value(subscriptionId, 0);

    if (retryIndex >= m_alterUrls.size()) {
        // 所有备用域名已用完 — 恢复原始 URL
        LOG_WARNING(QString("All alter URLs exhausted for subscription %1, restoring original URL").arg(subscriptionId));
        subscription->setUrl(m_originalSubscriptionUrls[subscriptionId]);
        m_alterUrlRetryIndex.remove(subscriptionId);
        m_originalSubscriptionUrls.remove(subscriptionId);
        return false;
    }

    // 取备用 URL 并提取其 host
    QString alterUrl = m_alterUrls[retryIndex];
    QUrl alterQUrl(alterUrl);
    QString newHost = alterQUrl.host();

    if (newHost.isEmpty()) {
        LOG_WARNING(QString("Alter URL '%1' has empty host, skipping").arg(alterUrl));
        m_alterUrlRetryIndex[subscriptionId] = retryIndex + 1;
        return tryNextAlterUrl(subscriptionId);  // 递归尝试下一个
    }

    // 替换订阅 URL 中的 host
    QString originalUrl = m_originalSubscriptionUrls[subscriptionId];
    QString newUrl = replaceUrlHost(originalUrl, newHost);

    subscription->setUrl(newUrl);
    m_alterUrlRetryIndex[subscriptionId] = retryIndex + 1;

    LOG_INFO(QString("Retrying subscription %1 with alter URL [%2/%3]: %4")
                 .arg(subscriptionId).arg(retryIndex + 1).arg(m_alterUrls.size()).arg(newUrl));

    m_subscriptionManager->updateSubscription(subscriptionId);
    return true;
}

QString ServerListViewModel::replaceUrlHost(const QString& url, const QString& newHost)
{
    QUrl qurl(url);
    if (!qurl.isValid()) {
        return url;
    }

    // newHost 可能带 scheme（如 "https://cp.jingo.cfd"），提取纯 host
    QString pureHost = newHost;
    if (pureHost.contains("://")) {
        QUrl hostUrl(pureHost);
        pureHost = hostUrl.host();
        // 如果 alterUrl 有不同的 port，也应用
        if (hostUrl.port() != -1) {
            qurl.setPort(hostUrl.port());
        }
    }

    qurl.setHost(pureHost);
    return qurl.toString();
}
