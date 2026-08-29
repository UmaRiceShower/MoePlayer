#include "playback/mpvclient.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QJsonValue>
#include <QLocalSocket>
#include <QProcess>
#include <QStringList>
#include <QTimer>
#include <QDir>
#include <QFile>
#include <QUuid>

#include "core/configmanager.h"
#include "core/embyclient.h"

namespace {
// 播放状态回传节流(与 QML Constants.progressReportMs 一致)。
constexpr qint64 kProgressReportMs = 10000;
// 每 10 分钟 Ping 维持服务器会话。
constexpr qint64 kPingMs = 600000;
// Emby Ticks → 秒。
constexpr double kTicksPerSecond = 1e7;
// ping 就绪探测的 request_id(无业务含义)。
constexpr int kReadyRequestId = 999;
// 查询 track-list 的 request_id(file-loaded 后发,用于所选轨匹配)。
constexpr int kTrackListRequestId = 998;
} // namespace

MpvClient::MpvClient(EmbyClient *emby, ConfigManager *config, QObject *parent)
    : QObject(parent)
    , m_emby(emby)
    , m_config(config)
{
}

void MpvClient::shutdownAll()
{
    // 应用退出:终止全部 mpv 子进程(避免残留窗口/进程)。
    const auto keys = m_sessions.keys();
    for (const QString &k : keys) {
        Session *s = m_sessions.value(k);
        if (s)
            destroySession(s, false, false);
    }
    m_sessions.clear();
}

MpvClient::~MpvClient()
{
    shutdownAll();
}

QString MpvClient::findMpvBinary()
{
    const QByteArray env = qgetenv("MOEPLAYER_MPV");
    if (!env.isEmpty())
        return QString::fromLocal8Bit(env);
    // 发版内封:应用目录放 mpv。
    const QString bundled =
        QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("mpv"));
    if (QFileInfo::exists(bundled))
        return bundled;
    // PATH 上的系统 mpv(QProcess 自行解析)。
    return QStringLiteral("mpv");
}

QString MpvClient::findOscScript()
{
    const QString appDir = QCoreApplication::applicationDirPath();
    const QString bundled = QDir(appDir).filePath(QStringLiteral("osc.lua"));
    if (QFileInfo::exists(bundled))
        return bundled;
    // 开发:源码到 third_party/osc.lua(构建目录在项目根下)。
    const QString src =
        QDir(appDir).filePath(QStringLiteral("../third_party/osc.lua"));
    if (QFileInfo::exists(src))
        return src;
    return bundled; // 缺失时由 mpv --script 报错,兜底返回应用目录路径。
}

MpvClient::Session *MpvClient::sessionFor(const QString &key) const
{
    return m_sessions.value(key, nullptr);
}

MpvClient::Session *MpvClient::createSession(const QString &key)
{
    auto *s = new Session;
    s->key = key;
    m_sessions.insert(key, s);
    m_active = s;
    return s;
}

bool MpvClient::startPending(const QVariantMap &meta)
{
    QString key = meta.value(QStringLiteral("itemId")).toString();
    if (key.isEmpty())
        key = QStringLiteral("session-%1").arg(++m_nextKeyId);
    if (m_sessions.contains(key))
        return false; // 同条目并行播放防重(与旧 pendingPlaybackWindows 语义一致)。
    Session *s = createSession(key);
    s->meta = meta;
    spawnMpv(s);
    return true;
}

void MpvClient::deliver(const QString &url, const QVariantList &headers,
                        const QVariantMap &meta)
{
    const QString key = meta.value(QStringLiteral("itemId")).toString();
    Session *s = sessionFor(key);
    if (!s) {
        // 理论上 startPending 已建会话;防御:直接建并起播。
        s = createSession(key.isEmpty() ? QStringLiteral("session-%1").arg(++m_nextKeyId) : key);
        spawnMpv(s);
    }
    s->meta = meta;
    s->delivered = true;
    reportStart(s);
    enqueueLoad(s, url, headers);
}

