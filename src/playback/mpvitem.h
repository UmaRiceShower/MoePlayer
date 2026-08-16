#pragma once

#include <QQuickFramebufferObject>
#include <QVariantList>

#include <QtQml/qqmlregistration.h>

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>

class MpvRenderer;

//! 以 QQuickFramebufferObject 嵌入 libmpv 的渲染控件(render API + OpenGL)。
//! 渲染发生在场景图渲染线程;mpv 事件经回调投递到 GUI 线程的 onMpvEvents() 处理。
class MpvItem : public QQuickFramebufferObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(MpvItem)
    Q_PROPERTY(double position READ position NOTIFY positionChanged)
    Q_PROPERTY(double duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(QString state READ state NOTIFY stateChanged) // "idle" | "paused" | "playing"
    Q_PROPERTY(int volume READ volume WRITE setVolume NOTIFY volumeChanged)
    // 播放流 HTTP 代理(ConfigManager.proxy;mpv/ffmpeg 仅支持 HTTP 代理,
    // https 目标走 CONNECT 隧道;空 = 直连)。
    Q_PROPERTY(QString httpProxy READ httpProxy WRITE setHttpProxy)
public:
    explicit MpvItem(QQuickItem *parent = nullptr);
    ~MpvItem() override;

    Renderer *createRenderer() const override;

    // 当前播放位置(秒)。
    double position() const { return m_position; }
    // 媒体总时长(秒),未加载时为 0。
    double duration() const { return m_duration; }
    // 播放状态:"idle"(无文件)/"paused"/"playing"。
    QString state() const;
    // 音量(0-100),写属性同时下发到 mpv。
    int volume() const { return m_volume; }
    void setVolume(int v);
    // 当前播放流 HTTP 代理串(空 = 直连)。
    QString httpProxy() const { return m_httpProxy; }
    // 设置播放流 HTTP 代理(空串/非 http(s) 忽略 = 直连)。
    void setHttpProxy(const QString &spec);

    // 加载并播放 url;headers 为流请求所需 "Name: Value" 头列表(可空)。
    Q_INVOKABLE void load(const QString &url, const QStringList &headers = {});
    // 跳到指定秒数。
    Q_INVOKABLE void seek(double seconds);
    // 暂停/恢复。
    Q_INVOKABLE void setPause(bool p);
    // 向 mpv 发送任意命令(参数为字符串数组,如 ["seek", "10", "absolute"])。
    Q_INVOKABLE void command(const QVariantList &params);

signals:
    void positionChanged();
    void durationChanged();
    void stateChanged();
    void volumeChanged();
    // 首次获得有效时长时发出,表示媒体已开始解码。
    void playbackStarted();
    // 文件加载完成事件。loadfile 是异步命令,外挂字幕必须等此事件后才能挂载。
    void fileLoaded();
    // 播放结束事件:error 为 true 表示出错退出,false 表示正常播完。
    void playbackEnded(bool error);

private slots:
    // GUI 线程排空 mpv 事件队列,更新属性并转发信号。
    void onMpvEvents();

private:
    // 处理属性变更事件,按观察序号更新对应缓存并发出信号。
    void handlePropertyChange(uint64_t observeId, mpv_event_property *prop);

    friend class MpvRenderer;

    mpv_handle *m_mpv = nullptr;
    mpv_render_context *m_mpvRC = nullptr; // 渲染线程首个帧时创建
    double m_position = 0.0;
    double m_duration = 0.0;
    bool m_paused = false;
    bool m_idle = true;
    int m_volume = 100;
    QString m_httpProxy;
};
