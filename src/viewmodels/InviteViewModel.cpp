#include "InviteViewModel.h"
#include "panel/AuthManager.h"
#include "core/Logger.h"
#include <QJsonArray>
#include <QDateTime>

InviteViewModel::InviteViewModel(QObject* parent)
    : QObject(parent)
{
    auto& auth = AuthManager::instance();

    // 邀请信息
    connect(&auth, &AuthManager::inviteInfoLoaded,
            this, &InviteViewModel::onInviteInfoLoaded);
    connect(&auth, &AuthManager::inviteInfoFailed,
            this, &InviteViewModel::onInviteInfoFailed);

    // 生成邀请码
    connect(&auth, &AuthManager::inviteCodeGenerated,
            this, &InviteViewModel::onInviteCodeGenerated);
    connect(&auth, &AuthManager::inviteCodeGenerationFailed,
            this, &InviteViewModel::onInviteCodeGenerationFailed);

    // 邀请明细
    connect(&auth, &AuthManager::inviteDetailsLoaded,
            this, &InviteViewModel::onInviteDetailsLoaded);
    connect(&auth, &AuthManager::inviteDetailsFailed,
            this, &InviteViewModel::onInviteDetailsFailed);
}

void InviteViewModel::fetchInviteInfo()
{
    LOG_INFO("InviteViewModel::fetchInviteInfo() called");

    if (m_isLoading) {
        LOG_INFO("InviteViewModel::fetchInviteInfo() - already loading, skip");
        return;
    }

    m_isLoading = true;
    emit isLoadingChanged();

    m_errorMessage.clear();
    emit errorMessageChanged();

    AuthManager::instance().fetchInviteInfo();
}

void InviteViewModel::refresh()
{
    fetchInviteInfo();
}

void InviteViewModel::generateInviteCode()
{
    LOG_INFO("InviteViewModel::generateInviteCode() called");

    if (m_isGenerating) {
        LOG_INFO("InviteViewModel::generateInviteCode() - already generating, skip");
        return;
    }

    m_isGenerating = true;
    emit isGeneratingChanged();

    AuthManager::instance().generateInviteCode();
}

void InviteViewModel::fetchInviteDetails()
{
    LOG_INFO("InviteViewModel::fetchInviteDetails() called");

    if (m_isLoadingDetails) {
        LOG_INFO("InviteViewModel::fetchInviteDetails() - already loading, skip");
        return;
    }

    m_isLoadingDetails = true;
    emit isLoadingDetailsChanged();

    AuthManager::instance().fetchInviteDetails();
}

// ============================================================================
// AuthManager 信号处理槽函数
// ============================================================================

void InviteViewModel::onInviteInfoLoaded(const QJsonObject& data)
{
    m_isLoading = false;
    emit isLoadingChanged();

    m_errorMessage.clear();
    emit errorMessageChanged();

    // data 已由 Normalizer 归一化为统一格式
    QJsonObject payload = data;
    if (data.contains("data") && data.value("data").isObject()) {
        payload = data.value("data").toObject();
    }

    // 邀请码
    QJsonArray codes = payload.value("codes").toArray();
    QString inviteCode = codes.isEmpty() ? QString() : codes[0].toObject().value("code").toString();
    if (m_inviteCode != inviteCode) {
        m_inviteCode = inviteCode;
        emit inviteCodeChanged();
    }

    // 邀请链接（Normalizer 已保证存在）
    QString inviteUrl = payload.value("invite_url").toString();
    if (m_inviteUrl != inviteUrl) {
        m_inviteUrl = inviteUrl;
        emit inviteUrlChanged();
    }

    // 统计（Normalizer 已保证 stat 是对象格式）
    QJsonObject stat = payload.value("stat").toObject();
    int registeredCount = stat.value("registered_count").toInt(0);
    int commissionRate = stat.value("commission_rate").toInt(0);
    int commissionBalance = stat.value("commission_balance").toInt(0);
    int totalCommission = stat.value("total_commission").toInt(0);

    if (m_registeredCount != registeredCount) {
        m_registeredCount = registeredCount;
        emit registeredCountChanged();
    }
    if (m_commissionRate != commissionRate) {
        m_commissionRate = commissionRate;
        emit commissionRateChanged();
    }
    if (m_commissionBalance != commissionBalance) {
        m_commissionBalance = commissionBalance;
        emit commissionBalanceChanged();
    }
    if (m_totalCommission != totalCommission) {
        m_totalCommission = totalCommission;
        emit totalCommissionChanged();
    }

    if (!m_hasData) {
        m_hasData = true;
        emit hasDataChanged();
    }

    LOG_INFO("Invite info loaded successfully");
}

void InviteViewModel::onInviteInfoFailed(const QString& error)
{
    m_isLoading = false;
    emit isLoadingChanged();

    m_errorMessage = error;
    emit errorMessageChanged();

    LOG_WARNING(QString("Failed to load invite info: %1").arg(error));
}

void InviteViewModel::onInviteCodeGenerated()
{
    m_isGenerating = false;
    emit isGeneratingChanged();

    LOG_INFO("Invite code generated, refreshing invite info");
    emit inviteCodeGenerated();

    // 刷新邀请信息以获取新邀请码
    fetchInviteInfo();
}

void InviteViewModel::onInviteCodeGenerationFailed(const QString& error)
{
    m_isGenerating = false;
    emit isGeneratingChanged();

    LOG_WARNING(QString("Failed to generate invite code: %1").arg(error));
    emit inviteCodeGenerationFailed(error);
}

void InviteViewModel::onInviteDetailsLoaded(const QJsonObject& response)
{
    m_isLoadingDetails = false;
    emit isLoadingDetailsChanged();

    // V2Board invite/details 返回佣金记录列表:
    // {"data": [{"id":..., "trade_no":..., "order_amount":..., "get_amount":..., "created_at":...}], "total":...}
    QJsonArray detailsArray = response.value("data").toArray();
    QVariantList details;

    for (const QJsonValue& val : detailsArray) {
        QJsonObject item = val.toObject();
        QVariantMap detail;

        // 订单号
        detail["tradeNo"] = item.value("trade_no").toString();

        // 订单金额（分 → 元）
        detail["orderAmount"] = item.value("order_amount").toInt(0);

        // 获得佣金（分 → 元）
        detail["getAmount"] = item.value("get_amount").toInt(0);

        // 创建时间
        int createdAt = item.value("created_at").toInt();
        if (createdAt > 0) {
            QDateTime dt = QDateTime::fromSecsSinceEpoch(createdAt);
            detail["createdAt"] = dt.toString("yyyy-MM-dd");
        } else {
            detail["createdAt"] = item.value("created_at").toString();
        }

        details.append(detail);
    }

    m_inviteDetails = details;
    emit inviteDetailsChanged();

    LOG_INFO(QString("Invite details loaded: %1 items").arg(details.size()));
}

void InviteViewModel::onInviteDetailsFailed(const QString& error)
{
    m_isLoadingDetails = false;
    emit isLoadingDetailsChanged();

    LOG_WARNING(QString("Failed to fetch invite details: %1").arg(error));
}
