#pragma once

#include <QByteArray>
#include <QHash>
#include <QObject>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>

class QJsonObject;
class QProcess;
class QLocalSocket;
class QTimer;
class EmbyClient;
class ConfigManager;
class MpvEmbeddedCore;

//! mpv 播放客户端:外部进程 / 内嵌 libmpv 双模式(embeddedPreferred
//! 判定,缺库或配置 external 走外部)。
//!
//! 外部模式:spawn 系统 mpv 二进制(`--force-window` + 内建 OSC 自绘
//! OSD/控制栏;moe-hook.lua 经 `--script` 加载承担连播换集),Qt 不渲染
//! 视频,经 `--input-ipc-server`(临时 unix socket)用 mpv JSON IPC 控制/
//! 订阅;内嵌模式:libmpv 渲染进 MpvVideoItem,经 MpvEmbeddedCore 的
//! JSON 模拟层走同一套命令/事件逻辑,不 spawn 进程。
//!
//! Emby 播放状态回传(Start/Progress/Stopped/Ping)在此承接(原自绘播放窗口的逻辑):起播上报、每 progressReportMs(项目 10s)进度节流、
//! 每 10 分钟 Ping、结束/关窗上报停止。协商链路:startPending 预建会话并
//! 弹播放窗(外部:mpv 空窗;内嵌:embeddedPlaybackRequested → 播放页),
//! deliver 交付地址起播,fail 关窗;Library 直连走 start。
//!
//! QML 侧以单例 "MpvClient" 使用(main.cpp 注册)。
class MpvClient : public QObject
{
    Q_OBJECT
public:
    explicit MpvClient(EmbyClient *emby, ConfigManager *config,
                       QObject *parent = nullptr);
    ~MpvClient() override;

    // 查找 mpv 可执行:MOEPLAYER_MPV 环境变量 → <appdir>/mpv(发版内封) →
    // PATH 上的 "mpv"。找不到则返回空。
    static QString findMpvBinary();
    // 查找随包脚本:可执行文件旁置 lua/(开发 build/)→ 安装布局
    // ../share/moeplayer/lua/(DEB/RPM 与 AppImage/Flatpak 的 AppDir 同构)。
    static QString findScript(const QString &fileName);
    // moe-hook.lua(on_load 占位重定向);界面用 mpv 内建 OSC。
    static QString findMoeHookScript();

    // 查找随包 shader(Anime4K):可执行文件旁置 shaders/(开发 build/)→
    // 安装布局 ../share/moeplayer/shaders/(DEB/RPM 与 AppImage/Flatpak 的
    // AppDir 同构)。
    static QString findShader(const QString &fileName);

    // Anime4K 超分预设:shader 链与顺序取官方 v4.0.1 模板
    // (md/Template/GLSL_Mac_Linux_High-end/input.conf);key 与官方快捷键
    // 一致(CTRL+1/2/3 模式 A/B/C、CTRL+4/5/6 二次模式、CTRL+0 关闭),
    // 去噪/去模糊两档为本项目补充(无尺寸门槛,窗口模式也有效果)。
    struct SuperResPreset
    {
        const char *id;
        const char *label;
        const char *key;             // mpv 快捷键(随会话经 IPC 注册)
        const char *const *files;    // 文件名,经 findShader 解析为绝对路径
        int fileCount;
    };
    static const QVector<SuperResPreset> &superResPresets();
    static const SuperResPreset *superResPreset(const QString &id);
    // ConfigManager 的 Combo 选项钩子({label,key})与档位显示名。
    Q_INVOKABLE static QVariantList superResOptions();
    static QString superResLabel(const QString &id);

