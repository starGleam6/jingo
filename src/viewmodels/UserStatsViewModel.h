#ifndef USERSTATSVIEWMODEL_H
#define USERSTATSVIEWMODEL_H

#include <QObject>
#include <QString>
#include <QJsonObject>

/**
 * @class UserStatsViewModel
 * @brief 用户统计 ViewModel
 *
 * @details
 * V2Board getStat 返回: [待处理订单数, 待处理工单数, 邀请用户数]
 * 经 Normalizer 归一化后为: {pending_orders, pending_tickets, invited_count}
 */
class UserStatsViewModel : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool isLoading READ isLoading NOTIFY isLoadingChanged)
    Q_PROPERTY(bool hasData READ hasData NOTIFY hasDataChanged)
    Q_PROPERTY(int pendingOrders READ pendingOrders NOTIFY statsChanged)
    Q_PROPERTY(int pendingTickets READ pendingTickets NOTIFY statsChanged)
    Q_PROPERTY(int invitedCount READ invitedCount NOTIFY statsChanged)

public:
    explicit UserStatsViewModel(QObject* parent = nullptr);
    ~UserStatsViewModel() override = default;

    bool isLoading() const { return m_isLoading; }
    bool hasData() const { return m_hasData; }
    int pendingOrders() const { return m_pendingOrders; }
    int pendingTickets() const { return m_pendingTickets; }
    int invitedCount() const { return m_invitedCount; }

    Q_INVOKABLE void fetchStats();

signals:
    void isLoadingChanged();
    void hasDataChanged();
    void statsChanged();

private slots:
    void onUserStatsLoaded(const QJsonObject& data);
    void onUserStatsFailed(const QString& error);

private:
    bool m_isLoading = false;
    bool m_hasData = false;
    int m_pendingOrders = 0;
    int m_pendingTickets = 0;
    int m_invitedCount = 0;
};

#endif // USERSTATSVIEWMODEL_H
