/**
 * @file ConnectionViewModel.cpp
 * @brief 连接视图模型实现文件
 * @details 实现VPN连接的状态管理、流量统计和连接时间监控
 * @author JinGo VPN Team
 * @date 2025
 */

#include "ConnectionViewModel.h"
#include "models/Server.h"
#include "core/Logger.h"
#include <QTimer>
#include <QDateTime>
#include <QGuiApplication>

#ifdef Q_OS_ANDROID
#include "superray.h"
#include <QJsonDocument>
#include <QJsonObject>
#endif

/**
 * @brief 构造函数
 * @param parent 父对象
 *
 * @details 初始化视图模型：
 * - 获取VPN管理器单例引用
 * - 创建两个定时器（统计更新和时间更新）
 * - 连接VPN管理器的状态变化信号
 * - 设置连接/断开时的回调处理
 * - 配置定时器（1秒间隔）
 *
 * @note 定时器在连接时启动，断开时停止
 */
ConnectionViewModel::ConnectionViewModel(QObject* parent)
    : QObject(parent)
    , m_vpnManager(&VPNManager::instance())
    , m_statsTimer(new QTimer(this))
    , m_timeTimer(new QTimer(this))
    , m_uploadBytes(0)
    , m_downloadBytes(0)
    , m_uploadSpeed(0)
    , m_downloadSpeed(0)
{
    // 连接 VPN 管理器状态变化信号
    QObject::connect(m_vpnManager, &VPNManager::stateChanged,
                     this, &ConnectionViewModel::onConnectionStateChanged);

    // 连接成功时的处理
    QObject::connect(m_vpnManager, &VPNManager::connected,
                     this, [this]() {
                         m_connectionStartTime = QDateTime::currentDateTime();
                         emit isConnectedChanged();
                         emit connectionStateChanged();
                         emit currentServerNameChanged();
                         m_statsTimer->start();
                         m_timeTimer->start();
                     });

    // 断开连接时的处理
    QObject::connect(m_vpnManager, &VPNManager::disconnected,
                     this, [this]() {
                         emit isConnectedChanged();
                         emit connectionStateChanged();
                         emit currentServerNameChanged();
                         m_statsTimer->stop();
                         m_timeTimer->stop();
                         // 重置流量统计
                         m_uploadBytes = 0;
                         m_downloadBytes = 0;
                         m_uploadSpeed = 0;
                         m_downloadSpeed = 0;
                         emit uploadBytesChanged();
                         emit downloadBytesChanged();
                         emit uploadSpeedChanged();
                         emit downloadSpeedChanged();
                     });

    // 设置统计更新定时器 (每5秒，与VPNCore统计采集频率一致)
    m_statsTimer->setInterval(STATS_INTERVAL_FOREGROUND);
    QObject::connect(m_statsTimer, &QTimer::timeout,
                     this, &ConnectionViewModel::updateStatistics);

    // 设置连接时间更新定时器 (每秒)
    m_timeTimer->setInterval(1000);
    QObject::connect(m_timeTimer, &QTimer::timeout,
                     this, &ConnectionViewModel::updateConnectionTime);

    // 监听应用前后台切换，移动平台后台时降低轮询频率
#if defined(Q_OS_ANDROID) || defined(Q_OS_IOS)
    QObject::connect(qApp, &QGuiApplication::applicationStateChanged,
                     this, &ConnectionViewModel::onApplicationStateChanged);
#endif
}

/**
 * @brief 获取是否已连接
 * @return true表示已连接，false表示未连接
 *
 * @details 从VPN管理器获取当前连接状态
 */
bool ConnectionViewModel::isConnected() const
{
    return m_vpnManager->isConnected();
}

/**
 * @brief 获取连接状态文本
 * @return 本地化的连接状态字符串
 *
 * @details 将VPN管理器的状态枚举转换为用户可读的本地化文本
 */
QString ConnectionViewModel::connectionState() const
{
    switch (m_vpnManager->state()) {
    case VPNManager::Disconnected:
        return tr("Not Connected");
    case VPNManager::Connecting:
        return tr("Connecting...");
    case VPNManager::Connected:
        return tr("Connected");
    case VPNManager::Disconnecting:
        return tr("Disconnecting...");
    case VPNManager::Reconnecting:
        return tr("Reconnecting...");
    case VPNManager::Error:
        return tr("Connection Error");
    default:
        return tr("Unknown Status");
    }
}

