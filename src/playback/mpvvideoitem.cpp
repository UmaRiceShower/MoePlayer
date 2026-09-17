#include "playback/mpvvideoitem.h"

#ifdef MOEPLAYER_HAVE_LIBMPV

#include <QJsonArray>
#include <QJsonDocument>
#include <QLibrary>
#include <QOpenGLContext>
#include <QOpenGLFramebufferObject>
#include <QStandardPaths>
#include <QThread>

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>

#include <deque>

#include "playback/mpvclient.h" // findMoeHookScript(Item 侧调用)

namespace {

// ---------- libmpv 运行时装载(dlopen)----------
// 内嵌是可选增强:构建只依赖头文件(pkg-config 的 CFLAGS),运行时 dlopen
// libmpv.so.2(API/ABI 自 libmpv 2.0 起稳定)。找不到库 = 外部模式兜底,
// deb/rpm/AppImage 均无硬依赖(AppImage 不会把 mpv+ffmpeg 拖进包)。
// Windows 同理可拓展(mpv-2.dll),本期不做。
struct MpvApi
{
#define MOE_MPV_FN(ret, name, args) ret (*name) args = nullptr;
    MOE_MPV_FN(mpv_handle *, mpv_create, (void))
    MOE_MPV_FN(int, mpv_initialize, (mpv_handle *))
    MOE_MPV_FN(void, mpv_terminate_destroy, (mpv_handle *))
    MOE_MPV_FN(int, mpv_set_option_string, (mpv_handle *, const char *, const char *))
    MOE_MPV_FN(int, mpv_request_log_messages, (mpv_handle *, const char *))
    MOE_MPV_FN(int, mpv_observe_property, (mpv_handle *, uint64_t, const char *, mpv_format))
    MOE_MPV_FN(int, mpv_unobserve_property, (mpv_handle *, uint64_t))
    MOE_MPV_FN(int, mpv_get_property, (mpv_handle *, const char *, mpv_format, void *))
    MOE_MPV_FN(char *, mpv_get_property_string, (mpv_handle *, const char *))
    MOE_MPV_FN(int, mpv_set_property, (mpv_handle *, const char *, mpv_format, void *))
    MOE_MPV_FN(int, mpv_command_node_async, (mpv_handle *, uint64_t, mpv_node *))
    MOE_MPV_FN(mpv_event *, mpv_wait_event, (mpv_handle *, double))
    MOE_MPV_FN(void, mpv_wakeup, (mpv_handle *))
    MOE_MPV_FN(const char *, mpv_event_name, (mpv_event_id))
    MOE_MPV_FN(int, mpv_event_to_node, (mpv_node *, mpv_event *))
    MOE_MPV_FN(void, mpv_free_node_contents, (mpv_node *))
    MOE_MPV_FN(void, mpv_free, (void *))
    MOE_MPV_FN(const char *, mpv_error_string, (int))
    MOE_MPV_FN(int, mpv_render_context_create, (mpv_render_context **, mpv_handle *, mpv_render_param *))
    MOE_MPV_FN(void, mpv_render_context_free, (mpv_render_context *))
    MOE_MPV_FN(int, mpv_render_context_render, (mpv_render_context *, mpv_render_param *))
    MOE_MPV_FN(void, mpv_render_context_set_update_callback,
               (mpv_render_context *, mpv_render_update_fn, void *))
#undef MOE_MPV_FN

