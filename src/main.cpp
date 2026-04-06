// src/main.cpp (修复 FormatUtils 实例化错误)
#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QCoreApplication>

// Unix signal handling for graceful shutdown
#if defined(Q_OS_UNIX)
#include <signal.h>
#endif
#include <QQuickStyle>
#include <QIcon>
#include <QDir>
#include <QStandardPaths>
#include <QDebug>
#include <QTranslator>
#include <QLocale>
#include <QTimer>
#include <QElapsedTimer>
#include <QThread>
#include <QSslSocket>
#include <QMessageBox>
#include <QLockFile>
#include <atomic>

// Core
#include "core/VPNCore.h"
#include "core/VPNManager.h"
#include "core/ConfigManager.h"
#include "core/BundleConfig.h"
#include "core/Logger.h"
#ifdef ENABLE_LICENSE_CHECK
#include "core/LicenseManager.h"
#endif
#include "core/CrashReporter.h"
#if defined(Q_OS_ANDROID) || defined(Q_OS_IOS) || defined(Q_OS_MACOS) || defined(Q_OS_LINUX) || defined(Q_OS_WIN)
#include "core/BackgroundDataUpdater.h"
#endif

// Network
#include "panel/SubscriptionManager.h"
#include "panel/AuthManager.h"
#include "panel/OrderManager.h"
#include "panel/PaymentManager.h"
#include "panel/TicketManager.h"
#include "panel/SystemConfigManager.h"
#include "panel/PanelManager.h"
#include "network/ApiClient.h"
#include "panel/v2board/V2BoardProvider.h"
#include "panel/v2board/V2BoardNormalizer.h"
#include "panel/xboard/XBoardProvider.h"
#include "panel/xboard/XBoardNormalizer.h"

// Storage
#include "storage/DatabaseManager.h"

// Models
#include "models/Server.h"
#include "models/User.h"
#include "models/Subscription.h"

// ViewModels
#include "viewmodels/LoginViewModel.h"
#include "viewmodels/RegisterViewModel.h"
#include "viewmodels/ServerListViewModel.h"
#include "viewmodels/ConnectionViewModel.h"
#include "viewmodels/SettingsViewModel.h"
#include "viewmodels/InviteViewModel.h"
#include "viewmodels/UserStatsViewModel.h"

// Platform
#include <FormatUtils.h>
#include "utils/ClipboardHelper.h"
#include "utils/LanguageManager.h"
#include "utils/CountryUtils.h"
#include "utils/ProxyDetector.h"
#include "utils/LogManager.h"

#include "platform/PlatformInterface.h"

// UI - 仅桌面平台
#if !defined(Q_OS_ANDROID) && !defined(Q_OS_IOS)
#include "ui/SystemTrayManager.h"
#endif

// Android 特定头文件
#if defined(Q_OS_ANDROID)
#include <QJniObject>
#include <QCoreApplication>
#include <QtCore/qnativeinterface.h>
#include "platform/AndroidStatusBarManager.h"
#endif

#if defined(Q_OS_IOS)
#include "platform/ios/IOSSafeAreaProvider.h"
#endif

// Windows 特定头文件 - 需要在main函数中使用CREATE_NO_WINDOW等常量
#if defined(Q_OS_WIN)
#include <windows.h>
#include <shellapi.h>
#endif

// 应用程序常量
#ifndef APP_VERSION
#define APP_VERSION "1.0.0"
#endif

namespace AppInfo {
constexpr const char* Name = "JinGo";
constexpr const char* Organization = "Opine Work";
constexpr const char* Version = APP_VERSION;
constexpr const char* DisplayName = "JinGoVPN";
constexpr const char* Domain = "opine.work";
}

// 初始化应用程序数据目录
bool initializeDataDirectory() {
          QString dataPath = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);

          QDir dir(dataPath);
          if (!dir.exists()) {
                    if (!dir.mkpath(".")) {
                              qCritical() << "Failed to create data directory:" << dataPath;
                              return false;
                    }
          }

          qInfo() << "Data directory:" << dataPath;
          return true;
}

// Geo 数据文件复制逻辑已移至 AndroidXrayBridge::startXray()
// 在首次连接 VPN 时自动从 assets 复制到 files 目录

// 注册 QML 类型
void registerQmlTypes() {
          // 首先注册跨线程信号槽需要的元类型
          qRegisterMetaType<VPNManager::ConnectionState>("ConnectionState");
          qRegisterMetaType<VPNManager::ConnectionState>("VPNManager::ConnectionState");

          // 注册枚举类型
          qmlRegisterUncreatableMetaObject(
                    VPNManager::staticMetaObject,
                    "JinGo",
                    1, 0,
                    "VPNManagerEnums",
                    "Cannot create VPNManager enums in QML"
                    );

          // 注册数据模型类型 - 不可在 QML 中创建
          qmlRegisterUncreatableType<Server>(
                    "JinGo",
                    1, 0,
                    "Server",
                    "Server objects can only be created in C++"
                    );

          qmlRegisterUncreatableType<User>(
                    "JinGo",
                    1, 0,
                    "User",
                    "User objects can only be created in C++"
                    );

          qmlRegisterUncreatableType<Subscription>(
                    "JinGo",
                    1, 0,
                    "Subscription",
                    "Subscription objects can only be created in C++"
                    );

          // 在 main 函数中，engine.load 之前添加：
          qmlRegisterSingletonType<FormatUtils>("JinGo", 1, 0, "FormatUtils",
                [](QQmlEngine *engine, QJSEngine *scriptEngine) -> QObject * {
                    Q_UNUSED(engine)
                    Q_UNUSED(scriptEngine)
                    static FormatUtils* instance = new FormatUtils();
                    return instance;
                });

          // 注意: Theme 单例已在 qmldir 文件中声明,无需在此手动注册
          // qmldir 路径: resources/qml/components/qmldir
          // 声明内容: singleton Theme 1.0 Theme.qml

}