    // 先弹 mpv 空窗(协商期加载态);meta 含 itemId/serverUrl/...。成功返回 true。
    Q_INVOKABLE bool startPending(const QVariantMap &meta);
    // 协商完成:把播放地址(含流头)交付并起播(按 meta.itemId 找会话)。
    Q_INVOKABLE void deliver(const QString &url, const QVariantList &headers,
                             const QVariantMap &meta);
    // 协商失败:关闭对应 mpv 空窗(未起播,不回传、不刷新)。
    Q_INVOKABLE void fail(const QString &itemId, const QString &message);
    // Library 直连:spawn 并立即起播。
    Q_INVOKABLE void start(const QString &url, const QVariantList &headers,
                           const QVariantMap &meta);
    // 终止全部 mpv 子进程(应用退出时;析构与强制退出路径共用)。
    void shutdownAll();

    // 播放控制(作用于指定 itemId 会话;缺省作用于最近活跃会话)。
    Q_INVOKABLE void seek(double seconds, const QString &itemId = {});
    Q_INVOKABLE void setPause(bool p, const QString &itemId = {});
    Q_INVOKABLE void setVolume(int v, const QString &itemId = {});
    Q_INVOKABLE void command(const QVariantList &params, const QString &itemId = {});
    // 全集进入 mpv 播放列表:写 m3u(EXTINF 标题;官方 demux_playlist.c
    // 解析为条目 title,经 --osd-playlist-entry=title 显示),第 0 条 = 当前集
    // 真 URL(标题一致),其余按「当前→其后→环绕前部」旋转顺序为占位
    // moe://ep/<id>(经 on_load hook 重定向,见 moe-hook.lua)。loadlist
    // (replace)灌入即自动播第 0 条;点列表/上/下集/eof 连播都走 hook。
    Q_INVOKABLE void setEpisodeList(const QVariantList &episodes,
                                    const QString &currentItemId, int currentIndex,
                                    const QString &url, const QVariantList &headers,
                                    const QVariantMap &meta);
    // on_load hook 应答:占位条目经 moe-url 请求,QML 协商后的真实地址、
    // 流头、元数据与(可选)外挂字幕 URL;meta 供 file-loaded 归位/选轨。
    // url 为空 = 协商失败:通知 hook 继续(占位加载失败,mpv 跳过该条)。
    // sessionKey = 会话键(起始集 accountId|itemId,换集不换键):多窗并发
    // 时把应答路由回发起 hook 的会话(此前按 m_active,多会话会答错/挂起)。
    Q_INVOKABLE void deliverEpisodeUrl(const QString &sessionKey, const QString &itemId, const QString &url,
                                       const QVariantList &headers,
                                       const QVariantMap &meta,
                                       const QString &subtitleUrl = {});

    // ---- 内嵌播放(libmpv)----
    Q_INVOKABLE bool embeddedAvailable() const;
    // PlayerPage 的 MpvVideoItem 就绪后绑定会话:core 属 QML 侧(item 子
    // 对象),本类不接管所有权。itemId 定位 startPending 预建的会话。
    Q_INVOKABLE void attachEmbedded(QObject *coreObj, const QString &itemId);
    // 用户主动停止(返回键/关闭播放页):回传 Stopped 并销毁会话。
    Q_INVOKABLE void stop(const QString &itemId);