    bool ok = false;
    static const MpvApi &get()
    {
        static const MpvApi api = [] {
            MpvApi a;
            // soname 固定 libmpv.so.2(client API 2.x);CLI 的 mpv 0.41 即此。
            // QLibrary 不可拷贝:堆上建,装载成功后有意常驻(永不卸载)。
            auto *lib = new QLibrary(QStringLiteral("libmpv.so.2"));
            if (!lib->load()) {
                delete lib;
                return a;
            }
            bool all = true;
#define MOE_MPV_FN(ret, name, args) \
            a.name = reinterpret_cast<ret (*) args>(lib->resolve(#name)); \
            all = all && a.name != nullptr;
            MOE_MPV_FN(mpv_handle *, mpv_create, (void))
            MOE_MPV_FN(int, mpv_initialize, (mpv_handle *))
            MOE_MPV_FN(void, mpv_terminate_destroy, (mpv_handle *))
            MOE_MPV_FN(int, mpv_set_option_string, (mpv_handle *, const char *, const char *))
            MOE_MPV_FN(int, mpv_request_log_messages, (mpv_handle *, const char *))
            MOE_MPV_FN(int, mpv_observe_property, (mpv_handle *, uint64_t, const char *, mpv_format))
            MOE_MPV_FN(int, mpv_unobserve_property, (mpv_handle *, uint64_t))
            MOE_MPV_FN(int, mpv_get_property, (mpv_handle *, const char *, mpv_format, void *))
            MOE_MPV_FN(char *, mpv_get_property_string, (mpv_handle *, const char *))
            MOE_MPV_FN(int, mpv_set_property, (mpv_handle *, const char *, mpv_format, void *))
            MOE_MPV_FN(int, mpv_command_node_async, (mpv_handle *, uint64_t, mpv_node *))
            MOE_MPV_FN(mpv_event *, mpv_wait_event, (mpv_handle *, double))
            MOE_MPV_FN(void, mpv_wakeup, (mpv_handle *))
            MOE_MPV_FN(const char *, mpv_event_name, (mpv_event_id))
            MOE_MPV_FN(int, mpv_event_to_node, (mpv_node *, mpv_event *))
            MOE_MPV_FN(void, mpv_free_node_contents, (mpv_node *))
            MOE_MPV_FN(void, mpv_free, (void *))
            MOE_MPV_FN(const char *, mpv_error_string, (int))
            MOE_MPV_FN(int, mpv_render_context_create, (mpv_render_context **, mpv_handle *, mpv_render_param *))
            MOE_MPV_FN(void, mpv_render_context_free, (mpv_render_context *))
            MOE_MPV_FN(int, mpv_render_context_render, (mpv_render_context *, mpv_render_param *))
            MOE_MPV_FN(void, mpv_render_context_set_update_callback,
                       (mpv_render_context *, mpv_render_update_fn, void *))
#undef MOE_MPV_FN
            a.ok = all;
            if (!all)
                delete lib; // 解析不全 = 不可用,卸载回外部模式
            return a;
        }();
        return api;
    }
};

} // namespace(MpvApi 段)
// 全文件调用点统一经 api():mpv_xxx(...) → MpvApi::get().mpv_xxx(...)。
// 用宏让下文代码与直链写法保持同形,便于与 mpv 文档/示例对照。
#define mpv_create MpvApi::get().mpv_create
#define mpv_initialize MpvApi::get().mpv_initialize
#define mpv_terminate_destroy MpvApi::get().mpv_terminate_destroy
#define mpv_set_option_string MpvApi::get().mpv_set_option_string
#define mpv_request_log_messages MpvApi::get().mpv_request_log_messages
#define mpv_observe_property MpvApi::get().mpv_observe_property
#define mpv_unobserve_property MpvApi::get().mpv_unobserve_property
#define mpv_get_property MpvApi::get().mpv_get_property
#define mpv_get_property_string MpvApi::get().mpv_get_property_string
#define mpv_set_property MpvApi::get().mpv_set_property
#define mpv_command_node_async MpvApi::get().mpv_command_node_async
#define mpv_wait_event MpvApi::get().mpv_wait_event
#define mpv_wakeup MpvApi::get().mpv_wakeup
#define mpv_event_name MpvApi::get().mpv_event_name
#define mpv_event_to_node MpvApi::get().mpv_event_to_node
#define mpv_free_node_contents MpvApi::get().mpv_free_node_contents
#define mpv_free MpvApi::get().mpv_free
#define mpv_error_string MpvApi::get().mpv_error_string
#define mpv_render_context_create MpvApi::get().mpv_render_context_create
#define mpv_render_context_free MpvApi::get().mpv_render_context_free
#define mpv_render_context_render MpvApi::get().mpv_render_context_render
#define mpv_render_context_set_update_callback MpvApi::get().mpv_render_context_set_update_callback

namespace {

// ---------- QJsonValue ↔ mpv_node 转换 ----------

// 转换期内存持有者:mpv_node 里的指针在 mpv 调用返回前必须有效。
// 必须 deque:vector 在 emplace 时整体搬迁,先存的 .back() 指针/引用
// 全部悬空;deque 的 push_back 不失效已有元素的引用。
struct NodePool
{
    std::deque<QByteArray> strings;
    std::deque<std::vector<mpv_node>> arrays;
    std::deque<std::vector<char *>> keyPtrs; // NODE_MAP 的 keys 是 char**
    std::deque<mpv_node_list> lists;
};

mpv_node jsonToNode(const QJsonValue &v, NodePool &pool)
{
    mpv_node n{};
    switch (v.type()) {
    case QJsonValue::Bool:
        n.format = MPV_FORMAT_FLAG;
        n.u.flag = v.toBool();
        return n;
    case QJsonValue::Double: {
        // 整数值给 INT64(mpv 对整数参数更宽容),小数给 DOUBLE。
        const double d = v.toDouble();
        const qint64 i = static_cast<qint64>(d);
        if (static_cast<double>(i) == d) {
            n.format = MPV_FORMAT_INT64;
            n.u.int64 = i;
        } else {
            n.format = MPV_FORMAT_DOUBLE;
            n.u.double_ = d;
        }
        return n;
    }
    case QJsonValue::String:
        pool.strings.push_back(v.toString().toUtf8());
        n.format = MPV_FORMAT_STRING;
        n.u.string = const_cast<char *>(pool.strings.back().constData());
        return n;
    case QJsonValue::Array: {
        const QJsonArray arr = v.toArray();
        pool.arrays.emplace_back();
        auto &vec = pool.arrays.back();
        vec.reserve(arr.size());
        for (const QJsonValue &e : arr)
            vec.push_back(jsonToNode(e, pool));
        mpv_node_list list{};
        list.num = int(vec.size());
        list.values = vec.data();
        pool.lists.push_back(list);
        n.format = MPV_FORMAT_NODE_ARRAY;
        n.u.list = &pool.lists.back();
        return n;
    }
    case QJsonValue::Object: {
        const QJsonObject obj = v.toObject();
        pool.keyPtrs.emplace_back();
        pool.arrays.emplace_back();
        auto &keys = pool.keyPtrs.back();
        auto &vals = pool.arrays.back();
        keys.reserve(obj.size());
        vals.reserve(obj.size());
        for (auto it = obj.begin(); it != obj.end(); ++it) {
            pool.strings.push_back(it.key().toUtf8());
            keys.push_back(const_cast<char *>(pool.strings.back().constData()));
            vals.push_back(jsonToNode(it.value(), pool));
        }
        mpv_node_list list{};
        list.num = int(keys.size());
        list.keys = keys.data();
        list.values = vals.data();
        pool.lists.push_back(list);
        n.format = MPV_FORMAT_NODE_MAP;
        n.u.list = &pool.lists.back();
        return n;
    }
    default:
        n.format = MPV_FORMAT_NONE;
        return n;
    }
}

QJsonValue nodeToJson(const mpv_node *n)
{
    switch (n->format) {
    case MPV_FORMAT_FLAG:
        return bool(n->u.flag);
    case MPV_FORMAT_INT64:
        return double(n->u.int64);
    case MPV_FORMAT_DOUBLE:
        return n->u.double_;
    case MPV_FORMAT_STRING:
        return QString::fromUtf8(n->u.string);
    case MPV_FORMAT_NODE_ARRAY: {
        QJsonArray arr;
        for (int i = 0; i < n->u.list->num; ++i)
            arr.append(nodeToJson(&n->u.list->values[i]));
        return arr;
    }
    case MPV_FORMAT_NODE_MAP: {
        QJsonObject obj;
        for (int i = 0; i < n->u.list->num; ++i)
            obj.insert(QString::fromUtf8(n->u.list->keys[i]),
                       nodeToJson(&n->u.list->values[i]));
        return obj;
    }
    case MPV_FORMAT_BYTE_ARRAY: // 不用于我们的命令面
    case MPV_FORMAT_NONE:
    default:
        return QJsonValue();
    }
}

void *mpvGetProcAddress(void * /*ctx*/, const char *name)
{
    // render 线程调用时 GL 上下文必已 current。
    QOpenGLContext *ctx = QOpenGLContext::currentContext();
    return ctx ? reinterpret_cast<void *>(ctx->getProcAddress(name)) : nullptr;
}

} // namespace

// ---------- 渲染资源共享持有者 ----------

MpvRenderResources::~MpvRenderResources()
{
    // 官方顺序:先 free 渲染上下文,再 terminate 实例。
    if (ctx)
        mpv_render_context_free(ctx);
    if (mpv)
        mpv_terminate_destroy(mpv);
}

// 渲染线程(GL 上下文 current)把 mpv 帧渲进 fbo;首次调用建上下文。
// 返回 false = 未就绪(黑帧)。
static bool renderIntoFbo(MpvRenderResources &res, int fbo, int w, int h,
                          MpvEmbeddedCore *updateTarget)
{
    if (!res.mpv)
        return false;
    if (!res.ctx) {
        mpv_opengl_init_params glInit{mpvGetProcAddress, nullptr};
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_API_TYPE, const_cast<char *>(MPV_RENDER_API_TYPE_OPENGL)},
            {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &glInit},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        if (mpv_render_context_create(&res.ctx, res.mpv, params) < 0) {
            qWarning() << "MpvEmbeddedCore: 渲染上下文创建失败";
            res.ctx = nullptr;
            return false;
        }
        // mpv 有新帧 → 排队重绘(回调只准做这一件事,严禁调任何 mpv 函数)。
        mpv_render_context_set_update_callback(
            res.ctx,
            [](void *ctx) {
                auto *target = static_cast<MpvEmbeddedCore *>(ctx);
                emit target->redrawRequested();
            },
            updateTarget);
        qInfo() << "MpvEmbeddedCore: 渲染上下文已建立";
    }
    mpv_opengl_fbo mpfbo{fbo, w, h, 0};
    int flip = 0; // 与 mpvqt 一致:QQuickFramebufferObject 的 FBO 无需翻转
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_OPENGL_FBO, &mpfbo},
        {MPV_RENDER_PARAM_FLIP_Y, &flip},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    return mpv_render_context_render(res.ctx, params) >= 0;
}