// 设置应用程序样式
void setupApplicationStyle() {
          // 设置 Qt Quick Controls 样式
#if defined(Q_OS_ANDROID) || defined(Q_OS_IOS)
          QQuickStyle::setStyle("Material");
#else
          QQuickStyle::setStyle("Fusion");
#endif

// 设置应用程序图标
#if defined(Q_OS_WIN) || defined(Q_OS_LINUX) || defined(Q_OS_MACOS)
          QApplication::setWindowIcon(QIcon(":/icons/app.png"));
#endif
}

// 初始化语言管理器
void initializeLanguageManager() {
          LanguageManager::instance().initialize();
          LOG_INFO("Language manager initialized");
}

// 初始化核心组件
bool initializeCoreComponents() {
          // 安装崩溃信号处理器（尽早安装以捕获初始化阶段的崩溃）
          CrashReporter::instance().install();

          // 初始化日志系统
          Logger::instance().initialize();
#ifdef Q_OS_ANDROID
          // Android: 保持控制台输出（logcat），便于调试
          Logger::instance().setConsoleOutput(true);
          LOG_INFO("Logger initialized (console output enabled for Android)");
#else
          // 桌面平台：禁用控制台输出，日志只写入文件
          Logger::instance().setConsoleOutput(false);
          LOG_INFO("Logger initialized (console output disabled)");
#endif

          // 初始化数据库
          if (!DatabaseManager::instance().initialize()) {
                    LOG_ERROR("Failed to initialize database");
                    return false;
          }
          LOG_INFO("Database initialized");

          // 初始化配置管理器
          ConfigManager::instance().load();
          LOG_INFO("Configuration loaded");

          // 从配置中设置日志级别
          // ConfigManager::LogLevel: None=0, Error=1, Warning=2, Info=3, Debug=4
          // Logger::LogLevel:        Debug=0, Info=1, Warning=2, Error=3, Critical=4
          // 映射关系: Logger level = 4 - ConfigManager level
          ConfigManager::LogLevel configLogLevel = ConfigManager::instance().logLevel();
          Logger::LogLevel loggerLevel = static_cast<Logger::LogLevel>(4 - static_cast<int>(configLogLevel));
          Logger::instance().setLogLevel(loggerLevel);
          LOG_INFO(QString("Log level set to: %1 (config=%2, logger=%3)")
                   .arg(static_cast<int>(configLogLevel))
                   .arg(static_cast<int>(configLogLevel))
                   .arg(static_cast<int>(loggerLevel)));

          // 连接配置管理器的日志级别变化信号，确保设置页面更改后日志级别同步更新
          QObject::connect(&ConfigManager::instance(), &ConfigManager::logLevelChanged, []() {
              ConfigManager::LogLevel newLevel = ConfigManager::instance().logLevel();
              Logger::instance().setLogLevel(static_cast<Logger::LogLevel>(4 - static_cast<int>(newLevel)));
              LOG_INFO(QString("Log level changed to: %1").arg(static_cast<int>(newLevel)));
          });

          // VPNCore 初始化已移至服务器列表加载完成后，早于首次连接
          LOG_INFO("VPNCore will be initialized after server list loaded");

#ifdef ENABLE_LICENSE_CHECK
          // 后台授权验证：连接 LicenseManager 信号
          LicenseManager& lm = LicenseManager::instance();

          // 授权过期或设备超限 → 弹窗提示并退出
          QObject::connect(&lm, &LicenseManager::exitRequired, qApp,
              [](const QString& title, const QString& message) {
                  LOG_ERROR(QString("[License] Exit required: %1 - %2").arg(title, message));
                  QMessageBox::critical(nullptr, title, message);
                  QCoreApplication::quit();
              });

          LOG_INFO("[License] License check enabled, signals connected");
#endif

          return true;
}

// ----------------------------------------------------------------------
// 注意：原 setupContextProperties 函数已移除，其逻辑已内联到 main 函数中。
// ----------------------------------------------------------------------

// 设置系统托盘连接 - 仅桌面平台
#if !defined(Q_OS_ANDROID) && !defined(Q_OS_IOS)
void setupSystemTrayConnections(SystemTrayManager* systemTray, VPNManager* vpnManager) {
          // VPN 状态变化 -> 更新托盘状态
          QObject::connect(vpnManager, &VPNManager::connected,
                                                      systemTray, [systemTray]() {
                                                                systemTray->setConnected(true);
                                                                LOG_INFO("System tray updated: connected");
                                                      });

          QObject::connect(vpnManager, &VPNManager::disconnected,
                                                      systemTray, [systemTray]() {
                                                                systemTray->setConnected(false);
                                                                LOG_INFO("System tray updated: disconnected");
                                                      });

          QObject::connect(vpnManager, &VPNManager::stateChanged,
                                                      systemTray, [systemTray](VPNManager::ConnectionState state) {
                                                                QString tooltip = "JinGoVPN - ";
                                                                switch (state) {
                                                                case VPNManager::Disconnected:
                                                                          tooltip += QObject::tr("Not Connected");
                                                                          break;
                                                                case VPNManager::Connecting:
                                                                          tooltip += QObject::tr("Connecting...");
                                                                          break;
                                                                case VPNManager::Connected:
                                                                          tooltip += QObject::tr("Connected");
                                                                          break;
                                                                case VPNManager::Disconnecting:
                                                                          tooltip += QObject::tr("Disconnecting...");
                                                                          break;
                                                                case VPNManager::Reconnecting:
                                                                          tooltip += QObject::tr("Reconnecting...");
                                                                          break;
                                                                case VPNManager::Error:
                                                                          tooltip += QObject::tr("Connection Error");
                                                                          break;
                                                                }
                                                                systemTray->setToolTip(tooltip);
                                                      });

          LOG_INFO("System tray connections established");
}
#endif // !Q_OS_ANDROID && !Q_OS_IOS

