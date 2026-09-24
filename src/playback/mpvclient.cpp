#include "playback/mpvclient.h"

#if defined(Q_OS_WIN)
// CREATE_NO_WINDOW 需要;防御宏避免 windows.h 的 min/max 宏污染本文件。
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif

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
#include <QStandardPaths>
#include <QStringList>
#include <QTimer>
#include <QFile>
#include <QUuid>

#include "core/configmanager.h"
#include "core/embyclient.h"
#include "playback/mpvvideoitem.h"

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
// 面板轨道查询(播放页 refreshTracks)。
constexpr int kTracksRequestId = 992;
// 章节查询(播放页进度条刻度)。
constexpr int kChaptersRequestId = 991;
// 超分回读:glsl-shaders 挂载列表 / video-params / osd-dimensions。
constexpr int kSuperResListRequestId = 995;
constexpr int kSuperResVideoRequestId = 994;
constexpr int kSuperResOutputRequestId = 993;
// 快速重试退避(ms):用完转慢速重试等待网络恢复(用户换代理/换网后自动继续)。
constexpr int kFastRetryDelaysMs[] = {1000, 2000, 4000};
constexpr int kSlowRetryDelayMs = 15000;
} // namespace

MpvClient::MpvClient(EmbyClient *emby, ConfigManager *config, QObject *parent)
    : QObject(parent)
    , m_emby(emby)
    , m_config(config)
{
    // 超分档位变化(设置界面/配置文件热重载/mpv 内快捷键回传)即时应用到
    // 所有在线会话。
    if (m_config) {
        connect(m_config, &ConfigManager::superResChanged, this, [this]() {
            const QString id = m_config->superRes();
            for (Session *s : m_sessions)
                applySuperRes(s, id, true);
        });
    }
}

void MpvClient::shutdownAll()
{
    // 应用退出:先补 Stopped 回传(播到一半退出,进度要落服务器),
    // 再终止全部 mpv 子进程(避免残留窗口/进程)。
    bool reported = false;
    const auto keys = m_sessions.keys();
    for (const QString &k : keys) {
        Session *s = m_sessions.value(k);
        if (s && s->loadIssued && !s->ended) {
            reportStopped(s);
            reported = true;
        }
    }
    if (reported) {
        // 回传是异步 POST:退出路径事件循环将停,给网络一小窗发出去。
        QEventLoop loop;
        QTimer::singleShot(600, &loop, &QEventLoop::quit);
        loop.exec();
    }
    for (const QString &k : keys) {
        Session *s = m_sessions.value(k);
        if (s)
            destroySession(s);
    }
    m_sessions.clear();
}

MpvClient::~MpvClient()
{
    shutdownAll();
}

bool MpvClient::embeddedAvailable() const
{
    return MpvEmbeddedCore::runtimeAvailable();
}

bool MpvClient::embeddedPreferred() const
{
    if (!embeddedAvailable())
        return false;
    return !m_config || m_config->playerBackend() != QLatin1String("external");
}

void MpvClient::attachEmbedded(QObject *coreObj, const QString &itemId)
{
    auto *core = qobject_cast<MpvEmbeddedCore *>(coreObj);
    if (!core) {
        qWarning() << "MpvClient: attachEmbedded 收到非 MpvEmbeddedCore 对象";
        return;
    }
    Session *s = sessionFor(itemId);
    if (!s) {
        qWarning() << "MpvClient: attachEmbedded 找不到会话" << itemId;
        return;
    }
    if (s->embedded == core && s->ready)
        return;
    core->disconnect(this);
    s->embedded = core;
    const QString key = s->key;
    connect(core, &MpvEmbeddedCore::jsonReceived, this, [this, key](const QJsonObject &obj) {
        Session *cur = sessionFor(key);
        if (cur)
            handleJson(cur, obj);
    });
    connect(core, &MpvEmbeddedCore::terminated, this, [this, key]() {
        stopAndConsiderEnd(key, true);
    });
    connect(core, &QObject::destroyed, this, [this, key]() {
        if (Session *cur = sessionFor(key))
            cur->embedded = nullptr;
    });
    s->ready = true;
    qInfo() << "MpvClient: 内嵌会话已绑定" << key;
    flush(s);
}

void MpvClient::stop(const QString &itemId)
{
    stopAndConsiderEnd(itemId, false);
}

void MpvClient::refreshTracks(const QString &itemId)
{
    Session *s = itemId.isEmpty() ? m_active : sessionFor(itemId);
    if (!s)
        return;
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("get_property"),
                                        QStringLiteral("track-list")}},
                            {QStringLiteral("request_id"), kTracksRequestId}});
}

void MpvClient::selectTrack(const QString &itemId, const QString &type, int mpvId)
{
    Session *s = itemId.isEmpty() ? m_active : sessionFor(itemId);
    if (!s)
        return;
    const QString prop = type == QLatin1String("audio") ? QStringLiteral("aid")
                                                        : QStringLiteral("sid");
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("set_property"), prop,
                                        mpvId < 0 ? QStringLiteral("no")
                                                  : QString::number(mpvId)}}});
    refreshTracks(s->key);
}

void MpvClient::refreshChapters(const QString &itemId)
{
    Session *s = itemId.isEmpty() ? m_active : sessionFor(itemId);
    if (!s)
        return;
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("get_property"),
                                        QStringLiteral("chapter-list")}},
                            {QStringLiteral("request_id"), kChaptersRequestId}});
}

QVariantMap MpvClient::previewInfo(const QString &itemId) const
{
    const Session *s = itemId.isEmpty() ? m_active : sessionFor(itemId);
    if (!s || s->url.isEmpty())
        return {};
    return QVariantMap{{QStringLiteral("url"), s->url},
                       {QStringLiteral("headers"), s->headers}};
}

void MpvClient::setEmbeddedOutputSize(const QString &itemId, double w, double h)
{
    Session *s = itemId.isEmpty() ? m_active : sessionFor(itemId);
    if (!s)
        return;
    s->outW = int(w);
    s->outH = int(h);
    if (s->superResPreset != QLatin1String("off"))
        requestSuperResState(s);
}