// ---------- 事件线程 ----------

class MpvEmbeddedCore::EventThread : public QThread
{
public:
    explicit EventThread(MpvEmbeddedCore *core) : m_core(core) {}

protected:
    void run() override { m_core->eventLoop(); }

private:
    MpvEmbeddedCore *m_core;
};

MpvEmbeddedCore::MpvEmbeddedCore(QObject *parent)
    : QObject(parent)
    , m_res(MpvRenderResourcesPtr::create())
{
}

MpvEmbeddedCore::~MpvEmbeddedCore()
{
    m_abort = true;
    if (m_res->mpv)
        mpv_wakeup(m_res->mpv);
    if (m_thread) {
        m_thread->wait(3000);
        delete m_thread;
        m_thread = nullptr;
    }
    // 事件线程已停。渲染上下文可能还在(Renderer 异步存活):先注销
    // update 回调(目标是本对象,不注销则回调打野指针;该 API 为控制面
    // 调用,任意线程合法),再置空句柄拒绝后续渲染。实例本体由共享持有者
    // 在末引用处按「先 ctx 后 mpv」序释放。
    {
        QMutexLocker lk(&m_res->mutex);
        if (m_res->ctx)
            mpv_render_context_set_update_callback(m_res->ctx, nullptr, nullptr);
        m_res->mpv = nullptr;
    }
    m_res.clear(); // 若 Renderer 仍持有,由它续命到渲染线程释放
}

