#include <QDir>
#include <QGuiApplication>
#include <QLockFile>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QSGRendererInterface>
#include <QQuickWindow>
#include <QUrl>

#include <clocale>

#include "core/accountmanager.h"
#include "core/embyclient.h"
#include "core/settingsstore.h"
#include "models/posterprovider.h"
#include "playback/mpvitem.h"

int main(int argc, char *argv[])
{
    // 解析命令行:--url <地址> 指定启动即播放的媒体,可省略。
    QString initialUrl;
    for (int i = 1; i < argc; ++i) {
        const QString a = QString::fromLocal8Bit(argv[i]);
        if (a == QLatin1String("--url") && i + 1 < argc)
            initialUrl = QString::fromLocal8Bit(argv[++i]);
        else if (a.startsWith(QLatin1String("--url=")))
            initialUrl = a.mid(6);
        else if (a == QLatin1String("--help")) {
            qInfo("Usage: MoePlayer [--url <url-or-local-file>]");
            return 0;
        }
    }

    // 固定 OpenGL 场景图后端,须在 QGuiApplication 构造前设置。
    qputenv("QSG_RHI_BACKEND", "opengl");
    // Qt 6 GUI 应用默认抑制控制台日志,强制输出便于终端调试。
    qputenv("QT_FORCE_STDERR_LOGGING", "1");

    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("MoePlayer"));
    app.setOrganizationName(QStringLiteral("MoePlayer"));
    app.setApplicationVersion(QStringLiteral("0.1.0"));

    // QGuiApplication 会按环境设置 locale,而 libmpv 要求 LC_NUMERIC 为 C,须在 mpv_create 前恢复。
    std::setlocale(LC_NUMERIC, "C");

    // QQuickFramebufferObject 仅支持 OpenGL 后端,固定并校验。
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
    const auto api = QQuickWindow::graphicsApi();
    qInfo().noquote() << "RHI backend:"
                      << (api == QSGRendererInterface::OpenGL ? QStringLiteral("opengl")
                                                              : QStringLiteral("other"));
    if (api != QSGRendererInterface::OpenGL)
        qFatal("OpenGL scene graph backend unavailable");

    // 单实例锁:重复启动直接退出。
    QLockFile lock(QDir::temp().filePath(QStringLiteral("MoePlayer.lock")));
    if (!lock.tryLock(100)) {
        qWarning("Another MoePlayer instance is already running.");
        return 1;
    }

    // 向 QML 暴露 C++ 类型与单例。
    SettingsStore settingsStore;
    EmbyClient embyClient;
    AccountManager accountManager(&embyClient);
    qmlRegisterSingletonInstance("MoePlayer.Core", 1, 0, "SettingsStore", &settingsStore);
    qmlRegisterSingletonInstance("MoePlayer.Core", 1, 0, "EmbyClient", &embyClient);
    qmlRegisterSingletonInstance("MoePlayer.Core", 1, 0, "AccountManager", &accountManager);
    qmlRegisterType<MpvItem>("MoePlayer.Playback", 1, 0, "MpvItem");

    // 启动自动登录:用最后使用的账号 token 配置会话(异步拉取视图)。
    // 无账号或 token 为空时返回 false,QML 侧显示登录入口;token 失效时
    // 经 autoLoginFinished(false) 通知回登录流程。
    accountManager.autoLogin();

    QQmlApplicationEngine engine;
    engine.addImportPath(QStringLiteral("qrc:/qml"));
    engine.addImageProvider(QStringLiteral("emby"), new PosterProvider(&embyClient));
    engine.rootContext()->setContextProperty(QStringLiteral("startupUrl"), initialUrl);

    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     []() { QCoreApplication::exit(-1); }, Qt::QueuedConnection);

    engine.load(QUrl(QStringLiteral("qrc:/qml/Main.qml")));

    return app.exec();
}