void MpvClient::fail(const QString &itemId, const QString &message)
{
    Q_UNUSED(message);
    Session *s = sessionFor(itemId);
    if (!s)
        return;
    // 协商失败:尚未起播,静默关窗(不回传、不刷新)。
    destroySession(s, false, false);
}

void MpvClient::start(const QString &url, const QVariantList &headers,
                      const QVariantMap &meta)
{
    QString key = meta.value(QStringLiteral("itemId")).toString();
    if (key.isEmpty())
        key = QStringLiteral("session-%1").arg(++m_nextKeyId);
    if (m_sessions.contains(key)) {
        // 已存在同条目会话:更新地址续播。
        Session *s = sessionFor(key);
        s->meta = meta;
        if (!s->delivered) {
            s->delivered = true;
            reportStart(s);
        }
        enqueueLoad(s, url, headers);
        return;
    }
    Session *s = createSession(key);
    s->meta = meta;
    s->delivered = true;
    reportStart(s);
    spawnMpv(s);
    enqueueLoad(s, url, headers);
}

void MpvClient::spawnMpv(Session *s)
{
    // 临时 unix socket(--input-ipc-server):fd 继承的 --input-ipc-client 在
    // mpv 侧不生效,改用文件 socket + QLocalSocket(稳定,跨平台)。
    const QString sockPath = QDir::tempPath() + QStringLiteral("/moe-mpv-") +
                             QUuid::createUuid().toString(QUuid::WithoutBraces) +
                             QStringLiteral(".sock");
    s->sockPath = sockPath;

    const QString mpvBin = findMpvBinary();
    const QString osc = findOscScript();

    QStringList args;
    args << QStringLiteral("--input-ipc-server=") + sockPath
         << QStringLiteral("--force-window=yes")
         << QStringLiteral("--idle=yes")
         << QStringLiteral("--osc=no")
         << QStringLiteral("--script=") + osc
         << QStringLiteral("--keep-open=yes")
         << QStringLiteral("--terminal=no")
         << QStringLiteral("--msg-level=all=warn")
         << QStringLiteral("--input-default-bindings=yes")
         << QStringLiteral("--input-cursor=yes")
         << QStringLiteral("--cache=yes")
         << QStringLiteral("--stop-screensaver=yes");
    // 播放流 HTTP 代理(仅 http(s);空=直连)。https 目标走 CONNECT 隧道。
    const QString proxy = m_config ? m_config->proxy() : QString();
    if (proxy.startsWith(QStringLiteral("http://")) ||
        proxy.startsWith(QStringLiteral("https://")))
        args << QStringLiteral("--http-proxy=") + proxy;

    s->proc = new QProcess(this);
    s->proc->setProgram(mpvBin);
    s->proc->setArguments(args);
    connect(s->proc, &QProcess::finished, this, [key = s->key, this](int code, QProcess::ExitStatus) {
        stopAndConsiderEnd(key, code != 0);
    });
    s->proc->start();

    // QLocalSocket 连接(--input-ipc-server 是 unix socket 文件)。mpv 建
    // socket 需短暂时间,连接失败则定时重试,直到 connected。
    s->sock = new QLocalSocket(this);
    connect(s->sock, &QLocalSocket::connected, this, [key = s->key, this]() {
        Session *cur = sessionFor(key);
        if (!cur)
            return;
        if (cur->connectRetry)
            cur->connectRetry->stop();
        // IPC 就绪探测:收到应答即 flush 已排队命令。
        sendJson(cur, QJsonObject{
                          {QStringLiteral("command"),
                           QJsonArray{QStringLiteral("get_property"), QStringLiteral("mpv-version")}},
                          {QStringLiteral("request_id"), kReadyRequestId},
                      });
    });
    connect(s->sock, &QLocalSocket::readyRead, this, [key = s->key, this]() {
        Session *cur = sessionFor(key);
        if (!cur)
            return;
        cur->buf.append(cur->sock->readAll());
        int idx = -1;
        while ((idx = cur->buf.indexOf('\n')) >= 0) {
            const QByteArray line = cur->buf.left(idx).trimmed();
            cur->buf.remove(0, idx + 1);
            if (!line.isEmpty()) {
                handleLine(cur, line);
                // handleLine 可能因 end-file 等结束会话(destroySession →
                // delete cur),循环不能再访问 cur->buf,立即返回。
                if (sessionFor(key) != cur)
                    return;
            }
        }
    });
    s->connectRetry = new QTimer(this);
    s->connectRetry->setInterval(150);
    connect(s->connectRetry, &QTimer::timeout, this, [key = s->key, this]() {
        Session *cur = sessionFor(key);
        if (!cur || !cur->sock)
            return;
        if (cur->sock->state() == QLocalSocket::ConnectedState) {
            cur->connectRetry->stop();
            return;
        }
        cur->sock->abort();
        cur->sock->connectToServer(cur->sockPath);
    });
    s->sock->connectToServer(s->sockPath);
    s->connectRetry->start();
}