bool MpvEmbeddedCore::runtimeAvailable()
{
    return MpvApi::get().ok;
}

bool MpvEmbeddedCore::start(const QString &hookScript)
{
    if (m_res->mpv)
        return true;
    if (!MpvApi::get().ok) {
        qInfo() << "MpvEmbeddedCore: libmpv.so.2 不可用,内嵌模式禁用";
        return false;
    }
    mpv_handle *mpv = mpv_create();
    if (!mpv) {
        qWarning() << "MpvEmbeddedCore: mpv_create 失败";
        return false;
    }
    // 选项与外部进程 spawn 参数对齐(差异:vo=libmpv 替代 force-window;
    // 无 terminal/输入绑定——输入由 QML 转发,界面由 QML 承担)。
    mpv_set_option_string(mpv, "vo", "libmpv");
    mpv_set_option_string(mpv, "keep-open", "yes");
    mpv_set_option_string(mpv, "idle", "yes");
    mpv_set_option_string(mpv, "osc", "no");
    mpv_set_option_string(mpv, "osd-bar", "no");
    mpv_set_option_string(mpv, "input-default-bindings", "no");
    mpv_set_option_string(mpv, "input-vo-keyboard", "no");
    mpv_set_option_string(mpv, "input-terminal", "no");
    mpv_set_option_string(mpv, "terminal", "no");
    mpv_set_option_string(mpv, "cache", "yes");
    mpv_set_option_string(mpv, "hwdec", "auto-safe");
    mpv_set_option_string(mpv, "stop-screensaver", "yes");
    mpv_set_option_string(mpv, "osd-playlist-entry", "title");
    // 日志走 MPV_EVENT_LOG_MESSAGE(事件线程转发 [mpv] 前缀,与进程
    // 模式的 stdout 转发同级)。status 级保留状态行(诊断用)。
    mpv_request_log_messages(mpv, "status");
    // on_load 换集钩子(占位条目重定向,连播核心);空 = 不挂(测试/纯播放)。
    if (!hookScript.isEmpty()) {
        const QByteArray hookUtf8 = hookScript.toUtf8();
        mpv_set_option_string(mpv, "scripts", hookUtf8.constData());
    }
    // 截图落点与外部模式一致。
    const QString shotDir =
        QStandardPaths::writableLocation(QStandardPaths::PicturesLocation) +
        QStringLiteral("/MoePlayer");
    mpv_set_option_string(mpv, "screenshot-dir", shotDir.toUtf8().constData());

    const int err = mpv_initialize(mpv);
    if (err < 0) {
        qWarning() << "MpvEmbeddedCore: mpv_initialize 失败" << mpv_error_string(err);
        mpv_terminate_destroy(mpv);
        return false;
    }
    m_res->mpv = mpv;
    m_thread = new EventThread(this);
    m_thread->start();
    if (char *ver = mpv_get_property_string(mpv, "mpv-version")) {
        qInfo() << "MpvEmbeddedCore: libmpv 实例已就绪" << ver;
        mpv_free(ver);
    }
    emit ready();
    return true;
}