// ============================================================================
// Unix Signal Handling for Graceful Shutdown
// ============================================================================
#if defined(Q_OS_UNIX)
static QCoreApplication *g_app = nullptr;

void unixSignalHandler(int sig)
{
    // Handle SIGTERM and SIGINT gracefully
    switch (sig) {
    case SIGTERM:
        LOG_INFO("Received SIGTERM signal, initiating graceful shutdown...");
        break;
    case SIGINT:
        LOG_INFO("Received SIGINT signal (Ctrl+C), initiating graceful shutdown...");
        break;
    default:
        LOG_WARNING(QString("Received unexpected signal: %1").arg(sig));
        break;
    }

    // Trigger Qt's quit mechanism (will call aboutToQuit signal)
    if (g_app) {
        QMetaObject::invokeMethod(g_app, "quit", Qt::QueuedConnection);
    }
}

void setupUnixSignalHandlers(QCoreApplication *app)
{
    g_app = app;

    // Install signal handlers
    struct sigaction sa;
    sa.sa_handler = unixSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGTERM, &sa, nullptr);
    sigaction(SIGINT, &sa, nullptr);
    LOG_INFO("Unix signal handlers installed (SIGTERM, SIGINT)");
}
#endif

// 清理应用资源（阻塞操作放入子线程，主线程保持 UI 响应）
void cleanupApplication() {
          static bool alreadyCleaned = false;
          if (alreadyCleaned) return;
          alreadyCleaned = true;

          LOG_INFO("Application shutting down...");

          // 停止后台数据更新器（快速操作，主线程执行）
          LOG_INFO("Stopping background data updater");
#if defined(Q_OS_ANDROID) || defined(Q_OS_IOS) || defined(Q_OS_MACOS) || defined(Q_OS_LINUX) || defined(Q_OS_WIN)
          BackgroundDataUpdater::instance().stop();
          BackgroundDataUpdater::destroy();
#endif

          // 在主线程发起 VPN 断开（disconnect 内部可能依赖信号/槽）
          bool needDisconnect = VPNManager::instance().isConnected() || VPNManager::instance().isConnecting();
          if (needDisconnect) {
                    LOG_INFO("Disconnecting VPN before shutdown...");
                    VPNManager::instance().disconnect();
          }

          // 将阻塞等待和进程清理放入子线程
          std::atomic<bool> cleanupDone{false};
          QThread* cleanupThread = QThread::create([needDisconnect, &cleanupDone]() {
                    // 1. 等待 VPN 断开完成（最多 5 秒）
                    if (needDisconnect) {
                              QElapsedTimer elapsed;
                              elapsed.start();
                              while (elapsed.elapsed() < 5000 &&
                                     (VPNManager::instance().isConnected() || VPNManager::instance().isConnecting())) {
                                        QThread::msleep(100);
                              }
                              LOG_INFO("VPN disconnect wait finished");
                    }

#if defined(Q_OS_MACOS)
                    // 2. macOS: 执行 JinGoCore cleanup（清理残留路由和 DNS）
                    {
                              QString corePath = QCoreApplication::applicationDirPath() + "/JinGoCore";
                              if (QFile::exists(corePath)) {
                                        QProcess cleanupProcess;
                                        cleanupProcess.start(corePath, QStringList() << "cleanup");
                                        cleanupProcess.waitForFinished(5000);
                                        LOG_INFO(QString("JinGoCore cleanup exit code: %1").arg(cleanupProcess.exitCode()));
                              }
                    }
#endif
                    cleanupDone.store(true);
          });
          cleanupThread->start();

          // 主线程保持事件循环响应，等待子线程完成（最多 8 秒）
          QElapsedTimer waitTimer;
          waitTimer.start();
          while (!cleanupDone.load() && waitTimer.elapsed() < 8000) {
                    QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
          }
          if (cleanupThread->isRunning()) {
                    cleanupThread->wait(1000);
          }
          delete cleanupThread;

          // 以下单例销毁必须在主线程执行（线程安全）
          VPNCore::instance().stop();
          VPNCore::destroy();

          ConfigManager::instance().save();

          SubscriptionManager::destroy();

          DatabaseManager::instance().close();
          DatabaseManager::destroy();

          LOG_INFO("Application shutdown complete");
}

// ============================================================================
// Android 权限管理
// ============================================================================

#if defined(Q_OS_ANDROID)
void requestAndroidPermissions() {
          LOG_INFO("Android permissions declared in AndroidManifest.xml");
          LOG_INFO("Runtime permissions will be requested automatically when needed");
          qInfo() << "Android platform initialized";

          // 状态栏颜色控制将在 QML 主题系统中处理
          // 暂时不使用 QtAndroidPrivate::requestPermissions
          // 权限在 AndroidManifest.xml 中声明
          // 运行时由系统自动处理
}
#endif

// ============================================================================
// iOS 权限管理
// ============================================================================

#if defined(Q_OS_IOS)
void requestIOSPermissions() {
          // iOS 权限请求在运行时处理
          // VPN 权限会在尝试建立连接时请求
          LOG_INFO("iOS platform initialized");
          qInfo() << "iOS platform initialized";
}
#endif

// ============================================================================
// 主函数
// ============================================================================

