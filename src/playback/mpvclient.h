#pragma once

#include <QByteArray>
#include <QHash>
#include <QObject>
#include <QVariantList>
#include <QVariantMap>

class QJsonObject;
class QProcess;
class QLocalSocket;
class QTimer;
class EmbyClient;
class ConfigManager;

//! 外部 mpv 进程客户端(路线2)。
//!
//! 点播放即 spawn 系统 mpv 二进制(`--force-window`,`osc=no` + 项目自带的
//! 官方 osc.lua 经 `--script` 加载,由 mpv 原生窗口自绘 OSD/控制栏),Qt 不再
//! 渲染视频。经 `--input-ipc-server`(临时 unix socket)用 mpv JSON IPC 控制/订阅。
//!
//! Emby 播放状态回传(Start/Progress/Stopped/Ping)在此承接(替代原自绘窗口
//! PlayerWindow 的逻辑):起播上报、每 progressReportMs(项目 10s)进度节流、
//! 每 10 分钟 Ping、结束/关窗上报停止。协商链路:startPending 先弹 mpv 空窗
//! (先开窗后协商),deliver 交付地址起播,fail 关窗;Library 直连走 start。
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
    // 查找 osc.lua:<appdir>/osc.lua(发版内封) → 源码 third_party/osc.lua(开发)。
    static QString findOscScript();
    // 查找 moe-hook.lua(on_load 占位重定向):<appdir>/moe-hook.lua →
    // 源码 third_party/moe-hook.lua(交付内置,与 osc 同款)。
    static QString findMoeHookScript();

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
    // moe://ep/<id>(经 on_load hook 重定向,见 moe-hook.lua)。deliver 后
    // mpv 自动播第 0 条;点列表/上/下集/eof 连播都走 hook。
    Q_INVOKABLE void setEpisodeList(const QVariantList &episodes,
                                    const QString &currentItemId, int currentIndex,
                                    const QString &url, const QVariantList &headers,
                                    const QVariantMap &meta);
    // on_load hook 应答:占位条目经 moe-url 请求,QML 协商后的真实地址、
    // 流头、元数据与(可选)外挂字幕 URL;meta 供 file-loaded 归位/选轨。
    // url 为空 = 协商失败:通知 hook 继续(占位加载失败,mpv 跳过该条)。
    Q_INVOKABLE void deliverEpisodeUrl(const QString &itemId, const QString &url,
                                       const QVariantList &headers,
                                       const QVariantMap &meta,
                                       const QString &subtitleUrl = {});

signals:
    // 文件加载完成(可续播/seek)。
    void playbackStarted(const QString &itemId);
    // 当前播放集上下文(连播:QML 据 meta 查全集序列、协商下一集再
    // enqueueNext;meta.itemId 为实际播放中的集,可能不同于会话键)。
    void playbackContextChanged(const QVariantMap &meta);
    // 播放列表占位条目请求(moe-hook on_load):QML 协商该集真实地址后
    // deliverEpisodeUrl 回发。
    void episodeUrlRequested(const QString &itemId);
    // 播放结束(正常播完/出错/用户关窗)。error=true 表示异常退出。
    void playbackFinished(const QString &itemId, bool error);

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
        // eof 结束判定(playlist-pos → count 两次查询间的暂存)。
        int pendingEofPos = -1;
        // 全集列表已灌入(第 0 条 = 当前集真 URL,经播放列表播放)。
        bool listSet = false;
        // --input-ipc-server 文件 socket(fd 继承的 --input-ipc-client 在 mpv
        // 侧不生效,改用文件 socket + QLocalSocket,稳定且跨平台)。
        QLocalSocket *sock = nullptr;
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
    };

    Session *sessionFor(const QString &key) const;
    Session *createSession(const QString &key);
    // 结束并销毁会话;ended=true 表示因播放结束(需回传+信号),否则静默清理。
    void destroySession(Session *s, bool playEnded, bool errored);
    void spawnMpv(Session *s);
    void sendJson(Session *s, const QJsonObject &obj);
    void handleLine(Session *s, const QByteArray &line);
    void handleEvent(Session *s, const QJsonObject &ev);
    void observe(Session *s);
    void flush(Session *s);
    // 文件加载后按 meta 所选轨(Emby index/title/lang/codec)在 track-list
    // 中匹配出 mpv 数字 id,set aid/sid;字幕 -2 显式关。
    void applyTrackSelection(Session *s, const QJsonArray &trackList);
    void enqueueLoad(Session *s, const QString &url, const QVariantList &headers);
    void reportStart(Session *s);
    void reportProgress(Session *s, bool force);
    void reportStopped(Session *s);
    // 按 key 结束会话:内部经 sessionFor 查找,对象销毁后查不到即安全返回
    // (避免两个事件源——QProcess::finished 与 QLocalSocket::readyRead——都对
    // 同一裸 Session* 触发时,后到者访问已释放对象)。key 按值传入:
    // destroySession 会释放 s->key 成员,须在函数内保留独立副本再 emit。
    void stopAndConsiderEnd(QString key, bool errored);

    EmbyClient *m_emby = nullptr;
    ConfigManager *m_config = nullptr;
    QHash<QString, Session *> m_sessions;
    Session *m_active = nullptr;   // 最近活跃会话(无 itemId 控制时用)
    int m_nextKeyId = 0;
};