void MpvEmbeddedCore::sendJson(const QJsonObject &obj)
{
    {
        QMutexLocker lk(&m_mutex);
        m_commands.enqueue(obj);
    }
    if (m_res->mpv)
        mpv_wakeup(m_res->mpv);
}

// 单条 JSON 命令 → mpv C API(事件线程执行)。同步应答返回应答复 JSON;
// async 命令返回空对象(应答经 MPV_EVENT_COMMAND_REPLY 再投递)。
QJsonObject MpvEmbeddedCore::execute(const QJsonObject &obj)
{
    const QJsonArray cmd = obj.value(QStringLiteral("command")).toArray();
    const int requestId = obj.value(QStringLiteral("request_id")).toInt(0);
    QJsonObject reply;
    if (requestId)
        reply.insert(QStringLiteral("request_id"), requestId);
    if (cmd.isEmpty()) {
        reply.insert(QStringLiteral("error"), QStringLiteral("invalid parameter"));
        return reply;
    }
    const QString name = cmd.first().toString();
    mpv_handle *mpv = m_res->mpv;

    // observe/unobserve 走专用 API(命令形式在 libmpv 也支持,但直调更省转换)。
    if (name == QLatin1String("observe_property") && cmd.size() >= 3) {
        const quint64 id = quint64(cmd.at(1).toVariant().toULongLong());
        const QString prop = cmd.at(2).toString();
        m_observed.insert(id, prop);
        mpv_observe_property(mpv, id, prop.toUtf8().constData(), MPV_FORMAT_NODE);
        reply.insert(QStringLiteral("error"), QStringLiteral("success"));
        return reply;
    }
    if (name == QLatin1String("unobserve_property") && cmd.size() >= 2) {
        const quint64 id = quint64(cmd.at(1).toVariant().toULongLong());
        m_observed.remove(id);
        mpv_unobserve_property(mpv, id);
        reply.insert(QStringLiteral("error"), QStringLiteral("success"));
        return reply;
    }
    // get_property/set_property 是 JSON IPC 层的特判命令(ipc.c 拦获),不在
    // mpv_command 的命令表里 —— 内嵌侧必须同样特判(裸调 command_node 报
    // invalid parameter,实测)。
    if (name == QLatin1String("get_property") && cmd.size() >= 2) {
        const QByteArray prop = cmd.at(1).toString().toUtf8();
        mpv_node val{};
        const int err = mpv_get_property(mpv, prop.constData(), MPV_FORMAT_NODE, &val);
        reply.insert(QStringLiteral("error"), QString::fromUtf8(mpv_error_string(err)));
        if (err >= 0) {
            reply.insert(QStringLiteral("data"), nodeToJson(&val));
            mpv_free_node_contents(&val);
        }
        return reply;
    }
    if (name == QLatin1String("set_property") && cmd.size() >= 3) {
        const QByteArray prop = cmd.at(1).toString().toUtf8();
        NodePool pool;
        mpv_node val = jsonToNode(cmd.at(2), pool);
        const int err = mpv_set_property(mpv, prop.constData(), MPV_FORMAT_NODE, &val);
        reply.insert(QStringLiteral("error"), QString::fromUtf8(mpv_error_string(err)));
        return reply;
    }

    // 命令表(loadfile 等):mpv_command_node 同步等完成,vo=libmpv 等待渲染
    // 上下文时会把事件线程堵死(实测)——一律 async:立即入队返回,应答经
    // MPV_EVENT_COMMAND_REPLY 回来,request_id 原样装在 reply_userdata。
    NodePool pool;
    std::vector<mpv_node> vals;
    vals.reserve(cmd.size());
    for (const QJsonValue &v : cmd)
        vals.push_back(jsonToNode(v, pool));
    mpv_node_list list{};
    list.num = int(vals.size());
    list.values = vals.data();
    mpv_node args{};
    args.format = MPV_FORMAT_NODE_ARRAY;
    args.u.list = &list;
    const int err = mpv_command_node_async(mpv, quint64(requestId), &args);
    if (err < 0) {
        reply.insert(QStringLiteral("error"), QString::fromUtf8(mpv_error_string(err)));
        return reply;
    }
    return {}; // 应答在事件循环的 COMMAND_REPLY 分支
}