    // ---- 内嵌播放页面板数据 ----
    // 拉当前 track-list → tracksChanged(itemId, [{id,type,title,lang,codec,
    // selected}]);file-loaded 选轨后页面应重拉。
    Q_INVOKABLE void refreshTracks(const QString &itemId);
    // 选轨:type = "audio"/"sub",mpvId = track-list 的数字 id(-1 = 关)。
    Q_INVOKABLE void selectTrack(const QString &itemId, const QString &type, int mpvId);
    // 直跳选集:episodeId 须在本次 setEpisodeList 的播放列表内(旋转序
    // 已存,内部映射成 playlist-play-index)。
    Q_INVOKABLE void playEpisode(const QString &itemId, const QString &episodeId);
    // 进度条预览:当前片的播放地址与流头(供预览实例 loadfile;空 = 无)。
    Q_INVOKABLE QVariantMap previewInfo(const QString &itemId) const;
    // 内嵌渲染输出尺寸(libmpv 无 osd-dimensions 概念,超分门槛判定用
    // 渲染目标尺寸;PlayerWindow 尺寸变化时上报)。
    Q_INVOKABLE void setEmbeddedOutputSize(const QString &itemId, double w, double h);

signals:
    // 内嵌模式点播放:Main 据此 push PlayerPage(不 spawn 外部进程)。
    void embeddedPlaybackRequested(const QVariantMap &meta);
    // refreshTracks 应答:轨道列表(每集 file-loaded 后页面重拉刷新)。
    void tracksChanged(const QString &itemId, const QVariantList &tracks);
    // refreshChapters 应答:[{time,title}](mpv chapter-list,秒)。
    void chaptersChanged(const QString &itemId, const QVariantList &chapters);
    // 文件加载完成(可续播/seek)。
    void playbackStarted(const QString &sessionKey, const QString &itemId);
    // 当前播放集上下文(连播换集后广播;meta.itemId 为实际播放中的集,
    // 可能不同于会话键。连播由 moe-hook on_load 占位请求驱动:mpv 侧
    // script-message → episodeUrlRequested → deliverEpisodeUrl)。
    void playbackContextChanged(const QVariantMap &meta);
    // 播放列表占位条目请求(moe-hook on_load):QML 协商该集真实地址后
    // deliverEpisodeUrl 回发。
    void episodeUrlRequested(const QString &sessionKey, const QString &itemId);
    // 播放结束(正常播完/出错/用户关窗)。error=true 表示异常退出。
    // 双轴:sessionKey 路由会话,itemId 为真实集 id(换集后随实际播放变)。
    void playbackFinished(const QString &sessionKey, const QString &itemId, bool error);

private:
    struct Session
    {
        QString key = {};          // itemId(缺失时生成的唯一键)
        QProcess *proc = nullptr;
        // on_load hook 请求中的文件 id(script-message moe-url 记录;
        // file-loaded 时以此把 QML 协商 meta 归位到本文件)。
        QString pendingFileId;
        // QML 协商结果缓存(id -> meta):file-loaded 按 pendingFileId 归位。
        QHash<QString, QVariantMap> episodeMeta;
        // eof 结束判定:播完条目的 playlist_entry_id(按 id 在播放列表
        // 定位,无 playlist-pos 的推进竞态)。
        int eofEntryId = -1;
        // 全集列表已灌入(第 0 条 = 当前集真 URL,经播放列表播放)。
        bool listSet = false;
        // --input-ipc-server 文件 socket(fd 继承的 --input-ipc-client 在 mpv
        // 侧不生效,改用文件 socket + QLocalSocket,稳定且跨平台)。
        QLocalSocket *sock = nullptr;
        // 内嵌会话:libmpv 核心(PlayerPage 的 MpvVideoItem 子对象,本类
        // 不拥有);非空时 sendJson 走它的 JSON 模拟层,不 spawn 进程。
        MpvEmbeddedCore *embedded = nullptr;
        QString sockPath;          // 临时 socket 文件(销毁时清理)
        QTimer *connectRetry = nullptr;
        QByteArray buf;
        QVariantMap meta;          // 协商 meta(serverUrl/token/userId/itemId/...)
        QVariantList headers;      // 流请求 "Name: Value" 头
        QString url;
        bool ready = false;        // IPC 已就绪(收到 ping 应答)
        bool observeSent = false;   // 已下发 observe(仅一次,url 可能先空)
        bool loadIssued = false;   // 已下发 loadfile(幂等,防重复起播)
        bool delivered = false;    // 已交付(开始回传)
        bool ended = false;
        double position = 0.0;
        double duration = 0.0;
        bool paused = false;
        double lastReport = 0.0;
        QTimer *pingTimer = nullptr;
        // 加载失败重试(网络中断兜底):失败条目的播放列表 index、失败时
        // 位置、已重试次数(超过快速重试次数后转慢速,等待网络恢复)。
        int retryIndex = -1;
        double retryPos = 0.0;
        double lastEarlyEofPos = -1.0; // 上次提前 EOF 的位置(判文件截断用)
        int retryCount = 0;
        int failedEntryId = -1;
        QTimer *retryTimer = nullptr;
        QString m3uPath;           // 播放列表 m3u(重试时重新灌入)
        // 播放列表旋转序的条目 id(第 0 条 = 点播集):选集面板直跳映射
        // episodeId → playlist-play-index 用。
        QStringList playlistIds;
        // IPC 未就绪时暂存的播放列表调用(setEpisodeList 早到;就绪 flush
        // 原样补灌)。
        QVariantList pendingEpisodes;
        int pendingIndex = -1;
        QString pendingUrl;
        QVariantList pendingHeaders;
        QVariantMap pendingMeta;
        // 内嵌渲染输出尺寸(QML 上报;0 = 未知,回退 osd-dimensions)。
        int outW = 0, outH = 0;
        // 超分(Anime4K):当前档位、spawn 默认档位/快捷键是否已下发、
        // 最近一次回读结果(挂载数、两侧尺寸、门槛判定)。
        QString superResPreset = QStringLiteral("off");
        bool superResReady = false;
        QVariantMap superResState;
    };