/**
 * @brief 获取当前服务器名称
 * @return 服务器名称，如果没有选中服务器则返回"无"
 *
 * @details 从VPN管理器获取当前连接的服务器对象并返回其名称
 */
QString ConnectionViewModel::currentServerName() const
{
    Server* server = m_vpnManager->currentServer();
    return server ? server->name() : tr("None");
}

/**
 * @brief 获取已连接时间
 * @return 格式化的时间字符串（HH:mm:ss）
 *
 * @details 计算从连接开始到当前的时间差并格式化为时:分:秒
 * - 如果未连接则返回"00:00:00"
 */
QString ConnectionViewModel::connectedTime() const
{
    if (!isConnected()) {
        return "00:00:00";
    }

    qint64 seconds = m_connectionStartTime.secsTo(QDateTime::currentDateTime());
    auto hours = seconds / 3600;
    auto minutes = (seconds % 3600) / 60;
    auto secs = seconds % 60;

    return QString("%1:%2:%3")
        .arg(hours, 2, 10, QChar('0'))
        .arg(minutes, 2, 10, QChar('0'))
        .arg(secs, 2, 10, QChar('0'));
}

/**
 * @brief 连接VPN
 *
 * @details 连接流程：
 * 1. 记录日志
 * 2. 从VPN管理器获取当前选中的服务器
 * 3. 如果没有选中服务器则记录警告并返回
 * 4. 调用VPN管理器的connecting方法建立连接
 */
void ConnectionViewModel::connect()
{
    LOG_DEBUG("[ConnectionViewModel] connect() called");

    // 获取当前选中的服务器
    Server* server = m_vpnManager->currentServer();
    LOG_DEBUG(QString("[ConnectionViewModel] currentServer: %1").arg(server ? server->name() : "NULL"));
    if (!server) {
        LOG_WARNING("No server selected for connection");
        return;
    }

    // 注意：物理网卡绑定已移至VPNManager平台特定实现中
    // 原因：网卡绑定属于业务逻辑层，不应在UI层（ViewModel）中处理
    // Linux: 见 VPNManager_Linux.cpp:500-515
    // macOS: 见 JinGoCore.mm:310-323
    // Windows/其他平台：由VPNManager统一处理

    // 调用 VPNManager 的 connect 方法
    LOG_DEBUG("[ConnectionViewModel] Calling VPNManager::connecting()");
    m_vpnManager->connecting(server);
}

/**
 * @brief 断开VPN连接
 *
 * @details 记录日志并调用VPN管理器的disconnect方法
 */
void ConnectionViewModel::disconnect()
{
    m_vpnManager->disconnect();
}

/**
 * @brief 重新连接VPN
 *
 * @details 记录日志并调用VPN管理器的reconnect方法
 * - VPN管理器会自动断开当前连接并重新连接到同一服务器
 */
void ConnectionViewModel::reconnect()
{
    m_vpnManager->reconnect();
}

/**
 * @brief VPN连接状态变化处理
 * @param state 新的连接状态（未使用）
 *
 * @details 当VPN管理器的状态改变时触发，发出connectionStateChanged信号通知UI更新
 */
void ConnectionViewModel::onConnectionStateChanged(VPNManager::ConnectionState state)
{
    Q_UNUSED(state)
    emit connectionStateChanged();
}

/**
 * @brief 更新流量统计数据
 *
 * @details 更新流程：
 * 1. 从VPN管理器获取最新的流量总量和速度
 * 2. 比较新旧值，仅在数据变化时更新并发出信号
 * 3. 分别处理上传/下载字节数和速度
 *
 * @note Android平台：VPNCore使用SuperRay_GetXrayStats()获取的是Xray内部计数器，
 *       在TUN模式下无法反映实际TUN流量。因此Android平台直接调用SuperRay_GetTrafficStats()
 *       和SuperRay_GetCurrentSpeed()获取正确的TUN流量统计。
 */