void MpvClient::playEpisode(const QString &itemId, const QString &episodeId)
{
    Session *s = itemId.isEmpty() ? m_active : sessionFor(itemId);
    if (!s || s->playlistIds.isEmpty())
        return;
    const int idx = s->playlistIds.indexOf(episodeId);
    if (idx < 0) {
        qWarning() << "MpvClient: playEpisode 找不到条目" << episodeId;
        return;
    }
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("playlist-play-index"), idx}}});
}

QString MpvClient::findMpvBinary()
{
    const QByteArray env = qgetenv("MOEPLAYER_MPV");
    if (!env.isEmpty())
        return QString::fromLocal8Bit(env);
    // 发版内封:应用目录放 mpv(Windows 可执行名为 mpv.exe)。
#ifdef Q_OS_WIN
    const QString bundled =
        QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("mpv.exe"));
#else
    const QString bundled =
        QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("mpv"));
#endif
    if (QFileInfo::exists(bundled))
        return bundled;
    // PATH 上的系统 mpv(QProcess 自行解析)。
    return QStringLiteral("mpv");
}

QString MpvClient::findScript(const QString &fileName)
{
    const QString appDir = QCoreApplication::applicationDirPath();
    // 旁置布局(仅开发构建:build/lua/ 与可执行文件同级)。
    const QString bundled = QDir(appDir).filePath(QStringLiteral("lua/") + fileName);
    if (QFileInfo::exists(bundled))
        return bundled;
    // 安装布局(DEB/RPM 与 AppImage/Flatpak 的 AppDir 同构:bin/ + ../share/)。
    const QString installed =
        QDir(appDir).filePath(QStringLiteral("../share/moeplayer/lua/") + fileName);
    if (QFileInfo::exists(installed))
        return installed;
    return bundled; // 缺失时由 mpv --script 报错,兜底返回旁置路径。
}

QString MpvClient::findMoeHookScript()
{
    return findScript(QStringLiteral("moe-hook.lua"));
}


QString MpvClient::findShader(const QString &fileName)
{
    const QString appDir = QCoreApplication::applicationDirPath();
    // 旁置布局(仅开发构建:build/shaders/ 与可执行文件同级)。
    const QString bundled = QDir(appDir).filePath(QStringLiteral("shaders/") + fileName);
    if (QFileInfo::exists(bundled))
        return bundled;
    // 安装布局(DEB/RPM 与 AppImage/Flatpak 的 AppDir 同构:bin/ + ../share/)。
    const QString installed =
        QDir(appDir).filePath(QStringLiteral("../share/moeplayer/shaders/") + fileName);
    if (QFileInfo::exists(installed))
        return installed;
    return bundled; // 缺失时由 mpv 报错,兜底返回旁置路径。
}

namespace {

// Anime4K v4.0.1 官方预设链:文件名顺序即 shader 处理顺序,同一文件不得出现
// 两次(官方 Advanced 文档)。A/B/C 为一次放大(+可选 AutoDownscalePre 夹在两次
// 放大之间),A+/B+/C+A 为二次放大(仅在放大比 ≥2 倍时使用)。
const char *const kSrModeA[] = {
    "Anime4K_Clamp_Highlights.glsl",
    "Anime4K_Restore_CNN_VL.glsl",
    "Anime4K_Upscale_CNN_x2_VL.glsl",
    "Anime4K_AutoDownscalePre_x2.glsl",
    "Anime4K_AutoDownscalePre_x4.glsl",
    "Anime4K_Upscale_CNN_x2_M.glsl",
};
const char *const kSrModeAPlus[] = {
    "Anime4K_Clamp_Highlights.glsl",
    "Anime4K_Restore_CNN_VL.glsl",
    "Anime4K_Upscale_CNN_x2_VL.glsl",
    "Anime4K_Restore_CNN_M.glsl",
    "Anime4K_AutoDownscalePre_x2.glsl",
    "Anime4K_AutoDownscalePre_x4.glsl",
    "Anime4K_Upscale_CNN_x2_M.glsl",
};
const char *const kSrModeB[] = {
    "Anime4K_Clamp_Highlights.glsl",
    "Anime4K_Restore_CNN_Soft_VL.glsl",
    "Anime4K_Upscale_CNN_x2_VL.glsl",
    "Anime4K_AutoDownscalePre_x2.glsl",
    "Anime4K_AutoDownscalePre_x4.glsl",
    "Anime4K_Upscale_CNN_x2_M.glsl",
};
const char *const kSrModeBPlus[] = {
    "Anime4K_Clamp_Highlights.glsl",
    "Anime4K_Restore_CNN_Soft_VL.glsl",
    "Anime4K_Upscale_CNN_x2_VL.glsl",
    "Anime4K_AutoDownscalePre_x2.glsl",
    "Anime4K_AutoDownscalePre_x4.glsl",
    "Anime4K_Restore_CNN_Soft_M.glsl",
    "Anime4K_Upscale_CNN_x2_M.glsl",
};
const char *const kSrModeC[] = {
    "Anime4K_Clamp_Highlights.glsl",
    "Anime4K_Upscale_Denoise_CNN_x2_VL.glsl",
    "Anime4K_AutoDownscalePre_x2.glsl",
    "Anime4K_AutoDownscalePre_x4.glsl",
    "Anime4K_Upscale_CNN_x2_M.glsl",
};
const char *const kSrModeCA[] = {
    "Anime4K_Clamp_Highlights.glsl",
    "Anime4K_Upscale_Denoise_CNN_x2_VL.glsl",
    "Anime4K_AutoDownscalePre_x2.glsl",
    "Anime4K_AutoDownscalePre_x4.glsl",
    "Anime4K_Restore_CNN_M.glsl",
    "Anime4K_Upscale_CNN_x2_M.glsl",
};
// 无尺寸门槛:参数/滤波类 pass,窗口模式下也有效果。
const char *const kSrDenoise[] = { "Anime4K_Denoise_Bilateral_Mode.glsl" };
const char *const kSrDeblur[] = { "Anime4K_Deblur_DoG.glsl" };

#define MOE_SR_ROW(id, label, key, arr)     { id, label, key, arr, int(sizeof(arr) / sizeof(arr[0])) }

const QVector<MpvClient::SuperResPreset> &superResTable()
{
    static const QVector<MpvClient::SuperResPreset> t = {
        { "off", "关闭", "CTRL+0", nullptr, 0 },
        MOE_SR_ROW("mode_a", "模式 A(1080p 常用)", "CTRL+1", kSrModeA),
        MOE_SR_ROW("mode_b", "模式 B(720p 常用)", "CTRL+2", kSrModeB),
        MOE_SR_ROW("mode_c", "模式 C(降采样源)", "CTRL+3", kSrModeC),
        MOE_SR_ROW("mode_a_plus", "模式 A+(放大 ≥2 倍)", "CTRL+4", kSrModeAPlus),
        MOE_SR_ROW("mode_b_plus", "模式 B+(放大 ≥2 倍)", "CTRL+5", kSrModeBPlus),
        MOE_SR_ROW("mode_c_a", "模式 C+A(放大 ≥2 倍)", "CTRL+6", kSrModeCA),
        MOE_SR_ROW("denoise", "去噪(窗口可用)", "CTRL+7", kSrDenoise),
        MOE_SR_ROW("deblur", "去模糊(窗口可用)", "CTRL+8", kSrDeblur),
    };
    return t;
}

#undef MOE_SR_ROW

// shader 源里是否带「输出须大于源 1.2 倍」的尺寸门槛(官方 CNN 放大 pass 的
// //!WHEN OUTPUT.w MAIN.w / 1.200 > …)。从文件现算,不手工维护名单。
bool shaderHasSizeGate(const QString &path)
{
    static QHash<QString, bool> cache;
    const auto it = cache.constFind(path);
    if (it != cache.constEnd())
        return it.value();
    bool gated = false;
    QFile f(path);
    if (f.open(QIODevice::ReadOnly))
        gated = f.readAll().contains("OUTPUT.w MAIN.w / 1.200 >");
    cache.insert(path, gated);
    return gated;
}

} // namespace