void MpvClient::sendJson(Session *s, const QJsonObject &obj)
{
    if (!s || !s->sock || s->sock->state() != QLocalSocket::ConnectedState)
        return;
    const QByteArray data = QJsonDocument(obj).toJson(QJsonDocument::Compact) + '\n';
    s->sock->write(data);
}

void MpvClient::handleLine(Session *s, const QByteArray &line)
{
    QJsonParseError pe;
    const QJsonDocument doc = QJsonDocument::fromJson(line, &pe);
    if (pe.error != QJsonParseError::NoError || !doc.isObject())
        return;
    const QJsonObject obj = doc.object();
    if (obj.contains(QStringLiteral("request_id"))) {
        const int rid = obj.value(QStringLiteral("request_id")).toInt();
        if (rid == kReadyRequestId) {
            s->ready = true;
            flush(s);
        } else if (rid == kTrackListRequestId) {
            applyTrackSelection(s, obj.value(QStringLiteral("data")).toArray());
        }
        return;
    }
    if (obj.contains(QStringLiteral("event")))
        handleEvent(s, obj);
}

void MpvClient::handleEvent(Session *s, const QJsonObject &ev)
{
    const QString evName = ev.value(QStringLiteral("event")).toString();

    if (evName == QLatin1String("property-change")) {
        const QString name = ev.value(QStringLiteral("name")).toString();
        const QJsonValue data = ev.value(QStringLiteral("data"));
        if (name == QLatin1String("time-pos")) {
            s->position = data.isDouble() ? data.toDouble() : s->position;
            reportProgress(s, false);
        } else if (name == QLatin1String("duration")) {
            s->duration = data.isDouble() ? data.toDouble() : s->duration;
        } else if (name == QLatin1String("pause")) {
            s->paused = data.isBool() ? data.toBool() : s->paused;
            reportProgress(s, true);
        }
        return;
    }
    if (evName == QLatin1String("file-loaded")) {
        s->loadIssued = true;
        // 续播:文件就绪后 seek 到上次位置。
        if (s->meta.contains(QStringLiteral("resumePositionTicks"))) {
            const double ticks = s->meta.value(QStringLiteral("resumePositionTicks")).toDouble();
            if (ticks > 0.0)
                sendJson(s, QJsonObject{
                                {QStringLiteral("command"),
                                 QJsonArray{QStringLiteral("seek"),
                                           QString::number(ticks / kTicksPerSecond),
                                           QStringLiteral("absolute")}},
                            });
        }
        // 文件就绪后查 track-list,匹配 Emby 所选轨(标题/语言/编码/序号)
        // 得到 mpv 数字 id 再 set aid/sid(aid/sid 仅接受数字 id)。
        sendJson(s, QJsonObject{
                        {QStringLiteral("command"),
                         QJsonArray{QStringLiteral("get_property"),
                                    QStringLiteral("track-list")}},
                        {QStringLiteral("request_id"), kTrackListRequestId},
                    });
        emit playbackStarted(s->key);
        return;
    }
    if (evName == QLatin1String("end-file")) {
        const QString reason =
            ev.value(QStringLiteral("reason")).toString();
        const bool errored = (reason == QLatin1String("error"));
        stopAndConsiderEnd(s->key, errored);
        return;
    }
}