void ConnectionViewModel::updateStatistics()
{
    qint64 newUploadBytes = 0;
    qint64 newDownloadBytes = 0;
    int newUploadSpeed = 0;
    int newDownloadSpeed = 0;

#ifdef Q_OS_ANDROID
    // Android TUN模式：直接调用SuperRay API获取TUN流量统计
    // VPNCore的SuperRay_GetXrayStats()只能获取Xray inbound/outbound的内部计数，
    // 无法反映通过gVisor netstack→Xray dialer路径的实际TUN流量
    char* trafficStats = SuperRay_GetTrafficStats();
    if (trafficStats) {
        QJsonDocument doc = QJsonDocument::fromJson(QByteArray(trafficStats));
        SuperRay_Free(trafficStats);
        if (doc.isObject()) {
            QJsonObject obj = doc.object();
            // SuperRay_GetTrafficStats 返回格式:
            // {"success":true,"data":{"upload":N,"download":N,...}}
            if (obj.contains("data") && obj["data"].isObject()) {
                QJsonObject data = obj["data"].toObject();
                newUploadBytes = static_cast<qint64>(data["upload"].toDouble());
                newDownloadBytes = static_cast<qint64>(data["download"].toDouble());
            } else {
                // 兼容直接返回的格式
                newUploadBytes = static_cast<qint64>(obj["upload"].toDouble());
                newDownloadBytes = static_cast<qint64>(obj["download"].toDouble());
            }
        }
    }

    char* speedStats = SuperRay_GetCurrentSpeed();
    if (speedStats) {
        QJsonDocument doc = QJsonDocument::fromJson(QByteArray(speedStats));
        SuperRay_Free(speedStats);
        if (doc.isObject()) {
            QJsonObject obj = doc.object();
            if (obj.contains("data") && obj["data"].isObject()) {
                QJsonObject data = obj["data"].toObject();
                newUploadSpeed = static_cast<int>(data["uplink_rate"].toDouble());
                newDownloadSpeed = static_cast<int>(data["downlink_rate"].toDouble());
            } else {
                newUploadSpeed = static_cast<int>(obj["uplink_rate"].toDouble());
                newDownloadSpeed = static_cast<int>(obj["downlink_rate"].toDouble());
            }
        }
    }
#else
    // 非Android平台：从VPNManager获取（VPNManager负责从VPNCore获取和计算）
    newUploadBytes = m_vpnManager->uploadBytes();
    newDownloadBytes = m_vpnManager->downloadBytes();
    newUploadSpeed = static_cast<int>(m_vpnManager->uploadSpeed());
    newDownloadSpeed = static_cast<int>(m_vpnManager->downloadSpeed());
#endif

    // 流量总量更新
    if (newUploadBytes != m_uploadBytes) {
        m_uploadBytes = newUploadBytes;
        emit uploadBytesChanged();
    }

    if (newDownloadBytes != m_downloadBytes) {
        m_downloadBytes = newDownloadBytes;
        emit downloadBytesChanged();
    }

    // 实时速度更新
    if (newUploadSpeed != m_uploadSpeed) {
        m_uploadSpeed = newUploadSpeed;
        emit uploadSpeedChanged();
    }

    if (newDownloadSpeed != m_downloadSpeed) {
        m_downloadSpeed = newDownloadSpeed;
        emit downloadSpeedChanged();
    }
}

/**
 * @brief 更新连接时间
 *
 * @details 每秒由m_timeTimer触发，发出connectedTimeChanged信号通知UI更新
 * - 实际时间计算在connectedTime()方法中进行
 */
void ConnectionViewModel::updateConnectionTime()
{
    emit connectedTimeChanged();
}

/**
 * @brief 应用前后台切换处理
 * @param state 新的应用状态
 *
 * @details 移动平台优化：
 * - 后台时：统计定时器降为30秒间隔，时间定时器暂停（UI不可见）
 * - 前台时：恢复正常轮询频率
 */
void ConnectionViewModel::onApplicationStateChanged(Qt::ApplicationState state)
{
    bool background = (state != Qt::ApplicationActive);
    if (background == m_isInBackground)
        return;

    m_isInBackground = background;

    if (background) {
        LOG_DEBUG("[ConnectionViewModel] App entered background, reducing poll frequency");
        m_statsTimer->setInterval(STATS_INTERVAL_BACKGROUND);
        if (m_timeTimer->isActive())
            m_timeTimer->stop();
    } else {
        LOG_DEBUG("[ConnectionViewModel] App returned to foreground, restoring poll frequency");
        m_statsTimer->setInterval(STATS_INTERVAL_FOREGROUND);
        if (isConnected() && !m_timeTimer->isActive())
            m_timeTimer->start();
        // 立即刷新一次统计和时间
        if (isConnected()) {
            updateStatistics();
            emit connectedTimeChanged();
        }
    }
}