#include <QDir>
#include <QGuiApplication>
#include <QLockFile>
#include <QNetworkProxy>
#include <QNetworkProxyFactory>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QSGRendererInterface>
#include <QQuickWindow>
#include <QUrl>

#include <clocale>

#include "core/accountmanager.h"
#include "core/apppaths.h"
#include "core/playbackhistory.h"
#include "core/recentsearches.h"
#include "core/applog.h"
#include "core/configmanager.h"
#include "core/constants.h"
#include "core/embyclient.h"
#include "core/screeninhibit.h"
#include "models/colorprovider.h"
#include "models/posterprovider.h"
#include "playback/mpvclient.h"
#include "playback/mpvvideoitem.h"

namespace {
// QML 模块版本(major, minor):QML 侧 import 不带版本,仅 C++ 注册使用;
// 集中定义便于修改(API 变更递增版本)与 issue 定位。
constexpr int kQmlModuleMajor = 1;
constexpr int kQmlModuleMinor = 0;

// 应用级代理工厂:未显式 setProxy 的 QNetworkAccessManager(如 QML Image
// 直接加载原始 URL 时 QQuickPixmap 的内部管理器,服务器自定义图标等)
// 统一走配置代理;显式设置代理的(EmbyClient/PosterProvider)不受影响。
class AppProxyFactory : public QNetworkProxyFactory
{
public:
    explicit AppProxyFactory(ConfigManager *config)
        : m_config(config)
    {
    }
    QList<QNetworkProxy> queryProxy(const QNetworkProxyQuery &) override
    {
        const QNetworkProxy p = m_config->proxyObject();
        return p.type() == QNetworkProxy::NoProxy
                   ? QList<QNetworkProxy>{QNetworkProxy::NoProxy}
                   : QList<QNetworkProxy>{p};
    }

private:
    ConfigManager *m_config;
};
} // namespace

// qmltyperegistrar 生成的模块注册函数(moeplayer_qmltyperegistrations.cpp),
// 注册 QML_ELEMENT/QML_SINGLETON/QML_NAMED_ELEMENT 标注的类型。
extern void qml_register_types_MoePlayer_Core();