void MpvClient::observe(Session *s)
{
    // id 1/2/3:time-pos/duration/pause(回传与进度所需;UI 由 mpv osc 承担)。
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("observe_property"), 1,
                                        QStringLiteral("time-pos")}}});
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("observe_property"), 2,
                                        QStringLiteral("duration")}}});
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("observe_property"), 3,
                                        QStringLiteral("pause")}}});
}

void MpvClient::flush(Session *s)
{
    if (!s->ready)
        return;
    // observe 只发一次(首次 flush 时 url 可能尚未就绪,先观察属性);
    // loadfile 幂等:url 就绪后补发,不再被一次 flush 挡住。
    if (!s->observeSent) {
        s->observeSent = true;
        observe(s);
    }
    if (!s->url.isEmpty() && !s->loadIssued) {
        if (!s->headers.isEmpty()) {
            QStringList fields;
            for (const QVariant &h : s->headers)
                fields << h.toString();
            sendJson(s, QJsonObject{
                            {QStringLiteral("command"),
                             QJsonArray{QStringLiteral("set_property"),
                                        QStringLiteral("http-header-fields"),
                                        fields.join(QLatin1Char(','))}},
                        });
        }
        // 外挂字幕:随 loadfile 第 4 参 options 挂 sub-file(文件加载时生效,
        // 避免 loadfile 前 sub-add 无文件可挂)。官方:第 3 参是 insertion
        // index,用第 4 参时必须占位 -1(mpv 0.38+);options 经 IPC 为
        // MPV_FORMAT_NODE_MAP,值须为字符串。无字幕时省略 index/options 传 3 参。
        // 加载后由 applyTrackSelection 按 ordinal 取 track-list 数字 id 选中。
        const QString subUrl =
            s->meta.value(QStringLiteral("selectedSubtitleUrl")).toString();
        const int subOrd =
            s->meta.contains(QStringLiteral("selectedSubtitleOrdinal"))
                ? s->meta.value(QStringLiteral("selectedSubtitleOrdinal")).toInt() : -1;
        if (subOrd >= 0 && !subUrl.isEmpty()) {
            QJsonObject loadOpts;
            loadOpts.insert(QStringLiteral("sub-file"), subUrl);
            sendJson(s, QJsonObject{
                            {QStringLiteral("command"),
                             QJsonArray{QStringLiteral("loadfile"), s->url,
                                        QStringLiteral("replace"), -1, loadOpts}},
                        });
        } else {
            sendJson(s, QJsonObject{
                            {QStringLiteral("command"),
                             QJsonArray{QStringLiteral("loadfile"), s->url,
                                        QStringLiteral("replace")}},
                        });
        }
        s->loadIssued = true;
    }
}

void MpvClient::enqueueLoad(Session *s, const QString &url,
                            const QVariantList &headers)
{
    s->url = url;
    s->headers = headers;
    s->delivered = true;
    // socket 已就绪则直接下发;否则等 flush。
    if (s->ready)
        flush(s);
}

void MpvClient::reportStart(Session *s)
{
    if (!m_emby || !s->delivered)
        return;
    const QString sid = s->meta.value(QStringLiteral("playSessionId")).toString();
    const QString token = s->meta.value(QStringLiteral("token")).toString();
    if (sid.isEmpty() || token.isEmpty())
        return;
    const double pos =
        s->meta.value(QStringLiteral("resumePositionTicks")).toDouble() / kTicksPerSecond;
    m_emby->reportPlaybackStart(
        s->meta.value(QStringLiteral("serverUrl")).toString(),
        token, s->meta.value(QStringLiteral("userId")).toString(),
        s->meta.value(QStringLiteral("itemId")).toString(),
        s->meta.value(QStringLiteral("mediaSourceId")).toString(),
        sid, s->meta.value(QStringLiteral("playMethod")).toString(), pos);
    // 每 10 分钟 Ping 维持服务器会话(原自绘窗口的定时器,迁到会话内)。
    if (!s->pingTimer) {
        s->pingTimer = new QTimer(this);
        s->pingTimer->setInterval(kPingMs);
        const QString serverUrl =
            s->meta.value(QStringLiteral("serverUrl")).toString();
        const QString userId = s->meta.value(QStringLiteral("userId")).toString();
        connect(s->pingTimer, &QTimer::timeout, this,
                [this, serverUrl, token, userId, sid]() {
                    m_emby->reportPlaybackPing(serverUrl, token, userId, sid);
                });
        s->pingTimer->start();
    }
}