int main(int argc, char *argv[])
{
          // 高 DPI 支持
#if QT_VERSION < QT_VERSION_CHECK(6, 0, 0)
          QApplication::setAttribute(Qt::AA_EnableHighDpiScaling);
          QApplication::setAttribute(Qt::AA_UseHighDpiPixmaps);
#endif

          // 创建应用程序实例
          QApplication app(argc, argv);

          // 设置应用程序信息
          app.setOrganizationName(AppInfo::Organization);
          app.setOrganizationDomain(AppInfo::Domain);
          app.setApplicationName(AppInfo::Name);
          // app.setApplicationDisplayName(AppInfo::DisplayName);  // 移至QML中处理，支持国际化
          app.setApplicationVersion(AppInfo::Version);

          // 【单实例检测】使用 QLockFile 防止多个 JinGo 实例同时运行
          QString lockFilePath = QStandardPaths::writableLocation(QStandardPaths::TempLocation)
                                 + "/jingo.lock";
          QLockFile lockFile(lockFilePath);
          // staleLockTime: 如果持有锁的进程已崩溃，超过此时间后自动清除过期锁
          // QLockFile 会检查锁文件中记录的 PID 是否存活，如果进程已死则立即清除
          lockFile.setStaleLockTime(5000);

          if (!lockFile.tryLock(100)) {
              qWarning() << "JinGo is already running. Exiting.";
              return 0;
          }

          // 初始化数据目录
          if (!initializeDataDirectory()) {
                    qCritical() << "Failed to initialize data directory";
                    return 1;
          }

          // 检测并清除系统 SOCKS5 代理（可能影响登录功能）
          if (ProxyDetector::hasSocks5ProxyEnabled()) {
                    QString proxyInfo = ProxyDetector::getProxyInfo();
                    qWarning() << "===================================================";
                    qWarning() << "WARNING: System SOCKS5 proxy detected!";
                    if (!proxyInfo.isEmpty()) {
                        qWarning() << "Proxy configuration:" << proxyInfo;
                    }
                    qWarning() << "This may prevent login functionality.";
                    qWarning() << "Attempting to disable system SOCKS5 proxy...";
                    qWarning() << "===================================================";
                    LOG_WARNING(QString("System SOCKS5 proxy detected: %1 - This may affect login functionality").arg(proxyInfo));

                    // 尝试清除系统代理
                    if (ProxyDetector::clearSystemProxy()) {
                        qInfo() << "✓ Successfully disabled system SOCKS5 proxy";
                        LOG_INFO("Successfully disabled system SOCKS5 proxy");
                    } else {
                        qWarning() << "✗ Failed to disable system SOCKS5 proxy automatically";
                        qWarning() << "Please disable it manually if you encounter login issues";
                        LOG_WARNING("Failed to disable system SOCKS5 proxy - user may need to disable manually");
                    }
          }

          // Geo 数据文件将在首次连接 VPN 时自动从 assets 复制

          // 设置样式
          setupApplicationStyle();

          // 注意：语言管理器初始化移至核心组件初始化之后，确保Logger已就绪

// 平台特定初始化
#if defined(Q_OS_ANDROID)
          LOG_INFO("Android platform detected");

          // Android特定的OpenGL设置
          QCoreApplication::setAttribute(Qt::AA_ShareOpenGLContexts);

          // 启用SSL调试日志
          qputenv("QT_LOGGING_RULES", "qt.network.ssl=true;qt.network.ssl.warning=true");

          // 检查SSL支持
          qInfo() << "=== SSL/TLS Configuration ===";
          qInfo() << "SSL Support:" << QSslSocket::supportsSsl();
          qInfo() << "SSL Build Version:" << QSslSocket::sslLibraryBuildVersionString();
          qInfo() << "SSL Runtime Version:" << QSslSocket::sslLibraryVersionString();
          qInfo() << "==============================";

          requestAndroidPermissions();
#elif defined(Q_OS_IOS)
          LOG_INFO("iOS platform detected");
          requestIOSPermissions();

          // 读取 Extension 诊断日志（写在 App Group 共享文件中）
          {
              QString extLog = VPNManager::instance().getExtensionLog();
              if (!extLog.isEmpty()) {
                  LOG_INFO("=== Extension Diagnostic Log ===");
                  for (const QString &line : extLog.split('\n')) {
                      if (!line.trimmed().isEmpty()) LOG_INFO(line);
                  }
                  LOG_INFO("=== End Extension Log ===");
              } else {
                  LOG_INFO("No Extension diagnostic log found");
              }
          }
#endif

          // 注册 QML 类型
          registerQmlTypes();

          // 初始化核心组件
          if (!initializeCoreComponents()) {
                    qCritical() << "Failed to initialize core components";
                    return 2;
          }

#if defined(Q_OS_UNIX)
          // Setup signal handlers for graceful shutdown (Ctrl+C, kill, etc.)
          setupUnixSignalHandlers(&app);
#endif

          // 初始化语言管理器（在Logger初始化之后）
          initializeLanguageManager();

// 创建系统托盘管理器（仅桌面平台）
#if !defined(Q_OS_ANDROID) && !defined(Q_OS_IOS)
    // 使用 app 作为父对象，确保其生命周期与应用同步
          SystemTrayManager systemTrayManager(&app);
          LOG_INFO("System tray manager created");

          // 设置系统托盘连接
          setupSystemTrayConnections(&systemTrayManager, &VPNManager::instance());
#endif

          // 创建 QML 引擎
          QQmlApplicationEngine engine;

          // 设置 QML 引擎到 LanguageManager（用于重新翻译）
          LanguageManager::instance().setQmlEngine(&engine);
          LOG_INFO("QML engine set to LanguageManager");

    // ========================================================================
    // 【关键修复】内联设置上下文属性：解决 QML 绑定时机问题
    // ========================================================================
    QQmlContext *rootContext = engine.rootContext();

    if (rootContext) {
        // 运行时安全开关：由编译宏 ENABLE_LICENSE_CHECK 控制
        // 注：配置签名验证在 BundleConfig::loadConfig() 中自动执行，无需运行时开关
#ifdef ENABLE_LICENSE_CHECK
        BundleConfig::setLicenseCheckEnabled(true);
        LOG_INFO("License check: ENABLED");
#endif

        // ========================================================================
        // 【关键修复】Android SecureStorage 必须在创建 ViewModels 之前初始化
        // 因为 LoginViewModel 构造函数会调用 AuthManager::instance()
        // ========================================================================
#if defined(Q_OS_ANDROID)
        // Android: Initialize SecureStorage with application context
        qInfo() << "[Android] Attempting to initialize SecureStorage before ViewModels...";
        LOG_INFO("Attempting to initialize Android SecureStorage before ViewModels...");

        try {
            // Get Android context using Qt 6 API
            qInfo() << "[Android] Getting context from QNativeInterface...";
            QJniObject androidContextObj = QNativeInterface::QAndroidApplication::context();

            qInfo() << "[Android] Context valid:" << androidContextObj.isValid();
            LOG_INFO(QString("Android context object valid: %1").arg(androidContextObj.isValid()));

            if (androidContextObj.isValid()) {
                qInfo() << "[Android] Calling SecureStorage.initialize()...";
                // Call SecureStorage.initialize() with the context
                QJniObject::callStaticMethod<void>(
                    "work/opine/jingo/SecureStorage",
                    "initialize",
                    "(Landroid/content/Context;)V",
                    androidContextObj.object<jobject>()
                );
                qInfo() << "[Android] SecureStorage.initialize() completed successfully";
                LOG_INFO("Android SecureStorage initialized successfully before ViewModels");
            } else {
                qInfo() << "[Android] Context is NOT valid!";
                LOG_ERROR("Android context object is not valid");
            }
        } catch (const std::exception& e) {
            LOG_ERROR(QString("Exception while initializing SecureStorage: %1").arg(e.what()));
        } catch (...) {
            LOG_ERROR("Unknown exception while initializing SecureStorage");
        }

        // ========================================================================
        // 【关键】SecureStorage 初始化完成后，手动调用 loadSession()
        // 这样 AuthManager 可以安全地从 SecureStorage 加载会话数据
        // 如果存在有效会话，会自动触发数据拉取
        // ========================================================================
        qInfo() << "[Android] About to call AuthManager::instance().loadSession()";
        LOG_INFO("About to call AuthManager::instance().loadSession() after SecureStorage initialization");

        try {
            qInfo() << "[Android] Getting AuthManager instance...";
            AuthManager& authManager = AuthManager::instance();
            qInfo() << "[Android] Got AuthManager instance, calling loadSession()...";
            authManager.loadSession();
            qInfo() << "[Android] loadSession() completed";
            LOG_INFO("loadSession() completed successfully");
        } catch (const std::exception& e) {
            LOG_ERROR(QString("Exception calling loadSession(): %1").arg(e.what()));
            qCritical() << "[Android] Exception calling loadSession():" << e.what();
        } catch (...) {
            LOG_ERROR("Unknown exception calling loadSession()");
            qCritical() << "[Android] Unknown exception calling loadSession()";
        }
#elif defined(Q_OS_IOS)
        // ========================================================================
        // 【关键修复】iOS: 在 ViewModels 创建之前调用 loadSession()
        // iOS 不需要像 Android 那样初始化 SecureStorage（自动使用 Keychain）
        // 但同样需要调用 loadSession() 来恢复登录状态
        // ========================================================================
        qInfo() << "[iOS] About to call AuthManager::instance().loadSession()";
        LOG_INFO("About to call AuthManager::instance().loadSession() for iOS");

        try {
            qInfo() << "[iOS] Getting AuthManager instance...";
            AuthManager& authManager = AuthManager::instance();
            qInfo() << "[iOS] Got AuthManager instance, calling loadSession()...";
            authManager.loadSession();
            qInfo() << "[iOS] loadSession() completed";
            LOG_INFO("iOS loadSession() completed successfully");
        } catch (const std::exception& e) {
            LOG_ERROR(QString("iOS Exception calling loadSession(): %1").arg(e.what()));
            qCritical() << "[iOS] Exception calling loadSession():" << e.what();
        } catch (...) {
            LOG_ERROR("iOS Unknown exception calling loadSession()");
            qCritical() << "[iOS] Unknown exception calling loadSession()";
        }
#else
        // ========================================================================
        // 【关键修复】macOS/Windows/Linux: 在 ViewModels 创建之前调用 loadSession()
        // 桌面平台使用系统的 SecureStorage (macOS Keychain, Windows Credential Manager, Linux Secret Service)
        // 不需要像 Android 那样手动初始化，但同样需要调用 loadSession() 来恢复登录状态
        // ========================================================================
        qInfo() << "[Desktop] About to call AuthManager::instance().loadSession()";
        LOG_INFO("About to call AuthManager::instance().loadSession() for Desktop platforms");

        try {
            qInfo() << "[Desktop] Getting AuthManager instance...";
            AuthManager& authManager = AuthManager::instance();
            qInfo() << "[Desktop] Got AuthManager instance, calling loadSession()...";
            authManager.loadSession();
            qInfo() << "[Desktop] loadSession() completed";
            LOG_INFO("Desktop loadSession() completed successfully");
        } catch (const std::exception& e) {
            LOG_ERROR(QString("Desktop Exception calling loadSession(): %1").arg(e.what()));
            qCritical() << "[Desktop] Exception calling loadSession():" << e.what();
        } catch (...) {
            LOG_ERROR("Desktop Unknown exception calling loadSession()");
            qCritical() << "[Desktop] Unknown exception calling loadSession()";
        }
#endif
        // ========================================================================

        // 1. 实例化 ViewModels，将 app 作为父对象 (确保 ViewModels 长生命周期)
        LoginViewModel* loginViewModel = new LoginViewModel(&app);
        RegisterViewModel* registerViewModel = new RegisterViewModel(&app);
        ServerListViewModel* serverListViewModel = new ServerListViewModel(&app);
        ConnectionViewModel* connectionViewModel = new ConnectionViewModel(&app);
        SettingsViewModel* settingsViewModel = new SettingsViewModel(&app);
        InviteViewModel* inviteViewModel = new InviteViewModel(&app);
        UserStatsViewModel* userStatsViewModel = new UserStatsViewModel(&app);

        // 创建工具类实例
        ClipboardHelper* clipboardHelper = new ClipboardHelper(&app);

        // 1.5 根据 BundleConfig 的 panelType 注册并选择面板提供者
        {
            QString panelType = BundleConfig::instance().panelType();
            LOG_INFO(QString("BundleConfig panelType: %1").arg(panelType));

            PanelManager& panelManager = PanelManager::instance();
            if (panelType == "v2board") {
                V2BoardProvider* v2board = new V2BoardProvider(&app);
                panelManager.registerProvider("v2board", v2board);
                panelManager.registerNormalizer("v2board", new V2BoardNormalizer());
                panelManager.setCurrentProvider("v2board");
                // V2Board 不使用 Bearer 前缀，直接发送原始 JWT token
                ApiClient::instance().setUseBearerPrefix(false);
                LOG_INFO("Panel provider set to V2Board");
            } else if (panelType == "xboard") {
                XBoardProvider* xboard = new XBoardProvider(&app);
                panelManager.registerProvider("xboard", xboard);
                panelManager.registerNormalizer("xboard", new XBoardNormalizer());
                panelManager.setCurrentProvider("xboard");
                LOG_INFO("Panel provider set to XBoard");
            }
            // 默认 ezpanel 已在 PanelManager::initDefaultProviders() 中注册
        }

        // 2. 暴露单例管理器
        rootContext->setContextProperty("authManager", &AuthManager::instance());
        rootContext->setContextProperty("vpnManager", &VPNManager::instance());
        rootContext->setContextProperty("subscriptionManager", &SubscriptionManager::instance());
        rootContext->setContextProperty("orderManager", &OrderManager::instance());
        rootContext->setContextProperty("paymentManager", &PaymentManager::instance());
        rootContext->setContextProperty("ticketManager", &TicketManager::instance());
        rootContext->setContextProperty("systemConfigManager", &SystemConfigManager::instance());
        rootContext->setContextProperty("configManager", &ConfigManager::instance());
        rootContext->setContextProperty("bundleConfig", &BundleConfig::instance());
#ifdef ENABLE_LICENSE_CHECK
        rootContext->setContextProperty("licenseManager", &LicenseManager::instance());
#endif
        rootContext->setContextProperty("languageManager", &LanguageManager::instance());
        rootContext->setContextProperty("clipboardHelper", clipboardHelper);
        rootContext->setContextProperty("logManager", &LogManager::instance());

#if defined(Q_OS_ANDROID)
        // Android状态栏管理器
        AndroidStatusBarManager *statusBarManager = new AndroidStatusBarManager(&app);
        rootContext->setContextProperty("androidStatusBarManager", statusBarManager);
        LOG_INFO("Android status bar manager exposed to QML");
#endif

#if defined(Q_OS_IOS)
        // iOS安全区域提供器
        IOSSafeAreaProvider *iosSafeArea = new IOSSafeAreaProvider(&app);
        rootContext->setContextProperty("iosSafeAreaProvider", iosSafeArea);
        LOG_INFO("iOS safe area provider exposed to QML");
#endif

        // 3. 暴露 ViewModels
        rootContext->setContextProperty("loginViewModel", loginViewModel);
        rootContext->setContextProperty("registerViewModel", registerViewModel);
        rootContext->setContextProperty("serverListViewModel", serverListViewModel);
        rootContext->setContextProperty("connectionViewModel", connectionViewModel);
        rootContext->setContextProperty("settingsViewModel", settingsViewModel);
        rootContext->setContextProperty("inviteViewModel", inviteViewModel);
        rootContext->setContextProperty("userStatsViewModel", userStatsViewModel);

        // 5. 暴露系统托盘管理器和平台信息
#if !defined(Q_OS_ANDROID) && !defined(Q_OS_IOS)
        rootContext->setContextProperty("systemTrayManager", &systemTrayManager);
#else
        rootContext->setContextProperty("systemTrayManager", QVariant::fromValue(nullptr));
#endif
        static PlatformInterface* platform = PlatformInterface::create();
        if (platform) {
            rootContext->setContextProperty("platformInterface", platform);

#if !defined(Q_OS_ANDROID) && !defined(Q_OS_IOS)
            // 连接平台通知信号到系统托盘
            QObject::connect(platform, &PlatformInterface::notificationRequested,
                            [&systemTrayManager](const QString& title, const QString& message) {
                                systemTrayManager.showMessage(title, message);
                            });
            LOG_INFO("Platform notification signal connected to system tray");
#endif
        }

        // 6. 暴露应用信息
        rootContext->setContextProperty("appVersion", AppInfo::Version);
        rootContext->setContextProperty("appName", AppInfo::Name);
        rootContext->setContextProperty("appDisplayName", AppInfo::DisplayName);

        LOG_INFO("View Models and core singletons exposed to QML context.");

        // 手动登录成功后 → 触发数据刷新（自动登录由启动定时器处理，不会触发此信号）
        QObject::connect(&AuthManager::instance(), &AuthManager::loginSucceeded,
            &app, [serverListViewModel]() {
                LOG_INFO("Login succeeded, triggering data refresh...");
                BackgroundDataUpdater::instance().triggerUpdate();
                SubscriptionManager::instance().loadSubscriptions();
                if (serverListViewModel) {
                    QMetaObject::invokeMethod(serverListViewModel, "loadServersFromManager",
                                              Qt::QueuedConnection);
                }
                // 提前初始化 VPNCore，减少首次连接延迟
                VPNCore::instance().initialize();
                LOG_INFO("VPNCore initialized after login data refresh");
            });

        // ========================================================================
        // 启动时加载本地缓存数据并通知UI刷新
        // 顺序：订阅 → 服务器 → UI通知
        // 注意：必须在此处（serverListViewModel可见的作用域内）设置定时器
        // ========================================================================
        QTimer::singleShot(500, &app, [serverListViewModel]() {
            try {
                AuthManager* authManager = &AuthManager::instance();
                SubscriptionManager* subscriptionManager = &SubscriptionManager::instance();

                // 0. 先触发后台数据更新（异步从网络刷新，完成后会通过信号自动刷新服务器列表）
                if (authManager->isAuthenticated()) {
                    LOG_INFO("========== [STARTUP] Triggering initial data update before loading local cache ==========");
                    BackgroundDataUpdater::instance().triggerUpdate();
                }

                // 1. 从数据库加载订阅数据（先用本地缓存，网络更新完成后会自动刷新）
                LOG_INFO("Loading subscriptions from local database...");
                subscriptionManager->loadSubscriptions();

                int localSubscriptionCount = subscriptionManager->subscriptionCount();
                int localServerCount = subscriptionManager->totalServerCount();

                LOG_INFO(QString("Loaded from database: %1 subscriptions, %2 servers")
                    .arg(localSubscriptionCount).arg(localServerCount));

                // 2. 然后刷新服务器列表UI（基于本地数据，不触发网络请求）
                if (serverListViewModel) {
                    // 使用异步调用，确保在事件循环中执行
                    QTimer::singleShot(0, [serverListViewModel]() {
                        QMetaObject::invokeMethod(serverListViewModel, "loadServersFromManager",
                                                Qt::QueuedConnection);
                        LOG_INFO("UI refresh triggered for server list");
                    });
                }

                // 提前初始化 VPNCore，减少首次连接延迟
                if (authManager->isAuthenticated()) {
                    VPNCore::instance().initialize();
                    LOG_INFO("VPNCore initialized after startup server list loaded");
                }

                // 记录认证状态
                if (authManager->isAuthenticated()) {
                    LOG_INFO("User authenticated - local cache loaded");
                    LOG_INFO("User can manually refresh to get latest data from server");
                } else {
                    LOG_INFO("User not authenticated - showing login screen");
                }

            } catch (const std::exception& e) {
                LOG_ERROR(QString("Exception during startup data loading: %1").arg(e.what()));
                // 继续运行，使用空数据
            } catch (...) {
                LOG_ERROR("Unknown exception during startup data loading - continuing with empty data");
                // 继续运行
            }
        });

    } else {
        qFatal("QQmlEngine rootContext is null! Cannot proceed.");
        return 3;
    }
    // ========================================================================
    // 修复结束
    // ========================================================================

          LOG_INFO("========== AFTER ROOTCONTEXT IF/ELSE ==========");
          LOG_INFO("About to add import paths and load QML");

          // 添加导入路径
          // 关键：qmldir 文件位于 qrc:/qml/components/qmldir
          // 当 QML 文件执行 "import JinGo 1.0" 时，Qt 会在导入路径中查找 "JinGo/qmldir"
          // 所以我们需要添加 qrc:/qml 作为导入路径
          LOG_INFO("Adding import paths...");
          engine.addImportPath("qrc:/qml");
          LOG_INFO("Import paths added");

          // 处理 QML 错误
          LOG_INFO("Connecting QML error signals...");

          // 连接QML警告信号以捕获加载错误
          QObject::connect(&engine, &QQmlEngine::warnings, &app, [](const QList<QQmlError> &warnings) {
              for (const QQmlError &warning : warnings) {
                  qCritical() << "QML Warning:" << warning.toString();
                  LOG_ERROR(QString("QML Warning: %1").arg(warning.toString()));
              }
          });

          // 使用布尔标志而不是直接调用exit，避免 "invalid reuse" 错误
          bool qmlLoadFailed = false;
          QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                                                      &app, [&qmlLoadFailed]() {
                                                                qCritical() << "Failed to create QML object";
                                                                qmlLoadFailed = true;
                                                      }, Qt::DirectConnection);
          LOG_INFO("QML error signals connected");

          // 加载主 QML 文件
          const QUrl url(QStringLiteral("qrc:/qml/main.qml"));
          LOG_INFO(QString("Attempting to load QML from: %1").arg(url.toString()));
          LOG_INFO(QString("QML import paths: %1").arg(engine.importPathList().join(", ")));
          engine.load(url);
          LOG_INFO("engine.load() returned");

          LOG_INFO("Checking root objects...");
          bool isEmpty = engine.rootObjects().isEmpty();
          auto count = engine.rootObjects().size();
          LOG_INFO(QString("Root objects isEmpty=%1, count=%2").arg(isEmpty).arg(count));

          // 检查加载是否失败
          if (isEmpty || qmlLoadFailed) {
                    LOG_ERROR(QString("Failed to load main.qml from %1").arg(url.toString()));
                    LOG_ERROR(QString("Root objects count: %1").arg(count));
                    LOG_ERROR(QString("QML load failed flag: %1").arg(qmlLoadFailed));
                    return 3;
          }
          LOG_INFO(QString("QML loaded successfully, root objects count: %1").arg(count));

          qInfo() << AppInfo::DisplayName << "started successfully";
          LOG_INFO(QString("%1 version %2 started").arg(AppInfo::DisplayName, AppInfo::Version));

          // ========================================================================
          // 启动后台数据更新器
          // ========================================================================