int main(int argc, char *argv[])
{
    // 固定 OpenGL 场景图后端,须在 QGuiApplication 构造前设置。
    // Windows 例外:保持默认(D3D11)—— 强制桌面 GL 在部分 Windows 驱动上
    // 不稳,而 qsb 烘焙已含各 RHI 后端变体,D3D11 跑同一套着色器。
#ifndef Q_OS_WIN
    qputenv("QSG_RHI_BACKEND", "opengl");
#endif
    // Qt 6 GUI 应用默认抑制控制台日志,强制输出便于终端调试。
    qputenv("QT_FORCE_STDERR_LOGGING", "1");

    QGuiApplication app(argc, argv);
    // libmpv 硬性要求 LC_NUMERIC=C(client.h;Qt6 在 QCoreApplication 构造
    // 时按环境 setlocale(LC_ALL,""),须拨回,否则 mpv_create 拒绝初始化)。
    std::setlocale(LC_NUMERIC, "C");
    app.setApplicationName(MoePlayer::kAppName);
    // 版本号来自 CMake project(VERSION),经 MOEPLAYER_VERSION 编译期注入,
    // 全局 applicationVersion() 与 UA/认证头共用,无第二处副本。
    app.setApplicationVersion(QStringLiteral(MOEPLAYER_VERSION));
    // 桌面集成标识:desktop 文件/图标/Wayland app_id(反向域名)。
    app.setDesktopFileName(MoePlayer::kAppId);
    // 便携模式检测(免安装版,见 apppaths.h):exe 旁 portable_mode.txt
    // 存在时数据改存 exe 旁 data/。须在 AppLog::install()(日志目录)
    // 与下方所有单例(accounts.json/config.toml/缓存)构造前完成。
    AppPaths::init();
    // 文件日志:setApplicationName 后即可定位 AppConfigLocation,
    // 尽早安装让首个 qInfo(RHI backend)也落盘。
    AppLog::install();

    // 场景图固定 OpenGL 后端(内嵌播放的 libmpv GL render 依赖它;
    // QML/ShaderEffect 也走 OpenGL RHI)。Windows 默认 D3D11 —— 若配置选了
    // 内嵌后端,在 ConfigManager 就绪后再切 OpenGL(见下)。
#if !defined(Q_OS_WIN)
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
#endif
    const auto api = QQuickWindow::graphicsApi();
    qInfo().noquote() << "RHI backend:"
                      << (api == QSGRendererInterface::OpenGL ? QStringLiteral("opengl")
                           : api == QSGRendererInterface::Direct3D11 ? QStringLiteral("d3d11")
                           : api == QSGRendererInterface::Vulkan ? QStringLiteral("vulkan")
                                                              : QStringLiteral("other"));
    qInfo().noquote() << "QPA platform:" << QGuiApplication::platformName()
                      << "version:" << app.applicationVersion();

    // 单实例锁:重复启动直接退出。
    QLockFile lock(QDir::temp().filePath(MoePlayer::kAppName + QStringLiteral(".lock")));
    if (!lock.tryLock(100)) {
        qWarning("Another MoePlayer instance is already running.");
        return 1;
    }

    // 向 QML 暴露 C++ 类型与单例。
    // 无依赖/无共享实例需求的类型(MediaItemModel 等)由
    // qmltyperegistrar 经 QML_ELEMENT/QML_SINGLETON/QML_NAMED_ELEMENT 自动注册
    // 到 MoePlayer.Core。生成的注册函数 qml_register_types_MoePlayer_Core() 由
    // qmltyperegistrations.cpp 中的 QQmlModuleRegistration 静态注册,理论上引擎
    // import 模块时自动触发;但实测(Qt 6.11,qrc qmldir 与静态注册并存)静态注册
    // 未在组件类型解析前触发,故在此显式调用该注册函数,保证类型在
    // loadFromModule 前就绪。宏与手动 qmlRegister 不并存,无双注册。
    qml_register_types_MoePlayer_Core();
    // 以下单例因构造依赖或需与 C++ 侧共享同一实例(PosterProvider 复用
    // EmbyClient/AccountManager;ColorProvider 复用 PosterProvider),按官方
    // 推荐用 qmlRegisterSingletonInstance 注入现有实例,不声明 QML_SINGLETON,
    // 避免与自动注册构成双注册。
    // 用户配置:无依赖,但须随应用启动即初始化(生成/读取 TOML 配置并挂
    // 热重载监视),不能等 QML 首次引用(惰性)才落盘,故同样显式构造注入。
    ConfigManager configManager;
#ifdef Q_OS_WIN
    // Windows 内嵌:libmpv render API 只有 GL 一路。注意 Qt6 事实(windows-
    // graphics.html 原文):ANGLE 自 Qt6 起不再随附,OpenGL on Windows 恒为
    // WGL 桌面 GL(AA_UseOpenGLES 无效果)⇒ render_gl.h「Windows 硬解互操作
    // 须 ANGLE」在 Qt6 栈上不可满足,d3d11va 直连缺席,硬解走 copy-back
    // (mpv auto-safe 默认即此,功能无损);真退化边缘 = 烂驱动下 Qt 动态 GL
    // 落 opengl32sw(llvmpipe 整窗软渲染)。
    // 必须在首个窗口创建前切;配置读 ConfigManager(须在构造之后)。
    if (configManager.playerBackend() == QLatin1String("embedded"))
        QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
#endif
    EmbyClient embyClient;
    // 全局代理(配置为空 = 直连):先按初始配置应用,热重载(用户手改
    // config.toml)后经 proxyChanged 再应用,新请求即时生效。
    embyClient.setProxy(configManager.proxyObject());
    QObject::connect(&configManager, &ConfigManager::proxyChanged, &embyClient,
                     [&configManager, &embyClient]() { embyClient.setProxy(configManager.proxyObject()); });
    // 未显式设代理的 QNAM(QML Image 原始 URL 等)统一走配置代理。
    QNetworkProxyFactory::setApplicationProxyFactory(new AppProxyFactory(&configManager));
    // 播放历史本地存储:启动拉取(AccountManager::fetchPlaybackHistory)的
    // 结果落此,供 UI 直接消费并为跨服务器合并留结构;须在 AccountManager
    // 构造与 QML 引用前就绪。
    PlaybackHistory playbackHistory;
    qmlRegisterSingletonInstance("MoePlayer.Core", kQmlModuleMajor, kQmlModuleMinor,
                                 "PlaybackHistory", &playbackHistory);
    // 最近搜索词(缓存层持久化):无依赖,须在 QML 引用前注入。
    RecentSearches recentSearches;
    qmlRegisterSingletonInstance("MoePlayer.Core", kQmlModuleMajor, kQmlModuleMinor,
                                 "RecentSearches", &recentSearches);
    AccountManager accountManager(&embyClient, &playbackHistory, &configManager);
    // 多线路收口:请求/取流基址 = 账号当前线路(身份键 serverUrl 不变)。
    embyClient.setBaseUrlResolver([&accountManager](const QString &serverUrl, const QString &userId) {
        return accountManager.activeUrlFor(serverUrl, userId);
    });
    // 图片 id 前缀 = 账号 id(不可变身份)。
    embyClient.setAccountIdResolver([&accountManager](const QString &serverUrl, const QString &userId) {
        return accountManager.accountIdFor(serverUrl, userId);
    });
    qmlRegisterSingletonInstance("MoePlayer.Core", kQmlModuleMajor, kQmlModuleMinor, "ConfigManager", &configManager);
    qmlRegisterSingletonInstance("MoePlayer.Core", kQmlModuleMajor, kQmlModuleMinor, "EmbyClient", &embyClient);
    qmlRegisterSingletonInstance("MoePlayer.Core", kQmlModuleMajor, kQmlModuleMinor, "AccountManager", &accountManager);
    // 海报取色:复用 PosterProvider 加载(实例须在 addImageProvider 前创建,
    // 且与 PosterProvider 同生命周期,ColorProvider 后台任务经 QPointer 自管)。
    PosterProvider *posterProvider = new PosterProvider(&embyClient, &accountManager, &configManager);
    ColorProvider colorProvider(posterProvider);
    qmlRegisterSingletonInstance("MoePlayer.Core", kQmlModuleMajor, kQmlModuleMinor, "ColorProvider", &colorProvider);

    // 播放防待机:视频播放期间抑制系统睡眠/灭屏(多会话引用计数)。
    // 无依赖,但须在 QML 引用前注入成单例。
    ScreenInhibit screenInhibit;
    qmlRegisterSingletonInstance("MoePlayer.Core", kQmlModuleMajor, kQmlModuleMinor,
                                 "ScreenInhibit", &screenInhibit);
    // 播放客户端(双后端):外部 = spawn 系统 mpv(内建 OSC);内嵌 =
    // libmpv(GL render,PlayerWindow)。JSON IPC 语义两后端统一。须在
    // QML 引用前注入。
    MpvClient mpvClient(&embyClient, &configManager);
    qmlRegisterSingletonInstance("MoePlayer.Core", kQmlModuleMajor, kQmlModuleMinor,
                                 "MpvClient", &mpvClient);
    // 内嵌播放视频表面(libmpv GL render;无 libmpv 的构建为空壳)。
    qmlRegisterType<MpvVideoItem>("MoePlayer.Core", kQmlModuleMajor, kQmlModuleMinor,
                                  "MpvVideoItem");

    // 启动日志:当前网络代理(直连/HTTP),便于确认配置生效。
    const QNetworkProxy appProxy = configManager.proxyObject();
    if (appProxy.type() == QNetworkProxy::NoProxy)
        qInfo() << "network proxy: direct";
    else
        qInfo() << "network proxy: http" << appProxy.hostName() << appProxy.port();


    // 首页聚合与启动 token 校验均由 Home 页 onCompleted 触发(见 Home.qml),
    // 此处不重复调用。

    QQmlApplicationEngine engine;
    // QML 文件随 qt_add_qml_module 部署在 qrc:/qt/qml/MoePlayer/Core/(默认
    // 资源导入路径),loadFromModule 免硬编码资源路径。旧 addImportPath("qrc:/qml")
    // 随 qml.qrc 布局删除。
    engine.addImageProvider(QStringLiteral("emby"), posterProvider);

    QObject::connect(&app, &QGuiApplication::lastWindowClosed, &app,
                     &QCoreApplication::quit);

    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     []() {
                         qCritical() << "QML 组件创建失败,应用退出";
                         QCoreApplication::exit(-1);
                     }, Qt::QueuedConnection);

    engine.loadFromModule(QStringLiteral("MoePlayer.Core"), QStringLiteral("Main"));

    const int ret = app.exec();
    qInfo() << "MoePlayer 退出,事件循环返回值" << ret;
    mpvClient.shutdownAll();
    std::_Exit(ret);
}