// 文件加载后按所选轨选 mpv 数字 id。
// 不依赖容器 Index/ff-index/src-id/title,转码重排/demuxer 差异均不影响。
void MpvClient::applyTrackSelection(Session *s, const QJsonArray &trackList)
{
    if (trackList.isEmpty())
        return;
    // QVariant::toInt 无默认参数(QJsonValue::toInt 才有);缺失键回退 -1。
    const auto metaInt = [&](const char *k) -> int {
        const QString key = QString::fromUtf8(k);
        return s->meta.contains(key) ? s->meta.value(key).toInt() : -1;
    };

    // 字幕显式关闭(-2):直接 sid no。
    const int subOrdinal = metaInt("selectedSubtitleOrdinal");
    if (subOrdinal == -2) {
        sendJson(s, QJsonObject{{QStringLiteral("command"),
                                 QJsonArray{QStringLiteral("set_property"),
                                            QStringLiteral("sid"),
                                            QStringLiteral("no")}}});
    }

    // 取某类型("audio"/"sub")同类第 ordinal 条的 mpv 数字 id。
    // 外挂字幕(external=true)经 sub-file 挂上,在 track-list 中排内封后,
    // 与详情页「内封+外挂」的 ordinal 序列一致。
    const auto idAtOrdinal = [&](const QString &type, int ordinal) -> int {
        if (ordinal < 0)
            return -1;
        int n = 0;
        for (const QJsonValue &v : trackList) {
            const QJsonObject t = v.toObject();
            if (t.value(QStringLiteral("type")).toString() != type)
                continue;
            if (n == ordinal)
                return t.value(QStringLiteral("id")).toInt(-1);
            ++n;
        }
        return -1;
    };

    const int audioOrdinal = metaInt("selectedAudioOrdinal");
    // 音轨显式关闭(-2):aid no;否则按 ordinal 选(>=0 才有目标)。
    if (audioOrdinal == -2)
        sendJson(s, QJsonObject{{QStringLiteral("command"),
                                 QJsonArray{QStringLiteral("set_property"),
                                            QStringLiteral("aid"),
                                            QStringLiteral("no")}}});
    const int wantAid = audioOrdinal >= 0 ? idAtOrdinal(QStringLiteral("audio"), audioOrdinal) : -1;
    const int wantSid = subOrdinal == -2 ? -1
                                         : idAtOrdinal(QStringLiteral("sub"), subOrdinal);
    if (wantAid >= 0)
        sendJson(s, QJsonObject{{QStringLiteral("command"),
                                 QJsonArray{QStringLiteral("set_property"),
                                            QStringLiteral("aid"),
                                            QString::number(wantAid)}}});
    if (wantSid >= 0)
        sendJson(s, QJsonObject{{QStringLiteral("command"),
                                 QJsonArray{QStringLiteral("set_property"),
                                            QStringLiteral("sid"),
                                            QString::number(wantSid)}}});
}

void MpvClient::reportProgress(Session *s, bool force)
{
    if (!m_emby || !s->delivered || s->ended)
        return;
    const QString sid = s->meta.value(QStringLiteral("playSessionId")).toString();
    const QString token = s->meta.value(QStringLiteral("token")).toString();
    if (sid.isEmpty() || token.isEmpty())
        return;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (!force && (now - s->lastReport < kProgressReportMs))
        return;
    s->lastReport = now;
    m_emby->reportPlaybackProgress(
        s->meta.value(QStringLiteral("serverUrl")).toString(),
        token, s->meta.value(QStringLiteral("userId")).toString(),
        s->meta.value(QStringLiteral("itemId")).toString(),
        s->meta.value(QStringLiteral("mediaSourceId")).toString(),
        sid, s->meta.value(QStringLiteral("playMethod")).toString(),
        s->position, s->paused);
}

