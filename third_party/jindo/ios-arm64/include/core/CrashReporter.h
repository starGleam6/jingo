/**
 * @file CrashReporter.h
 * @brief Crash reporter - captures unhandled signals and writes stack traces
 */

#ifndef CRASHREPORTER_H
#define CRASHREPORTER_H

#include <QObject>
#include <QString>

class CrashReporter : public QObject
{
    Q_OBJECT

public:
    static CrashReporter& instance();

    /**
     * @brief Install crash signal handlers. Call as early as possible in main().
     */
    void install();

    /**
     * @brief Check if a crash report from a previous session exists.
     */
    bool hasPendingCrashReport() const;

    /**
     * @brief Get the path to the pending crash report file.
     */
    QString pendingReportPath() const;

    /**
     * @brief Read the pending crash report content.
     */
    QString readPendingReport() const;

    /**
     * @brief Upload the pending crash report to the server.
     * @param endpoint API endpoint for crash reports
     */
    void uploadPendingReport(const QString& endpoint = QString());

    /**
     * @brief Discard the pending crash report.
     */
    void discardPendingReport();

signals:
    void crashReportUploaded(bool success);

private:
    CrashReporter(QObject* parent = nullptr);
    ~CrashReporter() override;
    CrashReporter(const CrashReporter&) = delete;
    CrashReporter& operator=(const CrashReporter&) = delete;

    static QString crashReportDir();
    static QString crashReportFilePath();

#if defined(Q_OS_WIN)
    static void installWindowsHandler();
#else
    static void installUnixHandlers();
    static void signalHandler(int sig, siginfo_t* info, void* context);
#endif

    bool m_installed = false;
};

#endif // CRASHREPORTER_H
