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
#include "core/configmanager.h"
#include "core/constants.h"
#include "core/embyclient.h"
#include "core/settingsstore.h"
#include "models/colorprovider.h"
#include "models/posterprovider.h"
#include "playback/mpvitem.h"

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
    qputenv("QSG_RHI_BACKEND", "opengl");
    // Qt 6 GUI 应用默认抑制控制台日志,强制输出便于终端调试。
    qputenv("QT_FORCE_STDERR_LOGGING", "1");

    QGuiApplication app(argc, argv);
    app.setApplicationName(MoePlayer::kAppName);
    app.setOrganizationName(MoePlayer::kAppName);
    // 版本号来自 CMake project(VERSION),经 MOEPLAYER_VERSION 编译期注入,
    // 全局 applicationVersion() 与 UA/认证头共用,无第二处副本。
    app.setApplicationVersion(QStringLiteral(MOEPLAYER_VERSION));

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
    QLockFile lock(QDir::temp().filePath(MoePlayer::kAppName + QStringLiteral(".lock")));
    if (!lock.tryLock(100)) {
        qWarning("Another MoePlayer instance is already running.");
        return 1;
    }

    // 向 QML 暴露 C++ 类型与单例。
    // 无依赖/无共享实例需求的类型(SettingsStore/MediaItemModel/MpvItem)由
    // qmltyperegistrar 经 QML_ELEMENT/QML_SINGLETON/QML_NAMED_ELEMENT 自动注册
    // 到 MoePlayer.Core。生成的注册函数 qml_register_types_MoePlayer_Core() 由
    // qmltyperegistrations.cpp 中的 QQmlModuleRegistration 静态注册,理论上引擎
    // import 模块时自动触发;但实测(Qt 6.11,qrc qmldir 与静态注册并存)静态注册
    // 未在组件类型解析前触发(PlayerWindow 解析 MpvItem 报 "is not a type"),
    // 故在此显式调用该注册函数,保证类型在 loadFromModule 前就绪。宏与手动
    // qmlRegister 不并存,无双注册。
    qml_register_types_MoePlayer_Core();
    // 以下单例因构造依赖或需与 C++ 侧共享同一实例(PosterProvider 复用
    // EmbyClient/AccountManager;ColorProvider 复用 PosterProvider),按官方
    // 推荐用 qmlRegisterSingletonInstance 注入现有实例,不声明 QML_SINGLETON,
    // 避免与自动注册构成双注册。
    // 用户配置:无依赖,但须随应用启动即初始化(生成/读取 TOML 配置并挂
    // 热重载监视),不能等 QML 首次引用(惰性)才落盘,故同样显式构造注入。
    ConfigManager configManager;
    EmbyClient embyClient;
    // 全局代理(配置为空 = 直连):先按初始配置应用,热重载(用户手改
    // config.toml)后经 proxyChanged 再应用,新请求即时生效。
    embyClient.setProxy(configManager.proxyObject());
    QObject::connect(&configManager, &ConfigManager::proxyChanged, &embyClient,
                     [&configManager, &embyClient]() { embyClient.setProxy(configManager.proxyObject()); });
    // 未显式设代理的 QNAM(QML Image 原始 URL 等)统一走配置代理。
    QNetworkProxyFactory::setApplicationProxyFactory(new AppProxyFactory(&configManager));
    AccountManager accountManager(&embyClient);
    qmlRegisterSingletonInstance("MoePlayer.Core", kQmlModuleMajor, kQmlModuleMinor, "ConfigManager", &configManager);
    qmlRegisterSingletonInstance("MoePlayer.Core", kQmlModuleMajor, kQmlModuleMinor, "EmbyClient", &embyClient);
    qmlRegisterSingletonInstance("MoePlayer.Core", kQmlModuleMajor, kQmlModuleMinor, "AccountManager", &accountManager);
    // 海报取色:复用 PosterProvider 加载(实例须在 addImageProvider 前创建,
    // 且与 PosterProvider 同生命周期,ColorProvider 后台任务经 QPointer 自管)。
    PosterProvider *posterProvider = new PosterProvider(&embyClient, &accountManager, &configManager);
    ColorProvider colorProvider(posterProvider);
    qmlRegisterSingletonInstance("MoePlayer.Core", kQmlModuleMajor, kQmlModuleMinor, "ColorProvider", &colorProvider);

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

    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     []() { QCoreApplication::exit(-1); }, Qt::QueuedConnection);

    engine.loadFromModule(QStringLiteral("MoePlayer.Core"), QStringLiteral("Main"));

    return app.exec();
}
