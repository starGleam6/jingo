#include "UserStatsViewModel.h"
#include "panel/AuthManager.h"
#include "core/Logger.h"

UserStatsViewModel::UserStatsViewModel(QObject* parent)
    : QObject(parent)
{
    auto& auth = AuthManager::instance();

    connect(&auth, &AuthManager::userStatsLoaded,
            this, &UserStatsViewModel::onUserStatsLoaded);
    connect(&auth, &AuthManager::userStatsFailed,
            this, &UserStatsViewModel::onUserStatsFailed);
}

void UserStatsViewModel::fetchStats()
{
    LOG_INFO("UserStatsViewModel::fetchStats() called");

    if (m_isLoading) {
        LOG_INFO("UserStatsViewModel::fetchStats() - already loading, skip");
        return;
    }

    m_isLoading = true;
    emit isLoadingChanged();

    AuthManager::instance().fetchUserStats();
}

void UserStatsViewModel::onUserStatsLoaded(const QJsonObject& data)
{
    m_isLoading = false;
    emit isLoadingChanged();

    // 数据已经过 Normalizer 归一化为统一对象格式:
    // {pending_orders, pending_tickets, invited_count}
    m_pendingOrders  = data.value("pending_orders").toInt(0);
    m_pendingTickets = data.value("pending_tickets").toInt(0);
    m_invitedCount   = data.value("invited_count").toInt(0);

    if (!m_hasData) {
        m_hasData = true;
        emit hasDataChanged();
    }

    emit statsChanged();

    LOG_INFO(QString("User stats loaded: orders=%1, tickets=%2, invited=%3")
        .arg(m_pendingOrders).arg(m_pendingTickets).arg(m_invitedCount));
}

void UserStatsViewModel::onUserStatsFailed(const QString& error)
{
    m_isLoading = false;
    emit isLoadingChanged();

    LOG_WARNING(QString("Failed to fetch user stats: %1").arg(error));
}