#if defined(Q_OS_ANDROID) || defined(Q_OS_IOS) || defined(Q_OS_MACOS) || defined(Q_OS_LINUX) || defined(Q_OS_WIN)
          LOG_INFO("Starting background data updater");
          // 从 ConfigManager 获取更新间隔（小时），转换为秒
          int updateIntervalHours = ConfigManager::instance().subscriptionUpdateInterval();
          int updateIntervalSeconds = updateIntervalHours * 3600;
          BackgroundDataUpdater::instance().setUpdateInterval(updateIntervalSeconds);
          BackgroundDataUpdater::instance().start();
          LOG_INFO(QString("Background data updater started - will update every %1 hours").arg(updateIntervalHours));

          // 监听配置变化，动态更新间隔
          QObject::connect(&ConfigManager::instance(), &ConfigManager::subscriptionUpdateIntervalChanged, []() {
              int hours = ConfigManager::instance().subscriptionUpdateInterval();
              BackgroundDataUpdater::instance().setUpdateInterval(hours * 3600);
              LOG_INFO(QString("Subscription update interval changed to %1 hours").arg(hours));
          });

          // 注册 BackgroundDataUpdater 到 QML 上下文
          if (rootContext) {
              rootContext->setContextProperty("backgroundDataUpdater", &BackgroundDataUpdater::instance());
          }

          // triggerUpdate 已移至 500ms 定时器中，在 loadSubscriptions 之前执行

