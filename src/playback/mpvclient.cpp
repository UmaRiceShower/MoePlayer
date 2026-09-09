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
// eof 后查询播放列表位置的 request_id(判定是否最后一项)。
constexpr int kEofCheckRequestId = 997;
// 播放列表查询(end-file 后判定失败条目是占位还是真实集)的 request_id。
constexpr int kPlaylistCheckRequestId = 996;
// 快速重试退避(ms):用完转慢速重试等待网络恢复(用户换代理/换网后自动继续)。
constexpr int kFastRetryDelaysMs[] = {1000, 2000, 4000};
constexpr int kSlowRetryDelayMs = 15000;
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

QString MpvClient::findMoeHookScript()
{
    const QString appDir = QCoreApplication::applicationDirPath();
    const QString bundled = QDir(appDir).filePath(QStringLiteral("moe-hook.lua"));
    if (QFileInfo::exists(bundled))
        return bundled;
    // 开发:源码到 third_party/moe-hook.lua(构建目录在项目根下)。
    const QString src =
        QDir(appDir).filePath(QStringLiteral("../third_party/moe-hook.lua"));
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
    qInfo() << "MpvClient: deliver" << key << (s->listSet ? QStringLiteral("列表") : QStringLiteral("单条"));
    if (s->listSet) {
        // 全集播放列表模式:setEpisodeList 的 loadlist replace 已播第 0 条
        // (当前集真 URL);无需再 loadfile。
        return;
    }
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

void MpvClient::scheduleRetry(Session *s)
{
    const int fastCount = int(sizeof(kFastRetryDelaysMs) / sizeof(kFastRetryDelaysMs[0]));
    const bool slow = s->retryCount >= fastCount;
    const int delayMs = slow ? kSlowRetryDelayMs : kFastRetryDelaysMs[s->retryCount];
    ++s->retryCount;
    // OSD 提示:让用户看出是"在重连"而非卡死;慢速阶段说明恢复方式。
    sendJson(s, QJsonObject{
                    {QStringLiteral("command"),
                     QJsonArray{QStringLiteral("show-text"),
                                slow ? QStringLiteral("网络中断,持续重连中(网络恢复后自动继续)")
                                     : QStringLiteral("网络中断,正在重连…"),
                                3000}},
                });
    qWarning() << "MpvClient: 加载失败,第" << s->retryCount << "次重试,延迟" << delayMs
               << "ms 条目" << s->retryIndex << s->key;
    if (!s->retryTimer) {
        s->retryTimer = new QTimer(this);
        s->retryTimer->setSingleShot(true);
        connect(s->retryTimer, &QTimer::timeout, this, [this, key = s->key]() {
            Session *cur = sessionFor(key);
            if (!cur || cur->retryIndex < 0)
                return;
            // 播放列表模式:占位条目的 on_load hook 挂起时,mpv 会吞掉所有
            // 播放列表操作(实测:playlist-pos 变了但不加载)——先清空列表
            // (除当前)、放行挂起的占位,待 mpv 回到 idle 再重新灌入 m3u
            // (第 0 条 = 当前集真实 URL),实现"重连当前集"。
            if (cur->listSet && !cur->m3uPath.isEmpty()) {
                sendJson(cur, QJsonObject{
                                 {QStringLiteral("command"),
                                  QJsonArray{QStringLiteral("playlist-clear")}},
                             });
                if (!cur->pendingFileId.isEmpty()) {
                    const QString pending = cur->pendingFileId;
                    cur->pendingFileId.clear();
                    qInfo() << "MpvClient: 重试前放行挂起的占位" << pending << cur->key;
                    sendJson(cur, QJsonObject{
                                     {QStringLiteral("command"),
                                      QJsonArray{QStringLiteral("script-message-to"),
                                                 QStringLiteral("moe_hook"),
                                                 QStringLiteral("moe-url-ready"),
                                                 pending, QString()}},
                                 });
                }
                QTimer::singleShot(400, this, [this, key]() {
                    Session *c2 = sessionFor(key);
                    if (c2 && !c2->m3uPath.isEmpty()) {
                        qInfo() << "MpvClient: 重新灌入播放列表重试" << c2->key;
                        sendJson(c2, QJsonObject{
                                         {QStringLiteral("command"),
                                          QJsonArray{QStringLiteral("loadlist"),
                                                     c2->m3uPath, QStringLiteral("replace")}},
                                     });
                    }
                });
                return;
            }
            // 单条模式:直接重新加载(播放列表只有这一条)。
            sendJson(cur, QJsonObject{
                             {QStringLiteral("command"),
                              QJsonArray{QStringLiteral("loadfile"), cur->url,
                                         QStringLiteral("replace")}},
                         });
        });
    }
    s->retryTimer->start(delayMs);
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
         << QStringLiteral("--script=") + findMoeHookScript()
         // 播放列表面板显示条目标题(m3u EXTINF 解析的 title;官方
         // --osd-playlist-entry,见 options.rst)。
         << QStringLiteral("--osd-playlist-entry=title")
         // 底栏自定义"选集"按钮:打开官方播放列表面板(全集标题,经 on_load
         // hook 重定向到真实地址,不再依赖 MoePlayer 自造菜单)。
         << QStringLiteral("--script-opts=osc-custom_button_1_content=\\\u2388|选集|")
         << QStringLiteral("--script-opts=osc-custom_button_1_mbtn_left_command=script-binding select/select-playlist; script-message-to osc osc-hide")
         << QStringLiteral("--keep-open=yes")
         // 日志:terminal=yes 保留 stdout/stderr(转发到 MoePlayer 输出);
         // input-terminal=no 不从 stdin 读按键(控制走 IPC,防假 tty 阻塞)。
         << QStringLiteral("--terminal=yes")
         << QStringLiteral("--input-terminal=no")
         // 状态行:级别 MSGL_STATUS(common/msg.c:update_loglevel),高于 INFO;
         // all=info 会被过滤(非 tty 也无状态行输出),all=status 恢复。
         << QStringLiteral("--msg-level=all=status")
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
        qInfo() << "MpvClient: mpv 进程退出,退出码" << code;
        stopAndConsiderEnd(key, code != 0);
    });
    // mpv 日志转发:逐行接进 MoePlayer 输出。实测 mpv 日志走 stdout 而非
    // stderr(--terminal=yes 时控制台输出在 stdout),两个通道都接防漏。
    const auto forwardLog = [key = s->key, this](QByteArray data) {
        Session *cur = sessionFor(key);
        if (!cur || !cur->proc)
            return;
        const QList<QByteArray> lines = data.split('\n');
        for (const QByteArray &line : lines) {
            const QByteArray t = line.trimmed();
            if (t.isEmpty())
                continue;
            // 状态行(官方仅 tty 单行重绘;非 tty 每帧一行)加 \r 前缀:
            // 终端原地覆盖 = tty 效果;日志文件里为 \r 行,无损。
            const bool statusLine = t.contains("AV:") || t.contains(" V:")
                                    || t.contains(" A:V") || t.contains("Cache:");
            // 状态行:消息整体以 \r 开头(AppLog 识别后终端单行覆盖)。
            if (statusLine)
                qInfo().noquote() << "\r[mpv] " + QString::fromUtf8(t);
            else
                qInfo().noquote() << "[mpv]" << QString::fromUtf8(t);
        }
    };
    connect(s->proc, &QProcess::readyReadStandardOutput, this,
            [this, key = s->key, forwardLog]() {
        Session *cur = sessionFor(key);
        if (cur && cur->proc)
            forwardLog(cur->proc->readAllStandardOutput());
    });
    connect(s->proc, &QProcess::readyReadStandardError, this,
            [this, key = s->key, forwardLog]() {
        Session *cur = sessionFor(key);
        if (cur && cur->proc)
            forwardLog(cur->proc->readAllStandardError());
    });
    connect(s->proc, &QProcess::errorOccurred, this, [key = s->key, this](QProcess::ProcessError err) {
        qWarning() << "MpvClient: mpv 启动失败" << int(err) << "key" << key;
    });
    qInfo() << "MpvClient: 启动 mpv 进程" << s->key;
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
    if (!s || !s->sock || s->sock->state() != QLocalSocket::ConnectedState) {
        qDebug() << "MpvClient: IPC 未连接,命令丢弃" << (s ? s->key : QStringLiteral("无会话"));
        return;
    }
    const QByteArray data = QJsonDocument(obj).toJson(QJsonDocument::Compact) + '\n';
    s->sock->write(data);
}