void MpvClient::reportStopped(Session *s)
{
    if (!m_emby || !s->delivered)
        return;
    const QString sid = s->meta.value(QStringLiteral("playSessionId")).toString();
    const QString token = s->meta.value(QStringLiteral("token")).toString();
    if (sid.isEmpty() || token.isEmpty())
        return;
    m_emby->reportPlaybackStopped(
        s->meta.value(QStringLiteral("serverUrl")).toString(),
        token, s->meta.value(QStringLiteral("userId")).toString(),
        s->meta.value(QStringLiteral("itemId")).toString(),
        s->meta.value(QStringLiteral("mediaSourceId")).toString(),
        sid, s->position);
}

void MpvClient::stopAndConsiderEnd(QString key, bool errored)
{
    Session *s = sessionFor(key);
    if (!s || s->ended)
        return;
    s->ended = true;
    // 结束前补一次停止回传(把最后位置写给服务器)。
    reportStopped(s);
    const bool played = s->loadIssued;
    destroySession(s, false, false);
    if (played)
        emit playbackFinished(key, errored);
}

void MpvClient::destroySession(Session *s, bool playEnded, bool errored)
{
    Q_UNUSED(playEnded);
    Q_UNUSED(errored);
    if (!s)
        return;
    if (s->pingTimer) {
        s->pingTimer->stop();
        s->pingTimer->deleteLater();
    }
    if (s->connectRetry) {
        s->connectRetry->stop();
        s->connectRetry->deleteLater();
    }
    if (s->sock) {
        // 断开捕获 Session* 的 lambda,避免删除后再触发。
        s->sock->disconnect(this);
        s->sock->abort();
        s->sock->deleteLater();
    }
    if (!s->sockPath.isEmpty())
        QFile::remove(s->sockPath);
    if (s->proc) {
        // 断开 finished/事件连接,再终止:lambda 捕获 Session*,禁用后再 kill
        // 避免 finished 回调用到已删除的 s。
        s->proc->disconnect(this);
        s->proc->kill();
        s->proc->deleteLater();
        s->proc = nullptr;
    }
    m_sessions.remove(s->key);
    if (m_active == s)
        m_active = nullptr;
    delete s;
}

void MpvClient::seek(double seconds, const QString &itemId)
{
    Session *s = itemId.isEmpty() ? m_active : sessionFor(itemId);
    if (s)
        sendJson(s, QJsonObject{{QStringLiteral("command"),
                                 QJsonArray{QStringLiteral("seek"),
                                            QString::number(seconds),
                                            QStringLiteral("absolute")}}});
}

void MpvClient::setPause(bool p, const QString &itemId)
{
    Session *s = itemId.isEmpty() ? m_active : sessionFor(itemId);
    if (s)
        sendJson(s, QJsonObject{{QStringLiteral("command"),
                                 QJsonArray{QStringLiteral("set_property"),
                                            QStringLiteral("pause"), p}}});
}

void MpvClient::setVolume(int v, const QString &itemId)
{
    Session *s = itemId.isEmpty() ? m_active : sessionFor(itemId);
    if (s)
        sendJson(s, QJsonObject{{QStringLiteral("command"),
                                 QJsonArray{QStringLiteral("set_property"),
                                            QStringLiteral("volume"), v}}});
}

void MpvClient::command(const QVariantList &params, const QString &itemId)
{
    Session *s = itemId.isEmpty() ? m_active : sessionFor(itemId);
    if (!s)
        return;
    QJsonArray arr;
    for (const QVariant &p : params)
        arr.append(QJsonValue::fromVariant(p));
    sendJson(s, QJsonObject{{QStringLiteral("command"), arr}});
}
