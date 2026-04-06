#ifndef INVITEVIEWMODEL_H
#define INVITEVIEWMODEL_H

#include <QObject>
#include <QString>
#include <QJsonObject>
#include <QVariantList>

class InviteViewModel : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool isLoading READ isLoading NOTIFY isLoadingChanged)
    Q_PROPERTY(QString errorMessage READ errorMessage NOTIFY errorMessageChanged)
    Q_PROPERTY(bool hasData READ hasData NOTIFY hasDataChanged)
    Q_PROPERTY(QString inviteUrl READ inviteUrl NOTIFY inviteUrlChanged)
    Q_PROPERTY(QString inviteCode READ inviteCode NOTIFY inviteCodeChanged)
    Q_PROPERTY(int registeredCount READ registeredCount NOTIFY registeredCountChanged)
    Q_PROPERTY(int commissionRate READ commissionRate NOTIFY commissionRateChanged)
    Q_PROPERTY(int commissionBalance READ commissionBalance NOTIFY commissionBalanceChanged)
    Q_PROPERTY(int totalCommission READ totalCommission NOTIFY totalCommissionChanged)

    Q_PROPERTY(QVariantList inviteDetails READ inviteDetails NOTIFY inviteDetailsChanged)
    Q_PROPERTY(bool isGenerating READ isGenerating NOTIFY isGeneratingChanged)
    Q_PROPERTY(bool isLoadingDetails READ isLoadingDetails NOTIFY isLoadingDetailsChanged)

public:
    explicit InviteViewModel(QObject* parent = nullptr);
    ~InviteViewModel() override = default;

    bool isLoading() const { return m_isLoading; }
    QString errorMessage() const { return m_errorMessage; }
    bool hasData() const { return m_hasData; }
    QString inviteUrl() const { return m_inviteUrl; }
    QString inviteCode() const { return m_inviteCode; }
    int registeredCount() const { return m_registeredCount; }
    int commissionRate() const { return m_commissionRate; }
    int commissionBalance() const { return m_commissionBalance; }
    int totalCommission() const { return m_totalCommission; }

    QVariantList inviteDetails() const { return m_inviteDetails; }
    bool isGenerating() const { return m_isGenerating; }
    bool isLoadingDetails() const { return m_isLoadingDetails; }

    Q_INVOKABLE void fetchInviteInfo();
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void generateInviteCode();
    Q_INVOKABLE void fetchInviteDetails();

signals:
    void isLoadingChanged();
    void errorMessageChanged();
    void hasDataChanged();
    void inviteUrlChanged();
    void inviteCodeChanged();
    void registeredCountChanged();
    void commissionRateChanged();
    void commissionBalanceChanged();
    void totalCommissionChanged();

    void inviteDetailsChanged();
    void isGeneratingChanged();
    void isLoadingDetailsChanged();
    void inviteCodeGenerated();
    void inviteCodeGenerationFailed(const QString& error);

private slots:
    void onInviteInfoLoaded(const QJsonObject& data);
    void onInviteInfoFailed(const QString& error);
    void onInviteCodeGenerated();
    void onInviteCodeGenerationFailed(const QString& error);
    void onInviteDetailsLoaded(const QJsonObject& data);
    void onInviteDetailsFailed(const QString& error);

private:
    bool m_isLoading = false;
    QString m_errorMessage;
    bool m_hasData = false;
    QString m_inviteUrl;
    QString m_inviteCode;
    int m_registeredCount = 0;
    int m_commissionRate = 0;
    int m_commissionBalance = 0;
    int m_totalCommission = 0;

    QVariantList m_inviteDetails;
    bool m_isGenerating = false;
    bool m_isLoadingDetails = false;
};

#endif // INVITEVIEWMODEL_H
