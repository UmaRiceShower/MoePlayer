#include "screeninhibit.h"

#include <QtDBus/QDBusConnection>
#include <QtDBus/QDBusMessage>
#include <QtDBus/QDBusUnixFileDescriptor>
#include <QGuiApplication>

int ScreenInhibit::s_count = 0;

ScreenInhibit::ScreenInhibit(QObject *parent)
    : QObject(parent)
{
}

ScreenInhibit::~ScreenInhibit()
{
    // 退出时兜底释放,避免抑制句柄残留。
    applyActive(false);
}

void ScreenInhibit::acquire()
{
    // 首个请求才真正抑制;后续仅是计数。
    if (++s_count == 1)
        applyActive(true);
}

void ScreenInhibit::release()
{
    if (s_count > 0) {
        --s_count;
        if (s_count == 0)
            applyActive(false);
    }
}

void ScreenInhibit::applyActive(bool on)
{
    if (on == m_active)
        return;
    m_active = on;
    const QString appName = QGuiApplication::applicationDisplayName();

    if (on) {
        // 主路径:systemd-logind,阻止 idle 自动挂起/灭屏(Wayland 与 X11 通用)。
        QDBusMessage m = QDBusMessage::createMethodCall(
            QStringLiteral("org.freedesktop.login1"),
            QStringLiteral("/org/freedesktop/login1"),
            QStringLiteral("org.freedesktop.login1.Manager"),
            QStringLiteral("Inhibit"));
        m << QStringLiteral("idle") << appName
          << QStringLiteral("视频播放中,防止自动待机") << QStringLiteral("block");
        QDBusMessage rep = QDBusConnection::systemBus().call(m, QDBus::Block, 2000);
        if (rep.type() == QDBusMessage::ReplyMessage && !rep.arguments().isEmpty()) {
            const QDBusUnixFileDescriptor fd =
                rep.arguments().first().value<QDBusUnixFileDescriptor>();
            if (fd.fileDescriptor() >= 0) {
                m_logindFd = fd;
                m_logindHeld = true;
            }
        }
        if (!m_logindHeld) {
            qWarning().noquote() << "ScreenInhibit: logind inhibit failed:"
                                 << rep.errorName() << rep.errorMessage();
        }

        // 兜底:ScreenSaver 抑制(compositor 锁屏/DPMS;找不到该服务属常见情况)。
        QDBusMessage s = QDBusMessage::createMethodCall(
            QStringLiteral("org.freedesktop.ScreenSaver"),
            QStringLiteral("/org/freedesktop/ScreenSaver"),
            QStringLiteral("org.freedesktop.ScreenSaver"),
            QStringLiteral("Inhibit"));
        s << appName << QStringLiteral("视频播放中,防止屏幕锁定") << quint32(0);
        QDBusMessage srep = QDBusConnection::sessionBus().call(s, QDBus::Block, 2000);
        if (srep.type() == QDBusMessage::ReplyMessage && !srep.arguments().isEmpty()) {
            m_ssCookie = srep.arguments().first().toUInt();
            m_ssHeld = true;
        }
        qInfo().noquote() << "ScreenInhibit: active logind=" << m_logindHeld
                          << "screensaver=" << m_ssHeld;
    } else {
        // 解除 logind:重置 fd 使其 close,系统自动解除该抑制。
        if (m_logindHeld) {
            m_logindFd = QDBusUnixFileDescriptor();
            m_logindHeld = false;
        }
        if (m_ssHeld) {
            QDBusMessage u = QDBusMessage::createMethodCall(
                QStringLiteral("org.freedesktop.ScreenSaver"),
                QStringLiteral("/org/freedesktop/ScreenSaver"),
                QStringLiteral("org.freedesktop.ScreenSaver"),
                QStringLiteral("UnInhibit"));
            u << m_ssCookie;
            QDBusConnection::sessionBus().call(u, QDBus::Block, 2000);
            m_ssCookie = 0;
            m_ssHeld = false;
        }
        qInfo() << "ScreenInhibit: inactive";
    }
}