#endif

    // VPN 自动连接（延迟3秒确保订阅数据已加载） - 仅当autoConnect设置为true时
    // 注意：autoConnect 和 autoStart 是不同的设置
    // - autoConnect: 应用启动时自动连接到VPN
    // - autoStart: 系统启动时自动启动应用
    QTimer::singleShot(3000, []() {
        ConfigManager* configManager = &ConfigManager::instance();
        VPNManager* vpnManager = &VPNManager::instance();

        // 1. 检查是否启用自动连接
        if (!configManager->autoConnect()) {
            LOG_INFO("VPN auto-connect is disabled in settings");
            return;
        }

        // 2. 检查VPN当前状态，避免重复连接
        if (vpnManager->isConnected() || vpnManager->state() == VPNManager::Connecting) {
            LOG_INFO("VPN already connected or connecting, skipping auto-connect");
            return;
        }

        // 3. 检查是否有选中的服务器
        Server* currentServer = vpnManager->currentServer();
        if (currentServer) {
            LOG_INFO(QString("VPN auto-connect enabled - connecting to selected server: %1")
                .arg(currentServer->name()));
            vpnManager->connecting(currentServer);
            return;
        }

        // 4. 如果没有选中服务器，检查是否有可用服务器
        LOG_INFO("No server selected, checking available servers...");
        SubscriptionManager* subManager = &SubscriptionManager::instance();
        if (subManager->totalServerCount() > 0) {
            QList<Server*> servers = subManager->getAllServers();
            if (!servers.isEmpty()) {
                LOG_INFO(QString("VPN auto-connect: using first available server: %1")
                    .arg(servers.first()->name()));
                vpnManager->connecting(servers.first());
            } else {
                LOG_WARNING("No servers available for VPN auto-connect (list is empty)");
            }
        } else {
            LOG_WARNING("No servers available for VPN auto-connect (count is 0)");
        }
    });

          // 应用退出时确保清理 VPN
          QObject::connect(&app, &QApplication::aboutToQuit, []() {
                    cleanupApplication();
          });

          // 运行事件循环
          int result = app.exec();

