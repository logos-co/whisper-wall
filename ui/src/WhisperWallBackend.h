#pragma once

#include <QFutureWatcher>
#include <QJsonObject>
#include <QObject>
#include <QTimer>
#include <QString>

class LogosAPI;

class WhisperWallBackend : public QObject {
    Q_OBJECT

    Q_PROPERTY(QString latestWhisper  READ latestWhisper  NOTIFY latestWhisperChanged)
    Q_PROPERTY(QString lastTip        READ lastTip        NOTIFY lastTipChanged)
    Q_PROPERTY(int     whisperCount   READ whisperCount   NOTIFY whisperCountChanged)
    Q_PROPERTY(bool    busy           READ busy           NOTIFY busyChanged)
    Q_PROPERTY(bool    wallExists     READ wallExists     NOTIFY wallExistsChanged)
    Q_PROPERTY(QString lastError      READ lastError      NOTIFY lastErrorChanged)
    Q_PROPERTY(QString lastTxHash     READ lastTxHash     NOTIFY lastTxHashChanged)

public:
    explicit WhisperWallBackend(LogosAPI* api, QObject* parent = nullptr);
    ~WhisperWallBackend() override;

    QString latestWhisper() const { return m_latestWhisper; }
    QString lastTip()       const { return m_lastTip; }
    int     whisperCount()  const { return m_whisperCount; }
    bool    busy()          const { return m_busy; }
    bool    wallExists()    const { return m_wallExists; }
    QString lastError()     const { return m_lastError; }
    QString lastTxHash()    const { return m_lastTxHash; }

    Q_INVOKABLE void initialize(const QString& adminAccountId);
    Q_INVOKABLE void whisper(const QString& signerAccountId, const QString& msg);
    Q_INVOKABLE void overwrite(const QString& signerAccountId, const QString& msg, const QString& tip);
    Q_INVOKABLE void drainJar(const QString& adminAccountId, const QString& recipientAccountId);
    Q_INVOKABLE void refreshState();

signals:
    void latestWhisperChanged();
    void lastTipChanged();
    void whisperCountChanged();
    void busyChanged();
    void wallExistsChanged();
    void lastErrorChanged();
    void lastTxHashChanged();
    void txSuccess(const QString& operation, const QString& txHash);
    void txError(const QString& operation, const QString& error);

private:
    void dispatchFfi(const QString& operation, std::function<QString()> fn);
    void handleFfiResult(const QString& operation, const QString& result);
    void applyStateJson(const QJsonObject& state);
    QJsonObject baseArgs() const;

    QString m_walletPath;
    QString m_sequencerUrl;
    QString m_programIdHex;

    QString m_latestWhisper;
    QString m_lastTip      = "0";
    int     m_whisperCount = 0;
    bool    m_busy         = false;
    bool    m_wallExists   = false;
    QString m_lastError;
    QString m_lastTxHash;

    QTimer* m_pollTimer;
};