void MpvEmbeddedCore::drainCommands()
{
    for (;;) {
        QJsonObject obj;
        {
            QMutexLocker lk(&m_mutex);
            if (m_commands.isEmpty())
                return;
            obj = m_commands.dequeue();
        }
        const QJsonObject reply = execute(obj);
        // 只回投带 request_id 的同步应答;async 命令的应答走事件。
        if (reply.contains(QStringLiteral("request_id")))
            emit jsonReceived(reply);
    }
}

void MpvEmbeddedCore::eventLoop()
{
    // 句柄在事件线程存活期稳定(Core 析构先 join 本线程再置空)。
    mpv_handle *mpv = m_res->mpv;
    while (!m_abort) {
        mpv_event *ev = mpv_wait_event(mpv, -1);
        if (m_abort)
            break;
        drainCommands(); // wakeup 唤醒后先执行积压命令
        if (ev->event_id == MPV_EVENT_NONE)
            continue;

        QJsonObject obj;
        bool deliver = true;
        switch (ev->event_id) {
        case MPV_EVENT_COMMAND_REPLY: {
            // async 命令应答:reply_userdata = 调用方 request_id(0 = 无 id,
            // 与 IPC 无 id 命令无应答同语义,丢弃)。
            if (ev->reply_userdata == 0) {
                deliver = false;
                break;
            }
            const auto *cr = static_cast<mpv_event_command *>(ev->data);
            if (ev->error < 0)
                qWarning() << "MpvEmbeddedCore: 命令失败"
                           << QString::fromUtf8(mpv_error_string(ev->error))
                           << "request_id" << ev->reply_userdata;
            obj.insert(QStringLiteral("request_id"), double(ev->reply_userdata));
            obj.insert(QStringLiteral("error"),
                       QString::fromUtf8(mpv_error_string(ev->error)));
            if (ev->error >= 0 && cr && cr->result.format != MPV_FORMAT_NONE)
                obj.insert(QStringLiteral("data"), nodeToJson(&cr->result));
            break;
        }
        case MPV_EVENT_PROPERTY_CHANGE:
        case MPV_EVENT_CLIENT_MESSAGE:
        case MPV_EVENT_FILE_LOADED:
        case MPV_EVENT_END_FILE: {
            // 官方 mpv_event_to_node:产出与 JSON IPC 事件同构的 node map
            // (client.h:1655),形状零漂移,免去逐字段手写。
            mpv_node node{};
            if (mpv_event_to_node(&node, ev) < 0) {
                deliver = false;
                break;
            }
            obj = nodeToJson(&node).toObject();
            mpv_free_node_contents(&node);
            // 事件名:mpv_event_name 返回与 IPC 一致的 kebab-case。
            obj.insert(QStringLiteral("event"),
                       QString::fromUtf8(mpv_event_name(ev->event_id)));
            if (ev->event_id == MPV_EVENT_PROPERTY_CHANGE && ev->reply_userdata)
                obj.insert(QStringLiteral("id"), double(ev->reply_userdata));
            break;
        }
        case MPV_EVENT_LOG_MESSAGE: {
            const auto *lm = static_cast<mpv_event_log_message *>(ev->data);
            // 与进程模式同前缀 [mpv];级别行原样透传(status 级含状态行)。
            qInfo().noquote() << "[mpv]" << QString::fromUtf8(lm->text).trimmed();
            deliver = false;
            break;
        }
        case MPV_EVENT_SHUTDOWN:
            emit terminated();
            deliver = false;
            break;
        default:
            deliver = false;
            break;
        }
        if (deliver)
            emit jsonReceived(obj);
    }
}

