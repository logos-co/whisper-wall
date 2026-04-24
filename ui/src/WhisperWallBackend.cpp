#include "WhisperWallBackend.h"

#include <QCoreApplication>
#include <QFuture>
#include <QJsonDocument>
#include <QThreadPool>
#include <QJsonObject>
#include <QtConcurrent/QtConcurrent>

// C FFI — resolved at runtime via dlopen (the .so is co-located with the plugin).
extern "C" {
    char* whisper_wall_initialize(const char* args_json);
    char* whisper_wall_whisper(const char* args_json);
    char* whisper_wall_overwrite(const char* args_json);
    char* whisper_wall_drain_jar(const char* args_json);
    char* whisper_wall_fetch_state_json(const char* args_json);
    void  whisper_wall_free_string(char* s);
}

static QString callFfiRaw(char* (*fn)(const char*), const QJsonObject& args) {
    QByteArray json = QJsonDocument(args).toJson(QJsonDocument::Compact);
    char* raw = fn(json.constData());
    if (!raw) return R"({"success":false,"error":"null return from FFI"})";
    QString result = QString::fromUtf8(raw);
    whisper_wall_free_string(raw);
    return result;
}

WhisperWallBackend::WhisperWallBackend(LogosAPI* /*api*/, QObject* parent)
    : QObject(parent)
    , m_walletPath(qEnvironmentVariable("NSSA_WALLET_HOME_DIR", "/tmp/ww-wallet"))
    , m_sequencerUrl(qEnvironmentVariable("NSSA_SEQUENCER_URL", "http://127.0.0.1:3040"))
    , m_programIdHex(qEnvironmentVariable("WHISPER_WALL_PROGRAM_ID_HEX"))
    , m_pollTimer(new QTimer(this))
{
    connect(m_pollTimer, &QTimer::timeout, this, &WhisperWallBackend::refreshState);
    m_pollTimer->start(5000);
    // Initial fetch (deferred so the plugin widget is up first).
    QTimer::singleShot(500, this, &WhisperWallBackend::refreshState);
}

WhisperWallBackend::~WhisperWallBackend() = default;

QJsonObject WhisperWallBackend::baseArgs() const {
    return QJsonObject{
        {"wallet_path",    m_walletPath},
        {"sequencer_url",  m_sequencerUrl},
        {"program_id_hex", m_programIdHex},
    };
}

void WhisperWallBackend::dispatchFfi(const QString& operation, std::function<QString()> fn) {
    if (m_busy) return;
    m_busy = true;
    emit busyChanged();

    auto* watcher = new QFutureWatcher<QString>(this);
    connect(watcher, &QFutureWatcher<QString>::finished, this, [this, watcher, operation]() {
        handleFfiResult(operation, watcher->result());
        watcher->deleteLater();
        m_busy = false;
        emit busyChanged();
    });
    watcher->setFuture(QtConcurrent::run(fn));
}

void WhisperWallBackend::handleFfiResult(const QString& operation, const QString& result) {
    QJsonObject obj = QJsonDocument::fromJson(result.toUtf8()).object();
    if (!obj.value("success").toBool()) {
        m_lastError = obj.value("error").toString(result);
        emit lastErrorChanged();
        emit txError(operation, m_lastError);
        return;
    }
    m_lastError.clear();
    emit lastErrorChanged();

    if (obj.contains("tx_hash")) {
        m_lastTxHash = obj.value("tx_hash").toString();
        emit lastTxHashChanged();
        emit txSuccess(operation, m_lastTxHash);
        // Refresh state after a successful write.
        QTimer::singleShot(1000, this, &WhisperWallBackend::refreshState);
    }

    if (obj.contains("state")) {
        applyStateJson(obj.value("state").toObject());
    }
}

void WhisperWallBackend::applyStateJson(const QJsonObject& s) {
    QString whisper = s.value("latest_whisper").toString();
    QString tip     = s.value("last_tip").toString("0");
    int     count   = static_cast<int>(s.value("whisper_count").toDouble(0));
    bool    exists  = !s.value("admin").toString().isEmpty();

    if (m_latestWhisper != whisper) { m_latestWhisper = whisper; emit latestWhisperChanged(); }
    if (m_lastTip       != tip)     { m_lastTip       = tip;     emit lastTipChanged(); }
    if (m_whisperCount  != count)   { m_whisperCount  = count;   emit whisperCountChanged(); }
    if (m_wallExists    != exists)  { m_wallExists    = exists;  emit wallExistsChanged(); }
}

// ── Public slots ──────────────────────────────────────────────────────────────

void WhisperWallBackend::initialize(const QString& adminAccountId) {
    QJsonObject args = baseArgs();
    args["admin"] = adminAccountId;
    dispatchFfi("initialize", [args]() {
        return callFfiRaw(whisper_wall_initialize, args);
    });
}

void WhisperWallBackend::whisper(const QString& signerAccountId, const QString& msg) {
    QJsonObject args = baseArgs();
    args["signer"] = signerAccountId;
    args["msg"]    = msg;
    dispatchFfi("whisper", [args]() {
        return callFfiRaw(whisper_wall_whisper, args);
    });
}

void WhisperWallBackend::overwrite(const QString& signerAccountId, const QString& msg, const QString& tip) {
    QJsonObject args = baseArgs();
    args["signer"] = signerAccountId;
    args["msg"]    = msg;
    args["tip"]    = tip;
    dispatchFfi("overwrite", [args]() {
        return callFfiRaw(whisper_wall_overwrite, args);
    });
}

void WhisperWallBackend::drainJar(const QString& adminAccountId, const QString& recipientAccountId) {
    QJsonObject args = baseArgs();
    args["signer"]    = adminAccountId;
    args["recipient"] = recipientAccountId;
    dispatchFfi("drain_jar", [args]() {
        return callFfiRaw(whisper_wall_drain_jar, args);
    });
}

void WhisperWallBackend::refreshState() {
    if (m_programIdHex.isEmpty() || m_busy) return;
    QJsonObject args = baseArgs();
    // Fire-and-forget background poll — don't hold the QFuture.
    QThreadPool::globalInstance()->start([this, args]() {
        QString result = callFfiRaw(whisper_wall_fetch_state_json, args);
        QMetaObject::invokeMethod(this, [this, result]() {
            QJsonObject obj = QJsonDocument::fromJson(result.toUtf8()).object();
            if (obj.value("success").toBool() && obj.contains("state")) {
                applyStateJson(obj.value("state").toObject());
            }
        }, Qt::QueuedConnection);
    });
}