    Session *sessionFor(const QString &key) const;
    Session *createSession(const QString &key);
    // 内嵌优先判定:编译带 libmpv + 配置非 external。
    bool embeddedPreferred() const;
    // handleLine 的 JSON 解析与分发分离:内嵌核心直接交 QJsonObject。
    void handleJson(Session *s, const QJsonObject &obj);
    // 章节表:file-loaded 时主动推送 → chaptersChanged(仅内部调用)。
    void refreshChapters(const QString &itemId);
    // 结束并销毁会话(清理资源;结束语义与回传由 stopAndConsiderEnd 承担)。
    void destroySession(Session *s);
    void spawnMpv(Session *s);
    // 加载失败后按退避策略重试失败条目(快速几次后转慢速,等网络恢复)。
    void scheduleRetry(Session *s);
    void sendJson(Session *s, const QJsonObject &obj);
    void handleLine(Session *s, const QByteArray &line);
    void handleEvent(Session *s, const QJsonObject &ev);
    void observe(Session *s);
    void flush(Session *s);
    // 文件加载后按 meta 所选轨在 track-list 中按同类型第 ordinal 条匹配出
    // mpv 数字 id,set aid/sid;两模式共享(外部经 IPC 同样可行,修复外部
    // 模式正数 ordinal 选轨被静默丢弃的缺口);字幕 -2 显式关。
    void applyTrackSelection(Session *s, const QJsonArray &trackList);
    void enqueueLoad(Session *s, const QString &url, const QVariantList &headers);
    // 超分:注册快捷键与默认档位(IPC 就绪后一次)、按档位挂载、回读校验。
    void initSuperRes(Session *s);
    // 把「键 档位 …」清单交 moe-hook.lua(弱绑定注册);脚本就绪晚于本类
    // 连接时由 moe-keys-request 触发补发。
    void sendSuperResKeys(Session *s);
    void applySuperRes(Session *s, const QString &presetId, bool announce);
    void requestSuperResState(Session *s);
    void reportStart(Session *s);
    void reportProgress(Session *s, bool force);
    void reportStopped(Session *s);
    // 按 key 结束会话:内部经 sessionFor 查找,对象销毁后查不到即安全返回
    // (避免两个事件源——QProcess::finished 与 QLocalSocket::readyRead——都对
    // 同一裸 Session* 触发时,后到者访问已释放对象)。key 按值传入:
    // destroySession 会释放 s->key 成员,须在函数内保留独立副本再 emit。
    // 会话键 = accountId|itemId(账号空 = 裸 itemId);起始集定死,
    // 换集不换键(会话路由恒走它,当前集 id 仅展示用)。
    static QString sessionKeyFor(const QVariantMap &meta);
    void stopAndConsiderEnd(QString key, bool errored);

    EmbyClient *m_emby = nullptr;
    ConfigManager *m_config = nullptr;
    QHash<QString, Session *> m_sessions;
    Session *m_active = nullptr;   // 最近活跃会话(无 itemId 控制时用)
    int m_nextKeyId = 0;
};
