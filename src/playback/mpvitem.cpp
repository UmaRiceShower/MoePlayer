#include "mpvitem.h"

#include <QDebug>
#include <QOpenGLContext>
#include <QOpenGLFramebufferObject>
#include <QQuickWindow>
#include <QMetaObject>
#include <QCoreApplication>

#include <stdexcept>

#include "core/constants.h"

namespace {

// mpv 事件回调:投递到 GUI 线程的 onMpvEvents() 排空事件队列。
void wakeupCallback(void *ctx)
{
    QMetaObject::invokeMethod(static_cast<MpvItem *>(ctx), "onMpvEvents",
                              Qt::QueuedConnection);
}

// 渲染线程回调:请求 GUI 线程调度新一帧。
void updateCallback(void *ctx)
{
    QMetaObject::invokeMethod(static_cast<MpvItem *>(ctx), "update",
                              Qt::QueuedConnection);
}

// mpv 在渲染线程、GL 上下文当前时调用,取 OpenGL 函数指针。
void *getProcAddress(void *, const char *name)
{
    QOpenGLContext *glctx = QOpenGLContext::currentContext();
    if (!glctx)
        return nullptr;
    return reinterpret_cast<void *>(glctx->getProcAddress(QByteArray(name)));
}

} // namespace

class MpvRenderer : public QQuickFramebufferObject::Renderer
{
public:
    explicit MpvRenderer(MpvItem *item)
        : m_item(item)
    {
    }

    QOpenGLFramebufferObject *createFramebufferObject(const QSize &size) override
    {
        // 首个帧在渲染线程创建 render context(须与当前线程的 GL 上下文绑定)。
        if (!m_item->m_mpvRC) {
            mpv_opengl_init_params glParams{ getProcAddress, nullptr };
            mpv_render_param params[] = {
                { MPV_RENDER_PARAM_API_TYPE, const_cast<char *>(MPV_RENDER_API_TYPE_OPENGL) },
                { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &glParams },
                { MPV_RENDER_PARAM_INVALID, nullptr }
            };
            if (mpv_render_context_create(&m_item->m_mpvRC, m_item->m_mpv, params) < 0)
                throw std::runtime_error("failed to initialize mpv GL context");
            mpv_render_context_set_update_callback(m_item->m_mpvRC, updateCallback, m_item);
        }
        return QQuickFramebufferObject::Renderer::createFramebufferObject(size);
    }

    void render() override
    {
        // 把视频绘制进场景图的 FBO,交给 Qt 合成到窗口。
        QOpenGLFramebufferObject *fbo = framebufferObject();
        mpv_opengl_fbo mpfbo{ static_cast<int>(fbo->handle()), fbo->width(),
                              fbo->height(), 0 };
        int flipY = 0;
        mpv_render_param params[] = {
            { MPV_RENDER_PARAM_OPENGL_FBO, &mpfbo },
            { MPV_RENDER_PARAM_FLIP_Y, &flipY },
            { MPV_RENDER_PARAM_INVALID, nullptr }
        };
        mpv_render_context_render(m_item->m_mpvRC, params);
    }

private:
    MpvItem *m_item;
};

MpvItem::MpvItem(QQuickItem *parent)
    : QQuickFramebufferObject(parent)
{
    setTextureFollowsItemSize(true);

    m_mpv = mpv_create();
    if (!m_mpv)
        throw std::runtime_error(
            "mpv_create 失败(通常没装 libmpv:Arch `pacman -S mpv`,或把 libmpv.so.2 放到程序同级目录)");

    mpv_set_option_string(m_mpv, "terminal", "yes");
    mpv_set_option_string(m_mpv, "vo", "libmpv");
    mpv_set_option_string(m_mpv, "gpu-api", "opengl");
    // 软解:vaapi-copy 在播放中可能解码失败且不会中途回退(打开时探测
    // 已选定后不再切换),表现为 "Video: no video";软解保证画面稳定。
    mpv_set_option_string(m_mpv, "hwdec", "no");
    // 统一 UA(软件名/版本号):mpv 取流(Emby DirectStream)用应用 UA,不用默认。
    mpv_set_option_string(m_mpv, "user-agent",
                          MoePlayer::userAgent().toUtf8().constData());
    mpv_set_option_string(m_mpv, "sub-auto", "fuzzy");
    mpv_set_option_string(m_mpv, "idle", "yes");
    mpv_set_option_string(m_mpv, "volume", "100");
    // 官方 OSC(进度条/按钮/时间)由 mpv 绘制进画面;render API 下注入的输入事件
    // 不会触发 OSC 自动显示,故固定为常显。
    mpv_set_option_string(m_mpv, "osc", "yes");
    mpv_set_option_string(m_mpv, "script-opts", "osc-visibility=always");
    // libmpv 默认关闭默认按键绑定,此处开启以支持转发空格/方向键等控制。
    mpv_set_option_string(m_mpv, "input-default-bindings", "yes");

    if (mpv_initialize(m_mpv) < 0) {
        mpv_terminate_destroy(m_mpv);
        throw std::runtime_error("mpv_initialize 失败(多半是播放器选项写错,见终端日志)");
    }

    mpv_set_wakeup_callback(m_mpv, wakeupCallback, this);
    mpv_observe_property(m_mpv, 1, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 2, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 3, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 4, "core-idle", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 5, "volume", MPV_FORMAT_INT64);
}

MpvItem::~MpvItem()
{
    if (m_mpvRC)
        mpv_render_context_free(m_mpvRC);
    mpv_terminate_destroy(m_mpv);
    m_mpv = nullptr;
}