// 清理系统托盘（仅桌面平台）
#if !defined(Q_OS_ANDROID) && !defined(Q_OS_IOS)
    // ViewModels/systemTrayManager 对象的清理将由 app 析构函数自动处理
#endif

          return result;
}

// ============================================================================
// 平台特定入口点处理
// ============================================================================

#if defined(Q_OS_WIN)
// Windows 平台特定初始化
// (Windows 头文件已在文件顶部包含)

// 控制台窗口管理
void setupWindowsConsole() {
#ifdef QT_DEBUG
          // Debug 模式下显示控制台
          AllocConsole();
          FILE* fp = nullptr;
          freopen_s(&fp, "CONOUT$", "w", stdout);
          freopen_s(&fp, "CONOUT$", "w", stderr);
          if (fp) {
                    // 成功打开
          }
#endif
}

// Windows 入口点
int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow)
{
          Q_UNUSED(hInstance)
          Q_UNUSED(hPrevInstance)
          Q_UNUSED(lpCmdLine)
          Q_UNUSED(nCmdShow)

          setupWindowsConsole();

          int argc = 0;
          char **argv = nullptr;

          // 获取命令行参数
          LPWSTR *szArglist = CommandLineToArgvW(GetCommandLineW(), &argc);
          if (szArglist) {
                    argv = new char*[argc];
                    for (int i = 0; i < argc; i++) {
                              int size = WideCharToMultiByte(CP_UTF8, 0, szArglist[i], -1, nullptr, 0, nullptr, nullptr);
                              argv[i] = new char[size];
                              WideCharToMultiByte(CP_UTF8, 0, szArglist[i], -1, argv[i], size, nullptr, nullptr);
                    }
                    LocalFree(szArglist);
          }

          int result = main(argc, argv);

          // 清理
          if (argv) {
                    for (int i = 0; i < argc; i++) {
                              delete[] argv[i];
                    }
                    delete[] argv;
          }

          return result;
}
#endif