// ---------- MpvVideoItem ----------

class MpvVideoRenderer : public QQuickFramebufferObject::Renderer
{
public:
    explicit MpvVideoRenderer(MpvEmbeddedCore *core)
        : m_res(core->renderResources())
        , m_core(core)
    {
    }

    // 析构(渲染线程,场景图异步):无需动手——渲染上下文与 mpv 实例由
    // 共享持有者在末引用处按序释放(本对象通常即末引用)。

    QOpenGLFramebufferObject *createFramebufferObject(const QSize &size) override
    {
        return new QOpenGLFramebufferObject(size, QOpenGLFramebufferObject::NoAttachment);
    }

    void render() override
    {
        QMutexLocker lk(&m_res->mutex);
        if (m_res->mpv && m_core) {
            QOpenGLFramebufferObject *f = framebufferObject();
            renderIntoFbo(*m_res, int(f->handle()), f->width(), f->height(), m_core);
        }
    }

private:
    MpvRenderResourcesPtr m_res; // 共享持有:Core 先析构本对象仍安全
    MpvEmbeddedCore *m_core;     // 仅作 update 回调目标;Core 析构即不再渲染
                                 // (mpv=null 短路),不会经此解引用已死对象
};

MpvVideoItem::MpvVideoItem(QQuickItem *parent)
    : QQuickFramebufferObject(parent)
{
    m_core = new MpvEmbeddedCore(this);
    // 新帧 → 重绘(渲染线程回调只发信号,GUI 线程执行 update)。
    connect(m_core, &MpvEmbeddedCore::redrawRequested, this,
            qOverload<>(&QQuickItem::update));
    // 播放状态镜像:直接从核心事件流喂(不经 MpvClient 回写,页面自洽)。
    connect(m_core, &MpvEmbeddedCore::jsonReceived, this,
            [this](const QJsonObject &obj) {
                if (obj.value(QStringLiteral("event")).toString()
                    != QLatin1String("property-change"))
                    return;
                const QString name = obj.value(QStringLiteral("name")).toString();
                const QJsonValue data = obj.value(QStringLiteral("data"));
                if (name == QLatin1String("time-pos") && data.isDouble())
                    setPlaybackState(data.toDouble(), m_duration, m_paused);
                else if (name == QLatin1String("duration") && data.isDouble())
                    setPlaybackState(m_position, data.toDouble(), m_paused);
                else if (name == QLatin1String("pause") && data.isBool())
                    setPlaybackState(m_position, m_duration, data.toBool());
                else if (name == QLatin1String("volume") && data.isDouble())
                    setVolumeSpeed(data.toDouble(), m_speed);
                else if (name == QLatin1String("speed") && data.isDouble())
                    setVolumeSpeed(m_volume, data.toDouble());
                else if (name == QLatin1String("paused-for-cache") && data.isBool())
                    setBuffering(data.toBool());
                else if (name == QLatin1String("demuxer-cache-state") && data.isObject()) {
                    // 可寻范围的最大末端 = 进度条缓存带右缘。
                    double end = 0.0;
                    const QJsonArray ranges =
                        data.toObject().value(QStringLiteral("seekable-ranges")).toArray();
                    for (const QJsonValue &r : ranges)
                        end = qMax(end, r.toObject().value(QStringLiteral("end")).toDouble());
                    setBuffered(end);
                }
            });
    m_core->start(MpvClient::findMoeHookScript());
}

