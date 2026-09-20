#pragma once

#include <QHash>
#include <QJsonObject>
#include <QMutex>
#include <QObject>
#include <QQueue>
#include <QQuickFramebufferObject>
#include <QSharedPointer>

#include <atomic>

struct mpv_handle;
struct mpv_render_context;

//! 内嵌播放核心:一个 libmpv 实例(mpv_handle)+ 事件线程 + JSON IPC 模拟层。
//!
//! 设计要点:
//! - **JSON IPC 模拟**:MpvClient 的全部逻辑(observe/选轨/超分/换集 hook)
//!   都建立在 mpv 的 JSON IPC 之上;本类把 JSON 命令翻译成 mpv C API 调用,
//!   把 mpv_event 翻译回 JSON 行(事件侧用官方 mpv_event_to_node,形状与
//!   IPC 零漂移),使内嵌模式与外部进程模式共享同一套 MpvClient 逻辑,
//!   脚本(moe-hook.lua)与协议(script-message)零改动。
//! - **命令通道**:observe/get_property/set_property 走专用同步 API
//!   (get/set_property 是 JSON IPC 层特判,不在命令表;裸调 command_node
//!   报 invalid parameter,实测);命令表(loadfile 等)走
//!   mpv_command_node_async —— 同步 command_node 会阻塞等完成,vo=libmpv
//!   等待渲染上下文时把事件线程堵死(实测),async 应答经
//!   MPV_EVENT_COMMAND_REPLY 回同一事件泵,request_id 装 reply_userdata。
//! - **线程模型**:GUI 线程调 sendJson() 入队 + mpv_wakeup;事件线程
//!   mpv_wait_event 循环,醒后先排空命令队列,事件转换后经信号投递回
//!   GUI(Qt::QueuedConnection)。

//! 渲染资源共享持有者(GUI 的核心与渲染线程的 Renderer 各持一份,
//! 末引用析构):QQuickFramebufferObject 的 Renderer 由场景图在渲染线程
//! 异步删除,晚于 GUI 侧 Item/Core 析构 —— 裸指针回指 Core 会 UAF
//! (mpvqt 的 MpvResourceManager 同款考量)。析构顺序:先 free 渲染上下文
//! 再 terminate mpv(官方要求);可能在渲染线程执行(GL 上下文由场景图
//! 保证 current)或 GUI 线程(渲染器先走的情形,mpv 容忍)。
struct MpvRenderResources
{
    mpv_handle *mpv = nullptr;              // start() 后有效;Core 析构置空
    mpv_render_context *ctx = nullptr;      // 仅渲染线程建立
    QMutex mutex;                           // mpv 指针的访问闸
    ~MpvRenderResources();                  // 定义在 cpp(需 libmpv 头)
};
using MpvRenderResourcesPtr = QSharedPointer<MpvRenderResources>;

class MpvEmbeddedCore : public QObject
{
    Q_OBJECT
public:
    explicit MpvEmbeddedCore(QObject *parent = nullptr);
    ~MpvEmbeddedCore() override;

    // 创建并初始化 mpv 实例(幂等)。options 已内嵌(与外部 spawn 参数对齐:
    // keep-open/osc=no/缓存等;vo=libmpv 渲染走 Item)。hookScript =
    // moe-hook.lua 路径(换集钩子;空 = 不挂,纯播放)。
    // 运行时可用性:编译带头文件 + dlopen 到 libmpv.so.2(全程只查一次)。
    static bool runtimeAvailable();
    bool start(const QString &hookScript = {});
    mpv_handle *handle() const { return m_res ? m_res->mpv : nullptr; }
    MpvRenderResourcesPtr renderResources() const { return m_res; }

    // 与外部进程模式 sendJson 等价:obj 形如 {"command":[...]} 或带
    // request_id 的查询。GUI 线程调用,立即返回。
    void sendJson(const QJsonObject &obj);

signals:
    // 事件/应答的 JSON 化投递(GUI 线程)。格式与 mpv IPC 一致:
    // 事件 {"event":...},应答 {"request_id":N,"error":"success","data":...}。
    void jsonReceived(const QJsonObject &obj);
    // mpv 有新帧待渲(渲染上下文的 update 回调转发;回调本身严禁调 mpv)。
    void redrawRequested();
    // mpv 进程内退出(SHUTDOWN/实例销毁)。
    void terminated();

private:
    void eventLoop();
    void drainCommands();
    // JSON → mpv C API 单条执行(事件线程)。同步应答返回 JSON;
    // async 命令返回空对象(应答走 COMMAND_REPLY 事件)。
    QJsonObject execute(const QJsonObject &obj);

    MpvRenderResourcesPtr m_res;
    std::atomic<bool> m_abort{false};
    QMutex m_mutex;
    QQueue<QJsonObject> m_commands;
    class EventThread;
    EventThread *m_thread = nullptr;
};

//! QML 视频表面:内嵌 mpv 帧渲染载体(QQuickFramebufferObject)。
//! 生命周期:Item 创建即建 MpvEmbeddedCore(子对象);Core 析构停事件线程
//! 并置空共享句柄,渲染上下文与 mpv 实例由共享持有者在末引用处释放。
//! MpvClient 经 attachEmbedded 接管其会话。
class MpvVideoItem : public QQuickFramebufferObject
{
    Q_OBJECT
    // 播放位置/时长/暂停态由 MpvClient 经 JSON 事件更新后写入(只读镜像)。
    Q_PROPERTY(double position READ position NOTIFY positionChanged)
    Q_PROPERTY(double duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(bool paused READ paused NOTIFY pausedChanged)
    Q_PROPERTY(double volume READ volume NOTIFY volumeChanged)
    Q_PROPERTY(double speed READ speed NOTIFY speedChanged)
    // 缓冲到的时间点(秒;demuxer-cache-state 可寻范围的最大末端)。
    Q_PROPERTY(double buffered READ buffered NOTIFY bufferedChanged)
    // 卡顿等缓存中(paused-for-cache)。
    Q_PROPERTY(bool buffering READ buffering NOTIFY bufferingChanged)
    // libmpv 核心(MpvClient.attachEmbedded 的绑定对象;只读常驻)。
    Q_PROPERTY(MpvEmbeddedCore *core READ core CONSTANT)
public:
    explicit MpvVideoItem(QQuickItem *parent = nullptr);
    ~MpvVideoItem() override;

    Renderer *createRenderer() const override;
    MpvEmbeddedCore *core() const { return m_core; }

    double position() const { return m_position; }
    double duration() const { return m_duration; }
    bool paused() const { return m_paused; }
    double volume() const { return m_volume; }
    double speed() const { return m_speed; }
    double buffered() const { return m_buffered; }
    bool buffering() const { return m_buffering; }
    // MpvClient 写镜像(GUI 线程)。
    void setPlaybackState(double position, double duration, bool paused);
    // 直发命令(预览实例等 QML 自治场景;主会话控制请走 MpvClient)。
    Q_INVOKABLE void sendCommand(const QVariantList &cmd);
    void setVolumeSpeed(double volume, double speed);
    void setBuffered(double buffered);
    void setBuffering(bool buffering);

signals:
    void positionChanged();
    void durationChanged();
    void pausedChanged();
    void volumeChanged();
    void speedChanged();
    void bufferedChanged();
    void bufferingChanged();

private:
    MpvEmbeddedCore *m_core = nullptr;
    double m_position = 0.0;
    double m_duration = 0.0;
    bool m_paused = false;
    double m_volume = 100.0;
    double m_speed = 1.0;
    double m_buffered = 0.0;
    bool m_buffering = false;
};