const QVector<MpvClient::SuperResPreset> &MpvClient::superResPresets()
{
    return superResTable();
}

const MpvClient::SuperResPreset *MpvClient::superResPreset(const QString &id)
{
    for (const SuperResPreset &p : superResTable()) {
        if (id == QLatin1String(p.id))
            return &p;
    }
    return nullptr;
}

QVariantList MpvClient::superResOptions()
{
    QVariantList out;
    for (const SuperResPreset &p : superResTable()) {
        out.append(QVariantMap{ { QStringLiteral("label"), QString::fromUtf8(p.label) },
                                { QStringLiteral("key"), QString::fromLatin1(p.id) },
                                { QStringLiteral("hotkey"), QString::fromUtf8(p.key) } });
    }
    return out;
}

QString MpvClient::superResLabel(const QString &id)
{
    const SuperResPreset *p = superResPreset(id);
    return p ? QString::fromUtf8(p->label) : QString();
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

QString MpvClient::sessionKeyFor(const QVariantMap &meta)
{
    const QString item = meta.value(QStringLiteral("itemId")).toString();
    const QString acc = meta.value(QStringLiteral("accountId")).toString();
    return acc.isEmpty() ? item : acc + QLatin1Char('|') + item;
}

bool MpvClient::startPending(const QVariantMap &meta)
{
    QString key = sessionKeyFor(meta);
    if (key.isEmpty())
        key = QStringLiteral("session-%1").arg(++m_nextKeyId);
    if (m_sessions.contains(key))
        return false; // 同条目并行播放防重(与旧 pendingPlaybackWindows 语义一致)。
    Session *s = createSession(key);
    s->meta = meta;
    if (embeddedPreferred()) {
        qInfo() << "MpvClient: 内嵌播放请求" << key;
        emit embeddedPlaybackRequested(meta);
        return true;
    }
    spawnMpv(s);
    return true;
}

void MpvClient::deliver(const QString &url, const QVariantList &headers,
                        const QVariantMap &meta)
{
    const QString key = sessionKeyFor(meta);
    Session *s = sessionFor(key);
    if (!s) {
        // 会话不存在 = 用户在协商期已关窗取消(startPending 建、stop 销毁)。
        // 建幽灵会话只会:永不播放(内嵌无窗无核心)、Ping 每 10 分钟永续、
        // 且同 key 重播被 contains 拦截永久阻断——必须丢弃。
        qWarning().noquote() << "MpvClient: deliver 到达时会话已不存在(用户已取消),丢弃" << key;
        return;
    }
    s->meta = meta;
    s->delivered = true;
    reportStart(s);
    qInfo() << "MpvClient: deliver" << key << (s->listSet ? QStringLiteral("列表") : QStringLiteral("单条"));
    s->url = url;
    s->headers = headers;
    if (s->listSet) {
        // 全集播放列表模式:setEpisodeList 的 loadlist replace 已播第 0 条
        // (当前集真 URL);无需再 loadfile。
        return;
    }
    enqueueLoad(s, url, headers);
}

void MpvClient::fail(const QString &itemId, const QString &message)
{
    qWarning() << "MpvClient: 协商失败,关闭会话" << itemId << message;
    Session *s = sessionFor(itemId);
    if (!s) {
        // 宽松:调用方(协商失败信号)只有裸 itemId,按后缀 "|itemId" 补配。
        for (auto it = m_sessions.constBegin(); it != m_sessions.constEnd(); ++it) {
            if (it.key().endsWith(QLatin1Char('|') + itemId)) {
                s = it.value();
                break;
            }
        }
    }
    if (!s)
        return;
    // 协商失败:尚未起播,不回传服务器、不刷新历史;但要发本地
    // playbackFinished 让内嵌 PlayerWindow 收窗(否则黑窗+转圈永驻;
    // Main 的 onErrorOccurred 失败结算路径同样依赖此信号关窗)。
    const QString key = m_sessions.key(s);
    const QString metaItemId = s->meta.value(QStringLiteral("itemId")).toString();
    destroySession(s);
    if (!key.isEmpty())
        emit playbackFinished(key, metaItemId, false, 0.0, 0.0);
}

void MpvClient::start(const QString &url, const QVariantList &headers,
                      const QVariantMap &meta)
{
    QString key = sessionKeyFor(meta);
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
    if (embeddedPreferred()) {
        s->url = url;
        s->headers = headers;
        emit embeddedPlaybackRequested(meta);
        return;
    }
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
            // 播放列表操作(playlist-pos 变了但不加载)——先清空列表
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
    // IPC 通道名:Linux/Unix = 临时目录下的 socket 文件;Windows = 命名管道
    // 裸名 —— mpv 与 QLocalSocket 都会对缺失的 \\.\pipe\ 前缀自动补齐
    // (mpv input/ipc-win.c、Qt qlocalserver_win.cpp 的 pipePath),两端传
    // 同一个裸名即可对上,不能把盘符路径塞进管道命名空间。
    // (fd 继承的 --input-ipc-client 在 mpv 侧不生效,故走 socket/管道。)
#ifdef Q_OS_WIN
    const QString sockPath = QStringLiteral("moe-mpv-") +
                             QUuid::createUuid().toString(QUuid::WithoutBraces);
#else
    const QString sockPath = QDir::tempPath() + QStringLiteral("/moe-mpv-") +
                             QUuid::createUuid().toString(QUuid::WithoutBraces) +
                             QStringLiteral(".sock");
#endif
    s->sockPath = sockPath;

    const QString mpvBin = findMpvBinary();

    QStringList args;
    args << QStringLiteral("--input-ipc-server=") + sockPath
         << QStringLiteral("--force-window=yes")
         << QStringLiteral("--idle=yes")
         << QStringLiteral("--script=") + findMoeHookScript()
         // 播放列表面板显示条目标题(m3u EXTINF 解析的 title;官方
         // --osd-playlist-entry,见 options.rst)。
         << QStringLiteral("--osd-playlist-entry=title")
         // 底栏自定义"选集"按钮:打开官方播放列表面板(全集标题,经 on_load
         // hook 重定向到真实地址,不再依赖 MoePlayer 自造菜单)。
         << QStringLiteral("--script-opts=osc-custom_button_1_content=\\\u2388|选集|")
         << QStringLiteral("--script-opts=osc-custom_button_1_mbtn_left_command=script-binding select/select-playlist; script-message-to osc osc-hide")
         // 不设 keep-open:mpv 在最后一条目 EOF 时会把 AT_END_OF_FILE 改写
         // 为 KEEP_PLAYING(暂停不发 end-file)——关窗/Stopped 回传
         // 全靠 end-file(eof) 判定;idle=yes+force-window 已保进程与窗口。
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
         << QStringLiteral("--stop-screensaver=yes")
         << QStringLiteral("--screenshot-dir=") +
                QStandardPaths::writableLocation(QStandardPaths::PicturesLocation) +
                QStringLiteral("/MoePlayer");
    const double resumeSec =
        s->meta.value(QStringLiteral("resumePositionTicks")).toDouble() / kTicksPerSecond;
    if (resumeSec > 0.0)
        args << QStringLiteral("--start=") + QString::number(resumeSec);
    const int subOrd = s->meta.contains(QStringLiteral("selectedSubtitleOrdinal"))
                           ? s->meta.value(QStringLiteral("selectedSubtitleOrdinal")).toInt() : -1;
    const QString subUrl = s->meta.value(QStringLiteral("selectedSubtitleUrl")).toString();
    if (subOrd == -2)
        args << QStringLiteral("--sid=no");
    else if (subOrd >= 0 && !subUrl.isEmpty())
        args << QStringLiteral("--sub-file=") + subUrl;
    if (s->meta.value(QStringLiteral("selectedAudioOrdinal")).toInt() == -2)
        args << QStringLiteral("--aid=no");
    {
        const QString preset = m_config ? m_config->superRes() : QStringLiteral("off");
        const SuperResPreset *pp = superResPreset(preset);
        if (pp && pp->fileCount > 0) {
            QStringList chain;
            for (int i = 0; i < pp->fileCount; ++i) {
                const QString path = findShader(QString::fromLatin1(pp->files[i]));
                if (QFileInfo::exists(path))
                    chain << path;
            }
            if (!chain.isEmpty()) {
#ifdef Q_OS_WIN
                args << QStringLiteral("--glsl-shaders=") + chain.join(QLatin1Char(';'));
#else
                args << QStringLiteral("--glsl-shaders=") + chain.join(QLatin1Char(':'));
#endif
            }
        }
    }
    // 播放流 HTTP 代理(仅 http(s);空=直连)。https 目标走 CONNECT 隧道。
    const QString proxy = m_config ? m_config->proxy() : QString();
    if (proxy.startsWith(QStringLiteral("http://")) ||
        proxy.startsWith(QStringLiteral("https://")))
        args << QStringLiteral("--http-proxy=") + proxy;

    s->proc = new QProcess(this);
#ifdef Q_OS_WIN
    // 官方 Windows mpv.exe 是 console 子系统进程:GUI 父进程启动它时,即使
    // stdout/stderr 已重定向到管道,Windows 仍会为它分配一个控制台窗口
    // (黑窗一闪)。CREATE_NO_WINDOW 抑制之;stdio 管道不受影响,--terminal
    // 的 [mpv] 日志转发照常(无控制台时 mpv 回退写管道)。
    s->proc->setCreateProcessArgumentsModifier(
        [](QProcess::CreateProcessArguments *args) { args->flags |= CREATE_NO_WINDOW; });
#endif
    s->proc->setProgram(mpvBin);
    s->proc->setArguments(args);
    connect(s->proc, &QProcess::finished, this, [key = s->key, this](int code, QProcess::ExitStatus) {
        qInfo() << "MpvClient: mpv 进程退出,退出码" << code;
        stopAndConsiderEnd(key, code != 0);
    });
    // mpv 日志转发:逐行接进 MoePlayer 输出。mpv 日志走 stdout 而非
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
    connect(s->proc, &QProcess::errorOccurred, this,
            [key = s->key, mpvBin, this](QProcess::ProcessError err) {
        if (err != QProcess::FailedToStart) {
            // Crashed 等:结束语义由 finished 处理器承担,这里只记录。
            qWarning() << "MpvClient: mpv 进程错误" << int(err) << "key" << key;
            return;
        }
        // 启动即失败 = 找不到可执行(或不可执行)。给出可操作指引并结束会话
        // (否则 IPC 连接会以 150ms 无限重试;播放从未开始,静默关窗与
        // fail() 的协商失败同语义,不回传不刷新)。
        qWarning().noquote()
            << "MpvClient: 无法启动 mpv(尝试:" << mpvBin << ")。"
            << "请安装 mpv 并加入 PATH,或将其放到 MoePlayer 可执行文件同目录"
#ifdef Q_OS_WIN
            << "(mpv.exe)"
#endif
            << ",或设环境变量 MOEPLAYER_MPV 指向其完整路径";
        Session *cur = sessionFor(key);
        if (cur)
            destroySession(cur);
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
    if (s && s->embedded) {
        s->embedded->sendJson(obj);
        return;
    }
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
    handleJson(s, doc.object());
}

void MpvClient::handleJson(Session *s, const QJsonObject &obj)
{
    if (obj.contains(QStringLiteral("request_id"))) {
        const int rid = obj.value(QStringLiteral("request_id")).toInt();
        if (rid == kReadyRequestId) {
            s->ready = true;
            qInfo() << "MpvClient: IPC 就绪" << s->key;
            flush(s);
        } else if (rid == kTrackListRequestId) {
            applyTrackSelection(s, obj.value(QStringLiteral("data")).toArray());
        } else if (rid == kChaptersRequestId) {
            QVariantList chapters;
            const QJsonArray list = obj.value(QStringLiteral("data")).toArray();
            for (const QJsonValue &v : list) {
                const QJsonObject c = v.toObject();
                chapters.append(QVariantMap{
                    {QStringLiteral("time"), c.value(QStringLiteral("time")).toDouble()},
                    {QStringLiteral("title"), c.value(QStringLiteral("title")).toString()},
                });
            }
            emit chaptersChanged(s->key, chapters);
        } else if (rid == kTracksRequestId) {
            const QVariantList audioStreams =
                s->meta.value(QStringLiteral("audioStreams")).toList();
            const QVariantList subStreams =
                s->meta.value(QStringLiteral("subtitleStreams")).toList();
            QVariantList tracks;
            int ordA = 0, ordS = 0;
            const QJsonArray list = obj.value(QStringLiteral("data")).toArray();
            for (const QJsonValue &v : list) {
                const QJsonObject t = v.toObject();
                const QString type = t.value(QStringLiteral("type")).toString();
                if (type != QLatin1String("audio") && type != QLatin1String("sub"))
                    continue;
                QString label;
                const QVariantList &streams =
                    type == QLatin1String("audio") ? audioStreams : subStreams;
                const int ord = type == QLatin1String("audio") ? ordA++ : ordS++;
                if (ord >= 0 && ord < streams.size())
                    label = streams.at(ord).toMap()
                                .value(QStringLiteral("displayTitle")).toString();
                if (label.isEmpty())
                    label = t.value(QStringLiteral("title")).toString();
                if (label.contains(QStringLiteral("://")))
                    label.clear(); // URL 形态的 title 不用
                if (label.isEmpty())
                    label = t.value(QStringLiteral("lang")).toString();
                if (label.isEmpty())
                    label = t.value(QStringLiteral("codec")).toString();
                tracks.append(QVariantMap{
                    {QStringLiteral("id"), t.value(QStringLiteral("id")).toInt()},
                    {QStringLiteral("type"), type},
                    {QStringLiteral("label"), label},
                    {QStringLiteral("selected"), t.value(QStringLiteral("selected")).toBool()},
                });
            }
            emit tracksChanged(s->key, tracks);
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
            // eof 应答:ended 条目在播放列表中的索引 ≥ 末位 = 播完(结束
            // 会话);否则 mpv 自动连播下一项(占位 → on_load hook 重定向)。
            const QJsonArray list = obj.value(QStringLiteral("data")).toArray();
            int index = -1;
            for (int i = 0; i < list.size(); ++i) {
                if (list.at(i).toObject().value(QStringLiteral("id")).toInt(-1)
                    == s->eofEntryId) {
                    index = i;
                    break;
                }
            }
            // 查不到(列表已被外部清空等)= 按播完处理。
            if (index < 0 || index >= list.size() - 1) {
                stopAndConsiderEnd(s->key, false);
            } else if (index < s->playlistIds.size()) {
                // 中间集真播完(eof 且非末条,mpv 继续连播):本地乐观标记已看。
                emit episodeFinished(s->key, s->playlistIds.at(index));
            }
        } else if (rid == kSuperResListRequestId) {
            // glsl-shaders 回读:实际挂载数 + 是否含尺寸门槛 pass。
            const QJsonArray list = obj.value(QStringLiteral("data")).toArray();
            bool gated = false;
            for (const QJsonValue &v : list)
                if (shaderHasSizeGate(v.toString()))
                    gated = true;
            s->superResState.insert(QStringLiteral("mounted"), list.size());
            s->superResState.insert(QStringLiteral("sizeGated"), gated);
        } else if (rid == kSuperResVideoRequestId) {
            const QJsonObject v = obj.value(QStringLiteral("data")).toObject();
            s->superResState.insert(QStringLiteral("videoW"), v.value(QStringLiteral("w")).toInt());
            s->superResState.insert(QStringLiteral("videoH"), v.value(QStringLiteral("h")).toInt());
        } else if (rid == kSuperResOutputRequestId) {
            const QJsonObject v = obj.value(QStringLiteral("data")).toObject();
            const int outW = s->outW > 0 ? s->outW : v.value(QStringLiteral("w")).toInt();
            const int outH = s->outH > 0 ? s->outH : v.value(QStringLiteral("h")).toInt();
            const int vidW = s->superResState.value(QStringLiteral("videoW")).toInt();
            const int vidH = s->superResState.value(QStringLiteral("videoH")).toInt();
            const int mounted = s->superResState.value(QStringLiteral("mounted")).toInt();
            const bool gated = s->superResState.value(QStringLiteral("sizeGated")).toBool();
            s->superResState.insert(QStringLiteral("outputW"), outW);
            s->superResState.insert(QStringLiteral("outputH"), outH);
            // 门槛判定:仅当播着且挂了 shader 才下结论(尺寸未知不下结论,
            // 既不谎报"已生效"也不误报失败)。判定口径与 shader 源里
            // //!WHEN OUTPUT.w MAIN.w / 1.200 > 一致,宽高都要过。
            const bool judged = mounted > 0 && vidW > 0 && vidH > 0 && outW > 0 && outH > 0;
            if (judged) {
                const bool willRun = !gated || (outW > vidW * 1.2 && outH > vidH * 1.2);
                s->superResState.insert(QStringLiteral("willRun"), willRun);
                if (!willRun && !s->superResState.value(QStringLiteral("warned")).toBool()) {
                    s->superResState.insert(QStringLiteral("warned"), true);
                    const QString msg =
                        QStringLiteral("Anime4K: 放大链未生效(窗口 %1×%2 未超过片源 %3×%4 的 1.2 倍)")
                            .arg(outW).arg(outH).arg(vidW).arg(vidH);
                    sendJson(s, QJsonObject{
                                    {QStringLiteral("command"),
                                     QJsonArray{QStringLiteral("show-text"), msg, 3000}},
                                });
                    qInfo() << "MpvClient:" << msg << s->key;
                }
            }
            qInfo() << "MpvClient: 超分回读" << s->superResPreset
                    << "挂载" << mounted << "/"
                    << s->superResState.value(QStringLiteral("expected")).toInt()
                    << "片源" << vidW << "x" << vidH << "输出" << outW << "x" << outH
                    << "尺寸门槛" << gated << s->key;
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
        } else if (name == QLatin1String("glsl-shaders")) {
            // 链被改动(mpv 内快捷键/外部):重算挂载数与门槛判定。
            requestSuperResState(s);
        }
        return;
    }
    if (evName == QLatin1String("file-loaded")) {
        // on_load hook 路径(playlist 占位):QML 协商 meta 按 pendingFileId 归位;
        // 首集(用户点播)保持会话初值(pendingFileId 为空)。
        if (!s->pendingFileId.isEmpty()) {
            const QVariantMap pm = s->episodeMeta.value(s->pendingFileId);
            if (!pm.isEmpty()) {
                const QString oldSid = s->meta.value(QStringLiteral("playSessionId")).toString();
                if (s->loadIssued
                    && s->meta.value(QStringLiteral("itemId")).toString()
                        != pm.value(QStringLiteral("itemId")).toString())
                    reportStopped(s);
                s->meta = pm;
                if (!pm.value(QStringLiteral("playSessionId")).toString().isEmpty()
                    && pm.value(QStringLiteral("playSessionId")).toString() != oldSid)
                    reportStart(s);
            }
            s->pendingFileId.clear();
        }
        s->loadIssued = true;
        qInfo() << "MpvClient: file-loaded" << s->meta.value(QStringLiteral("itemId")).toString();
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
        // 文件就绪即查 track-list,匹配 Emby 所选轨(两模式共享;外部经
        // IPC 同样可行——修正外部模式正数 ordinal 选轨静默丢弃的缺口)。
        sendJson(s, QJsonObject{
                        {QStringLiteral("command"),
                         QJsonArray{QStringLiteral("get_property"),
                                    QStringLiteral("track-list")}},
                        {QStringLiteral("request_id"), kTrackListRequestId},
                    });
        if (!s->embedded) {
            emit playbackStarted(s->key, s->meta.value(QStringLiteral("itemId")).toString());
            emit playbackContextChanged(s->meta);
            return;
        }
        if (s->pendingFileId.isEmpty()) {
            const int subOrd = s->meta.contains(QStringLiteral("selectedSubtitleOrdinal"))
                                   ? s->meta.value(QStringLiteral("selectedSubtitleOrdinal")).toInt()
                                   : -1;
            const QString subUrl = s->meta.value(QStringLiteral("selectedSubtitleUrl")).toString();
            if (subOrd >= 0 && !subUrl.isEmpty())
                sendJson(s, QJsonObject{{QStringLiteral("command"),
                                         QJsonArray{QStringLiteral("sub-add"), subUrl}}});
        }
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
        // 超分:片源尺寸此时才可知,重算门槛判定(窗口够大才真跑放大链)。
        if (s->superResPreset != QLatin1String("off"))
            requestSuperResState(s);
        refreshChapters(s->key);
        emit playbackStarted(s->key, s->meta.value(QStringLiteral("itemId")).toString());
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
            const bool early = s->duration > 12.0 && s->position > 0.5
                               && s->position < s->duration - 12.0;
            if (early && qAbs(s->position - s->lastEarlyEofPos) > 2.0) {
                s->lastEarlyEofPos = s->position;
                qWarning() << "MpvClient: 提前 EOF(断流),按失败重连" << s->position
                           << "/" << s->duration << s->key;
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
            // 是否最后一项:按 playlist_entry_id 在播放列表里定位(无竞态;
            // 旧实现查 playlist-pos,应答到达时 mpv 可能已推进到下一项,
            // 倒数第二集会被误判为最后而提前关窗)。
            s->eofEntryId = ev.value(QStringLiteral("playlist_entry_id")).toInt(-1);
            sendJson(s, QJsonObject{
                            {QStringLiteral("command"),
                             QJsonArray{QStringLiteral("get_property"),
                                        QStringLiteral("playlist")}},
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
            emit episodeUrlRequested(s->key, s->pendingFileId);
        } else if (args.size() >= 1 && args.at(0).toString() == QLatin1String("moe-keys-request")) {
            // 脚本就绪晚于本类连接时的补发请求(moe-hook.lua 加载即发一次)。
            sendSuperResKeys(s);
        } else if (args.size() >= 2 && args.at(0).toString() == QLatin1String("moe-shader")) {
            // mpv 内快捷键(CTRL+0..8,script-message 广播):写配置,
            // 随后由 superResChanged 统一应用到所有会话(单一真相源)。
            const QString id = args.at(1).toString();
            if (superResPreset(id) && m_config) {
                qInfo() << "MpvClient: 快捷键切换超分档位" << id << s->key;
                m_config->setsuperRes(id);
            } else {
                qWarning() << "MpvClient: 未知超分档位" << id;
            }
        }
        return;
    }
}

void MpvClient::observe(Session *s)
{
    // id 1/2/3:time-pos/duration/pause(两模式共用:回传与进度)。
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("observe_property"), 1,
                                        QStringLiteral("time-pos")}}});
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("observe_property"), 2,
                                        QStringLiteral("duration")}}});
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("observe_property"), 3,
                                        QStringLiteral("pause")}}});
    // id 4-8 只服务内嵌(超分回读/UI 镜像);外部模式 OSC 自管,不发
    // (每个 observe = 每条变化一条 IPC 流量,外部纯浪费)。
    if (!s->embedded)
        return;
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("observe_property"), 4,
                                        QStringLiteral("glsl-shaders")}}});
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("observe_property"), 5,
                                        QStringLiteral("volume")}}});
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("observe_property"), 6,
                                        QStringLiteral("speed")}}});
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("observe_property"), 7,
                                        QStringLiteral("demuxer-cache-state")}}});
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("observe_property"), 8,
                                        QStringLiteral("paused-for-cache")}}});
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
        // 超分:注册快捷键 + 按配置挂载默认档位(仅一次,之后再变走配置信号)。
        initSuperRes(s);
    }
    // 未就绪期暂存的播放列表调用,就绪后原样补灌(已置 ready,本次直通)。
    if (!s->pendingEpisodes.isEmpty()) {
        const QVariantList eps = s->pendingEpisodes;
        const int idx = s->pendingIndex;
        const QString u = s->pendingUrl;
        const QVariantList h = s->pendingHeaders;
        const QVariantMap m = s->pendingMeta;
        s->pendingEpisodes.clear();
        s->pendingIndex = -1;
        s->pendingUrl.clear();
        s->pendingHeaders.clear();
        s->pendingMeta.clear();
        setEpisodeList(eps, s->key, idx, u, h, m);
    }
    if (!s->url.isEmpty() && !s->loadIssued && !s->listSet) {
        if (!s->headers.isEmpty()) {
            QStringList fields;
            for (const QVariant &h : s->headers)
                fields << h.toString();
            sendJson(s, QJsonObject{
                            {QStringLiteral("command"),
                             QJsonArray{QStringLiteral("set_property"),
                                        QStringLiteral("http-header-fields"),
                                        QJsonArray::fromStringList(fields)}},
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
    // 按传入会话键定位(m_active 只是最新会话:多窗并发下重播旧窗剧集
    // 会把播放列表灌进别的窗口)。
    Session *s = sessionFor(currentItemId);
    if (!s)
        s = m_active;
    if (!s || episodes.isEmpty()) {
        qDebug() << "MpvClient: setEpisodeList 跳过(无会话/空列表)";
        return;
    }
    if (!s->ready) {
        // 外部模式 IPC 未就绪:暂存,就绪 flush 里补灌(原路跳过会让
        // Main 置 _listPrimed 而列表永远丢失)。
        s->pendingEpisodes = episodes;
        s->pendingIndex = currentIndex;
        s->pendingUrl = url;
        s->pendingHeaders = headers;
        s->pendingMeta = meta;
        qDebug() << "MpvClient: 会话未就绪,播放列表暂存待补灌" << s->key;
        return;
    }
    if (!meta.isEmpty())
        s->episodeMeta.insert(currentItemId, meta);
    // 写 m3u:条目标题(m3u EXTINF,mpv demux_playlist.c 解析为 playlist
    // entry title,经 --osd-playlist-entry=title 显示)+ 占位地址
    // 可重复调用(重播同集/续链):清旧播放表 + 删旧 m3u(否则 ids 翻倍、
    // 旧文件泄漏)。
    s->playlistIds.clear();
    if (!s->m3uPath.isEmpty()) {
        QFile::remove(s->m3uPath);
        s->m3uPath.clear();
    }
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
        title.replace(QLatin1Char('\n'), QLatin1Char(' ')).replace(QLatin1Char('\r'), QLatin1Char(' '));
        if (title.isEmpty())
            title = id;
        body2 += "#EXTINF:0," + title.toUtf8() + "\n";
        body2 += (k == 0 ? url.toUtf8() : ("moe://ep/" + id.toUtf8())) + "\n";
        s->playlistIds << id;
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
                                    QJsonArray::fromStringList(fields)}},
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

void MpvClient::deliverEpisodeUrl(const QString &sessionKey, const QString &itemId,
                                  const QString &url,
                                  const QVariantList &headers,
                                  const QVariantMap &meta,
                                  const QString &subtitleUrl)
{
    Session *s = sessionFor(sessionKey);
    if (!s || !s->ready) {
        qDebug() << "MpvClient: deliverEpisodeUrl 跳过(无活跃会话/未就绪)" << itemId;
        return;
    }
    if (!meta.isEmpty())
        s->episodeMeta.insert(itemId, meta);
    // 换集真实地址同步进会话(进度条预览实例吃 s->url/s->headers,
    // 不同步会一直拉首集或已过期地址)。
    if (!url.isEmpty()) {
        s->url = url;
        s->headers = headers;
    }
    // 流头(可能跨服务器变化):切换全局头,后续加载生效。
    if (!headers.isEmpty()) {
        QStringList fields;
        for (const QVariant &h : headers)
            fields << h.toString();
        sendJson(s, QJsonObject{
                        {QStringLiteral("command"),
                         QJsonArray{QStringLiteral("set_property"),
                                    QStringLiteral("http-header-fields"),
                                    QJsonArray::fromStringList(fields)}},
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
        // 按会话键现取 meta:换集后 Ping 跟随当前集(不再钉死首集)。
        const QString key = s->key;
        connect(s->pingTimer, &QTimer::timeout, this, [this, key]() {
            Session *cur = sessionFor(key);
            if (!cur)
                return;
            const QString sid0 = cur->meta.value(QStringLiteral("playSessionId")).toString();
            if (sid0.isEmpty())
                return;
            m_emby->reportPlaybackPing(cur->meta.value(QStringLiteral("serverUrl")).toString(),
                                       cur->meta.value(QStringLiteral("token")).toString(),
                                       cur->meta.value(QStringLiteral("userId")).toString(), sid0);
        });
        s->pingTimer->start();
    }
}

// 文件加载后按所选轨选 mpv 数字 id;两模式共享(外部经 IPC 同样可行,
// 修复外部模式正数 ordinal 选轨被静默丢弃的缺口)。
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
    const QString bareId = s->meta.value(QStringLiteral("itemId")).toString();
    const double pos = s->position, dur = s->duration;
    destroySession(s);
    if (played)
        emit playbackFinished(key, bareId, errored, pos, dur);
}

void MpvClient::destroySession(Session *s)
{
    if (!s)
        return;
    if (s->embedded) {
        // 内嵌:停播并断开(核心是 QML Item 子对象,不随会话销毁)。
        s->embedded->disconnect(this);
        s->embedded->sendJson(QJsonObject{
            {QStringLiteral("command"),
             QJsonArray{QStringLiteral("stop")}}});
        s->embedded = nullptr;
    }
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
#ifndef Q_OS_WIN // Windows 是命名管道,无文件可删(mpv 退出即消)
    if (!s->sockPath.isEmpty())
        QFile::remove(s->sockPath);
#endif
    if (!s->m3uPath.isEmpty())
        QFile::remove(s->m3uPath);
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

void MpvClient::initSuperRes(Session *s)
{
    if (s->superResReady)
        return;
    s->superResReady = true;
    // mpv 窗口内快捷键:把「键 档位 …」清单交 moe-hook.lua 用
    // mp.add_key_binding 注册。**必须是 lua 的弱绑定**:IPC 的 keybind 命令
    // 会顶掉用户自己 input.conf 的同名键,lua.rst 的 add_key_binding
    // 只覆盖默认绑定。按键 → script-message moe-shader <id>(mpv 广播给所有
    // 客户端,含 IPC)→ 本类 client-message 分支写配置,再统一应用到所有会话。
    sendSuperResKeys(s);
    applySuperRes(s, m_config ? m_config->superRes() : QStringLiteral("off"), false);
}

void MpvClient::sendSuperResKeys(Session *s)
{
    QStringList kv;
    for (const SuperResPreset &p : superResPresets())
        kv << QString::fromLatin1(p.key) << QString::fromLatin1(p.id);
    sendJson(s, QJsonObject{
                    {QStringLiteral("command"),
                     QJsonArray{QStringLiteral("script-message-to"), QStringLiteral("moe_hook"),
                                QStringLiteral("moe-keys"), kv.join(QLatin1Char(' '))}},
                });
}

void MpvClient::applySuperRes(Session *s, const QString &presetId, bool announce)
{
    const SuperResPreset *p = superResPreset(presetId);
    s->superResPreset = p ? QString::fromLatin1(p->id) : QStringLiteral("off");
    s->superResState.clear();
    // clr 的 value 必须给空串(mpv:不带值的操作也要求占位参数)。
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("change-list"),
                                        QStringLiteral("glsl-shaders"),
                                        QStringLiteral("clr"), QString()}}});
    int expected = 0;
    if (p) {
        for (int i = 0; i < p->fileCount; ++i) {
            const QString name = QString::fromLatin1(p->files[i]);
            const QString path = findShader(name);
            if (!QFileInfo::exists(path)) {
                qWarning() << "MpvClient: 缺少 shader 文件" << name << path;
                continue;
            }
            // 逐条 append:单条命令不经路径列表分隔符(POSIX ':' / Windows ';'),
            // 绝对路径里含分隔符也不会被切开。
            sendJson(s, QJsonObject{{QStringLiteral("command"),
                                     QJsonArray{QStringLiteral("change-list"),
                                                QStringLiteral("glsl-shaders"),
                                                QStringLiteral("append"), path}}});
            ++expected;
        }
    }
    s->superResState.insert(QStringLiteral("expected"), expected);
    s->superResState.insert(QStringLiteral("preset"), s->superResPreset);
    qInfo() << "MpvClient: 超分档位" << s->superResPreset << "下发" << expected
            << "个 shader" << s->key;
    if (announce && p) {
        sendJson(s, QJsonObject{
                        {QStringLiteral("command"),
                         QJsonArray{QStringLiteral("show-text"),
                                    QStringLiteral("Anime4K: ") +
                                        QString::fromUtf8(p->label)}},
                    });
    }
    requestSuperResState(s);
}

void MpvClient::requestSuperResState(Session *s)
{
    if (!s || !s->ready || !s->embedded)
        return;
    // 回读三件套:实际挂载列表、片源尺寸、输出(VO)尺寸。
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("get_property"),
                                        QStringLiteral("glsl-shaders")}},
                            {QStringLiteral("request_id"), kSuperResListRequestId}});
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("get_property"),
                                        QStringLiteral("video-params")}},
                            {QStringLiteral("request_id"), kSuperResVideoRequestId}});
    sendJson(s, QJsonObject{{QStringLiteral("command"),
                             QJsonArray{QStringLiteral("get_property"),
                                        QStringLiteral("osd-dimensions")}},
                            {QStringLiteral("request_id"), kSuperResOutputRequestId}});
}