MpvVideoItem::~MpvVideoItem() = default;

MpvVideoItem::Renderer *MpvVideoItem::createRenderer() const
{
    return new MpvVideoRenderer(m_core);
}

void MpvVideoItem::sendCommand(const QVariantList &cmd)
{
    QJsonArray arr;
    for (const QVariant &v : cmd)
        arr.append(QJsonValue::fromVariant(v));
    m_core->sendJson(QJsonObject{{QStringLiteral("command"), arr}});
}

void MpvVideoItem::setPlaybackState(double position, double duration, bool paused)
{
    if (m_position != position) {
        m_position = position;
        emit positionChanged();
    }
    if (m_duration != duration) {
        m_duration = duration;
        emit durationChanged();
    }
    if (m_paused != paused) {
        m_paused = paused;
        emit pausedChanged();
    }
}

void MpvVideoItem::setBuffering(bool buffering)
{
    if (m_buffering != buffering) {
        m_buffering = buffering;
        emit bufferingChanged();
    }
}

void MpvVideoItem::setBuffered(double buffered)
{
    if (m_buffered != buffered) {
        m_buffered = buffered;
        emit bufferedChanged();
    }
}

void MpvVideoItem::setVolumeSpeed(double volume, double speed)
{
    if (m_volume != volume) {
        m_volume = volume;
        emit volumeChanged();
    }
    if (m_speed != speed) {
        m_speed = speed;
        emit speedChanged();
    }
}

#else // !MOEPLAYER_HAVE_LIBMPV —— 占位实现(无 libmpv 的平台仍可编译链接)

#include <QOpenGLFramebufferObject>

MpvRenderResources::~MpvRenderResources() = default;

MpvEmbeddedCore::MpvEmbeddedCore(QObject *parent) : QObject(parent) {}
MpvEmbeddedCore::~MpvEmbeddedCore() = default;
bool MpvEmbeddedCore::runtimeAvailable() { return false; }
bool MpvEmbeddedCore::start(const QString &) { return false; }
void MpvEmbeddedCore::sendJson(const QJsonObject &) {}

namespace {
class NullRenderer : public QQuickFramebufferObject::Renderer
{
public:
    QOpenGLFramebufferObject *createFramebufferObject(const QSize &size) override
    {
        return new QOpenGLFramebufferObject(size);
    }
    void render() override {}
};
} // namespace

MpvVideoItem::MpvVideoItem(QQuickItem *parent) : QQuickFramebufferObject(parent)
{
    m_core = new MpvEmbeddedCore(this);
}
MpvVideoItem::~MpvVideoItem() = default;
MpvVideoItem::Renderer *MpvVideoItem::createRenderer() const { return new NullRenderer; }
void MpvVideoItem::setPlaybackState(double, double, bool) {}
void MpvVideoItem::sendCommand(const QVariantList &) {}
void MpvVideoItem::setVolumeSpeed(double, double) {}

#endif