QQuickFramebufferObject::Renderer *MpvItem::createRenderer() const
{
    return new MpvRenderer(const_cast<MpvItem *>(this));
}

QString MpvItem::state() const
{
    if (m_idle)
        return QStringLiteral("idle");
    return m_paused ? QStringLiteral("paused") : QStringLiteral("playing");
}

void MpvItem::setVolume(int v)
{
    v = qBound(0, v, 100);
    if (v == m_volume)
        return;
    m_volume = v;
    mpv_set_property(m_mpv, "volume", MPV_FORMAT_INT64, &v);
    emit volumeChanged();
}

void MpvItem::setHttpProxy(const QString &spec)
{
    // 仅 http/https scheme 生效(防御性:配置层已限 HTTP,防手改配置绕过);
    // 空串 = 直连,清空选项。
    const QString trimmed = spec.trimmed();
    m_httpProxy = (trimmed.startsWith(QLatin1String("http://"))
                   || trimmed.startsWith(QLatin1String("https://")))
                      ? trimmed
                      : QString();
}

void MpvItem::load(const QString &url, const QStringList &headers)
{
    // 流请求所需的自定义头(如 Emby 认证)经 http-header-fields 选项下发,须在 loadfile 前设置。
    if (!headers.isEmpty())
        mpv_set_option_string(m_mpv, "http-header-fields", headers.join(QStringLiteral(", ")).toUtf8().constData());
    // 播放流代理(HTTP;经选项下发,须在 loadfile 前设置)。
    if (!m_httpProxy.isEmpty())
        mpv_set_option_string(m_mpv, "http-proxy", m_httpProxy.toUtf8().constData());
    command({ QStringLiteral("loadfile"), url });
}

void MpvItem::seek(double seconds)
{
    command({ QStringLiteral("seek"), QString::number(seconds, 'f', 3),
              QStringLiteral("absolute") });
}

void MpvItem::setPause(bool p)
{
    mpv_set_property(m_mpv, "pause", MPV_FORMAT_FLAG, &p);
}

void MpvItem::command(const QVariantList &params)
{
    if (!m_mpv)
        return;

    // QVariantList 转 mpv_node 数组;字符串缓冲区须存活到 mpv_command_node 返回之后。
    QList<QByteArray> strings;
    strings.reserve(params.size());
    for (const QVariant &v : params)
        strings.append(v.toString().toUtf8());

    QList<mpv_node> nodes;
    nodes.reserve(params.size());
    for (int i = 0; i < params.size(); ++i) {
        mpv_node n;
        n.format = MPV_FORMAT_STRING;
        n.u.string = const_cast<char *>(strings.at(i).constData());
        nodes.append(n);
    }

    mpv_node_list list;
    list.num = params.size();
    list.keys = nullptr;
    list.values = nodes.data();

    mpv_node root;
    root.format = MPV_FORMAT_NODE_ARRAY;
    root.u.list = &list;

    mpv_command_node(m_mpv, &root, nullptr);
}

void MpvItem::onMpvEvents()
{
    if (!m_mpv)
        return;
    for (;;) {
        mpv_event *event = mpv_wait_event(m_mpv, 0);
        if (event->event_id == MPV_EVENT_NONE)
            break;
        if (event->event_id == MPV_EVENT_PROPERTY_CHANGE)
            handlePropertyChange(event->reply_userdata,
                                 static_cast<mpv_event_property *>(event->data));
        else if (event->event_id == MPV_EVENT_FILE_LOADED)
            emit fileLoaded();
        else if (event->event_id == MPV_EVENT_END_FILE) {
            const auto *ef = static_cast<mpv_event_end_file *>(event->data);
            emit playbackEnded(ef && ef->reason == MPV_END_FILE_REASON_ERROR);
        }
    }
}

void MpvItem::handlePropertyChange(uint64_t observeId, mpv_event_property *prop)
{
    if (prop->format == MPV_FORMAT_NONE) // 属性暂不可用
        return;

    bool posChanged = false, durChanged = false, stChanged = false, volChanged = false;

    switch (observeId) {
    case 1: // time-pos
        if (prop->format == MPV_FORMAT_DOUBLE) {
            const double v = *static_cast<double *>(prop->data);
            if (v != m_position) {
                m_position = v;
                posChanged = true;
            }
        }
        break;
    case 2: // duration
        if (prop->format == MPV_FORMAT_DOUBLE) {
            const double v = *static_cast<double *>(prop->data);
            if (v != m_duration) {
                const bool wasZero = (m_duration == 0.0);
                m_duration = v;
                durChanged = true;
                if (wasZero && v > 0.0) {
                    emit playbackStarted();
                    qInfo() << "playback started, duration =" << v;
                }
            }
        }
        break;
    case 3: // pause
        if (prop->format == MPV_FORMAT_FLAG) {
            const bool v = *static_cast<int *>(prop->data) != 0;
            if (v != m_paused) {
                m_paused = v;
                stChanged = true;
            }
        }
        break;
    case 4: // core-idle
        if (prop->format == MPV_FORMAT_FLAG) {
            const bool v = *static_cast<int *>(prop->data) != 0;
            if (v != m_idle) {
                m_idle = v;
                stChanged = true;
            }
        }
        break;
    case 5: // volume
        if (prop->format == MPV_FORMAT_INT64) {
            const int v = static_cast<int>(*static_cast<int64_t *>(prop->data));
            if (v != m_volume) {
                m_volume = v;
                volChanged = true;
            }
        }
        break;
    }

    if (posChanged)
        emit positionChanged();
    if (durChanged)
        emit durationChanged();
    if (stChanged)
        emit stateChanged();
    if (volChanged)
        emit volumeChanged();
}
