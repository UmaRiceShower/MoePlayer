#pragma once

#include <QtDBus/QDBusUnixFileDescriptor>
#include <QObject>

// 播放时的待机抑制(防睡眠):视频播放期间保持系统唤醒,暂停/结束恢复。
// Qt 6 桌面端没有跨平台 inhibit API(仅 Android 有 QAndroidWakeLock),故经
// 平台标准 DBus 抑制:主路径 org.freedesktop.login1 Inhibit("idle")(systemd
// 通用,阻止 idle 自动挂起/灭屏),兜底 org.freedesktop.ScreenSaver Inhibit
// (compositor 层锁屏/DPMS;Wayland 下 KDE/GNOME 多提供兼容服务)。
// 多窗口共享引用计数:任一播放窗口处于 playing 即抑制,全部释放才解除。
class ScreenInhibit : public QObject
{
    Q_OBJECT
public:
    explicit ScreenInhibit(QObject *parent = nullptr);
    ~ScreenInhibit() override;

    // 持有一个"播放中"计数(acquire);暂停/结束调用 release 释放一个。
    Q_INVOKABLE void acquire();
    Q_INVOKABLE void release();

private:
    void applyActive(bool on);

    static int s_count;
    bool m_active = false;
    // logind 抑制:持有 unix fd,上下文关闭(close)时系统自动解除。
    QDBusUnixFileDescriptor m_logindFd;
    bool m_logindHeld = false;
    // ScreenSaver 抑制:按 cookie UnInhibit 解除。
    bool m_ssHeld = false;
    quint32 m_ssCookie = 0;
};