void MpvClient::handleLine(Session *s, const QByteArray &line)
{
    QJsonParseError pe;
    const QJsonDocument doc = QJsonDocument::fromJson(line, &pe);
    if (pe.error != QJsonParseError::NoError || !doc.isObject()) {
        qWarning() << "MpvClient: IPC JSON 解析失败" << pe.errorString()
                   << QString::fromUtf8(line.left(160));
        return;
    }
    const QJsonObject obj = doc.object();
    if (obj.contains(QStringLiteral("request_id"))) {
        const int rid = obj.value(QStringLiteral("request_id")).toInt();
        if (rid == kReadyRequestId) {
            s->ready = true;
            qInfo() << "MpvClient: IPC 就绪" << s->key;
            flush(s);
        } else if (rid == kTrackListRequestId) {
            applyTrackSelection(s, obj.value(QStringLiteral("data")).toArray());
        } else if (rid == kPlaylistCheckRequestId) {
            const QJsonArray list = obj.value(QStringLiteral("data")).toArray();
            QString filename;
            int index = -1;
            for (int i = 0; i < list.size(); ++i) {
                const QJsonObject e = list.at(i).toObject();
                if (e.value(QStringLiteral("id")).toInt(-1) == s->failedEntryId) {
                    filename = e.value(QStringLiteral("filename")).toString();
                    index = i;
                    break;
                }
            }
            if (filename.isEmpty() || filename.startsWith(QLatin1String("moe://"))) {
                // 占位条目(或条目已不在列表):协商失败/网络,由 mpv 跳过继续。
                qWarning() << "MpvClient: end-file error,跳过当前条目" << s->key;
                return;
            }
            s->retryIndex = index;
            scheduleRetry(s);
        } else if (rid == kEofCheckRequestId) {
            // eof 后:最后一项才结束会话(playlist 无后续);否则 mpv 自动
            // 载入下一项(占位 → on_load hook 重定向)。
            const QJsonValue v = obj.value(QStringLiteral("data"));
            if (v.isDouble()) {
                const int pos = v.toInt();
                // 先存 pos 再判断:stopAndConsiderEnd 会销毁会话,其后
                // 不得再访问 s(否则 UAF)。
                s->pendingEofPos = pos;
                if (pos >= 0) {
                    sendJson(s, QJsonObject{
                                    {QStringLiteral("command"),
                                     QJsonArray{QStringLiteral("get_property"),
                                                QStringLiteral("playlist-count")}},
                                    {QStringLiteral("request_id"), kEofCheckRequestId + 1},
                                });
                } else {
                    // 无可查位置(空播放列表):正常结束。
                    stopAndConsiderEnd(s->key, false);
                }
            } else {
                stopAndConsiderEnd(s->key, false);
            }
        } else if (rid == kEofCheckRequestId + 1) {
            // playlist-count 响应:与 eof 时的 pos 比对。
            const QJsonValue v = obj.value(QStringLiteral("data"));
            const int count = v.isDouble() ? v.toInt() : 0;
            if (s->pendingEofPos < 0 || s->pendingEofPos >= count - 1)
                stopAndConsiderEnd(s->key, false);
            else
                s->pendingEofPos = -1;
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
        // on_load hook 路径(playlist 占位):QML 协商 meta 按 pendingFileId 归位;
        // 首集(用户点播)保持会话初值(pendingFileId 为空)。
        if (!s->pendingFileId.isEmpty()) {
            const QVariantMap pm = s->episodeMeta.value(s->pendingFileId);
            if (!pm.isEmpty())
                s->meta = pm;
            s->pendingFileId.clear();
        }
        s->loadIssued = true;
        // 续播:仅用户点播的集(meta 带 resumePositionTicks)seek 到上次
        // 位置;连播项协商不带该键,从零开始。
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
        qInfo() << "MpvClient: file-loaded" << s->meta.value(QStringLiteral("itemId")).toString();
        // 重试成功:恢复到失败前的位置,并复位重试状态。
        if (s->retryCount > 0) {
            if (s->retryPos > 0.5) {
                qInfo() << "MpvClient: 重试成功,恢复到" << s->retryPos << "s" << s->key;
                sendJson(s, QJsonObject{
                                {QStringLiteral("command"),
                                 QJsonArray{QStringLiteral("seek"), s->retryPos,
                                            QStringLiteral("absolute")}},
                            });
            }
            s->retryCount = 0;
            s->retryIndex = -1;
            s->retryPos = 0.0;
        }
        emit playbackStarted(s->meta.value(QStringLiteral("itemId")).toString());
        emit playbackContextChanged(s->meta);
        return;
    }
    if (evName == QLatin1String("end-file")) {
        const QString reason =
            ev.value(QStringLiteral("reason")).toString();
        if (reason == QLatin1String("error")) {
            // 加载失败:查询播放列表,按失败条目区分——占位条目(moe://ep/)
            // 协商失败 → 跳过(现状);真实集失败(网络中断)→ 退避重试,
            // 用户切好代理/网络后自动继续(见 scheduleRetry)。
            s->failedEntryId = ev.value(QStringLiteral("playlist_entry_id")).toInt(-1);
            s->retryPos = s->position;
            sendJson(s, QJsonObject{
                            {QStringLiteral("command"),
                             QJsonArray{QStringLiteral("get_property"),
                                        QStringLiteral("playlist")}},
                            {QStringLiteral("request_id"), kPlaylistCheckRequestId},
                        });
            return;
        }
        if (reason == QLatin1String("eof")) {
            // 是否最后一项:查询播放位置异步判定(playlist 可能下一项已开始)。
            sendJson(s, QJsonObject{
                            {QStringLiteral("command"),
                             QJsonArray{QStringLiteral("get_property"),
                                        QStringLiteral("playlist-pos")}},
                            {QStringLiteral("request_id"), kEofCheckRequestId},
                        });
        }
        // 其余(stop/quit 等):不结束(playlist 内部跳转/自动换集)。
        return;
    }
    if (evName == QLatin1String("client-message")) {
        // IPC 事件名 = client-message(MPV_EVENT_CLIENT_MESSAGE,序列化
        // 无 name 字段):args[0] 是消息名,args[1..] 是参数。moe-hook.lua
        // on_load 重定向请求:占位条目要真实地址。
        const QJsonArray args = ev.value(QStringLiteral("args")).toArray();
        if (args.size() >= 2 && args.at(0).toString() == QLatin1String("moe-url")) {
            s->pendingFileId = args.at(1).toString();
            qInfo() << "MpvClient: hook 请求" << s->pendingFileId;
            emit episodeUrlRequested(s->pendingFileId);
        }
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
        qInfo() << "MpvClient: 下发 loadfile" << s->key;
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
void MpvClient::setEpisodeList(const QVariantList &episodes,
                               const QString &currentItemId, int currentIndex,
                               const QString &url, const QVariantList &headers,
                               const QVariantMap &meta)
{
    Session *s = m_active;
    if (!s || !s->ready || episodes.isEmpty()) {
        qDebug() << "MpvClient: setEpisodeList 跳过(无会话/未就绪/空列表)";
        return;
    }
    if (!meta.isEmpty())
        s->episodeMeta.insert(currentItemId, meta);
    // 写 m3u:条目标题(m3u EXTINF,mpv demux_playlist.c 解析为 playlist
    // entry title,经 --osd-playlist-entry=title 显示)+ 占位地址
    // moe://ep/<id>(on_load hook 重定向)。
    const QString path = QDir::tempPath() + QStringLiteral("/moe-ep-") +
                         QUuid::createUuid().toString(QUuid::WithoutBraces) +
                         QStringLiteral(".m3u");
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qWarning() << "MpvClient: 不能写 m3u" << path << f.errorString();
        return;
    }
    // 旋转顺序:第 0 条 = 当前集(真 URL,标题一致);其后 = 当前集之后
    // 全集(占位),最后 = 前部(第 0 集..当前集-1,占位)。此前集条目均
    // 占位,经 on_load hook 重定向;本条真 URL passthrough。
    const int n = episodes.size();
    QByteArray body2 = "#EXTM3U\n";
    for (int k = 0; k < n; ++k) {
        const int i = (currentIndex + k) % n;
        const QVariantMap m = episodes.at(i).toMap();
        const QString id = m.value(QStringLiteral("id")).toString();
        QString title = m.value(QStringLiteral("title")).toString();
        if (title.isEmpty())
            title = id;
        body2 += "#EXTINF:0," + title.toUtf8() + "\n";
        body2 += (k == 0 ? url.toUtf8() : ("moe://ep/" + id.toUtf8())) + "\n";
    }
    f.write(body2);
    f.close();
    s->m3uPath = path; // 网络中断重试时重新灌入(见 scheduleRetry)
    if (!headers.isEmpty()) {
        QStringList fields;
        for (const QVariant &h : headers)
            fields << h.toString();
        sendJson(s, QJsonObject{
                        {QStringLiteral("command"),
                         QJsonArray{QStringLiteral("set_property"),
                                    QStringLiteral("http-header-fields"),
                                    fields.join(QLatin1Char(','))}},
                    });
    }
    // idle 时以 replace 灌入:mpv 直接播第 0 条(真 URL)。
    // (播放中 loadlist 会报错,官方行为;本方法在 deliver 前调用为 idle。)
    sendJson(s, QJsonObject{
                    {QStringLiteral("command"),
                     QJsonArray{QStringLiteral("loadlist"), path,
                                QStringLiteral("replace")}},
                });
    s->listSet = true;
    qInfo() << "MpvClient: 下发 loadlist" << s->key;
}

void MpvClient::deliverEpisodeUrl(const QString &itemId, const QString &url,
                                  const QVariantList &headers,
                                  const QVariantMap &meta,
                                  const QString &subtitleUrl)
{
    Session *s = m_active;
    if (!s || !s->ready) {
        qDebug() << "MpvClient: deliverEpisodeUrl 跳过(无活跃会话/未就绪)" << itemId;
        return;
    }
    if (!meta.isEmpty())
        s->episodeMeta.insert(itemId, meta);
    // 流头(可能跨服务器变化):切换全局头,后续加载生效。
    if (!headers.isEmpty()) {
        QStringList fields;
        for (const QVariant &h : headers)
            fields << h.toString();
        sendJson(s, QJsonObject{
                        {QStringLiteral("command"),
                         QJsonArray{QStringLiteral("set_property"),
                                    QStringLiteral("http-header-fields"),
                                    fields.join(QLatin1Char(','))}},
                    });
    }
    if (url.isEmpty())
        qWarning() << "MpvClient: 协商失败,放行占位条目" << itemId;
    // 应答 hook:lua 侧 set stream-open-filename(外挂字幕经
    // file-local-options/sub-file)后 cont;空 url = 协商失败(占位失败跳过)。
    // 脚本名 = 文件名去扩展并把非字母数字转下划线(scripting.c
    // script_name_from_filename:"moe-hook" → "moe_hook")。
    sendJson(s, QJsonObject{
                    {QStringLiteral("command"),
                     QJsonArray{QStringLiteral("script-message-to"),
                                QStringLiteral("moe_hook"),
                                QStringLiteral("moe-url-ready"), itemId,
                                url, subtitleUrl}},
                });
}

void MpvClient::reportStart(Session *s)
{
    if (!m_emby || !s->delivered)
        return;
    const QString sid = s->meta.value(QStringLiteral("playSessionId")).toString();
    const QString token = s->meta.value(QStringLiteral("token")).toString();
    if (sid.isEmpty() || token.isEmpty()) {
        qDebug() << "MpvClient: 跳过起播回传(sid/token 空)" << s->key;
        return;
    }
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
        qWarning() << "MpvClient: track-list 未找到" << type << "轨道 ordinal" << ordinal;
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
    // 目标轨已是当前选中轨时跳过 set:mpv 对同值设置也打印 Track switched
    // (src/player/command.c:6635 直接 mp_switch_track 无值比较),避免重复噪音。
    const auto currentlySelected = [&](const QString &type) -> int {
        for (const QJsonValue &v : trackList) {
            const QJsonObject t = v.toObject();
            if (t.value(QStringLiteral("type")).toString() != type)
                continue;
            if (t.value(QStringLiteral("selected")).toBool())
                return t.value(QStringLiteral("id")).toInt(-1);
        }
        return -1;
    };
    if (wantAid >= 0 && wantAid != currentlySelected(QLatin1String("audio")))
        sendJson(s, QJsonObject{{QStringLiteral("command"),
                                 QJsonArray{QStringLiteral("set_property"),
                                            QStringLiteral("aid"),
                                            QString::number(wantAid)}}});
    if (wantSid >= 0 && wantSid != currentlySelected(QLatin1String("sub")))
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
    if (sid.isEmpty() || token.isEmpty()) {
        qDebug() << "MpvClient: 跳过进度回传(sid/token 空)" << s->key;
        return;
    }
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
    if (sid.isEmpty() || token.isEmpty()) {
        qDebug() << "MpvClient: 跳过停止回传(sid/token 空)" << s->key;
        return;
    }
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
    if (s->retryTimer) {
        s->retryTimer->stop();
        s->retryTimer->deleteLater();
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
    if (!s) {
        qDebug() << "MpvClient: 无会话,忽略 seek" << seconds;
        return;
    }
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("seek"),
                                        QString::number(seconds),
                                        QStringLiteral("absolute")}}});
}

void MpvClient::setPause(bool p, const QString &itemId)
{
    Session *s = itemId.isEmpty() ? m_active : sessionFor(itemId);
    if (!s) {
        qDebug() << "MpvClient: 无会话,忽略 setPause";
        return;
    }
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("set_property"),
                                        QStringLiteral("pause"), p}}});
}

void MpvClient::setVolume(int v, const QString &itemId)
{
    Session *s = itemId.isEmpty() ? m_active : sessionFor(itemId);
    if (!s) {
        qDebug() << "MpvClient: 无会话,忽略 setVolume";
        return;
    }
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("set_property"),
                                        QStringLiteral("volume"), v}}});
}

void MpvClient::command(const QVariantList &params, const QString &itemId)
{
    Session *s = itemId.isEmpty() ? m_active : sessionFor(itemId);
    if (!s) {
        qDebug() << "MpvClient: 无会话,忽略 command";
        return;
    }
    QJsonArray arr;
    for (const QVariant &p : params)
        arr.append(QJsonValue::fromVariant(p));
    sendJson(s, QJsonObject{{QStringLiteral("command"), arr}});
}
