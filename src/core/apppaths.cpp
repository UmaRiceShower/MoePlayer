#include "apppaths.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QStandardPaths>

#include "constants.h"

namespace {
// 便携标记:空文件,存在即便携。不做配置化 —— 它本身就是"配置存在哪"
// 的开关,不能再由配置决定。
const QString kPortableMarker = QStringLiteral("portable_mode.txt");

bool g_portable = false;
bool g_initialized = false;
} // namespace

void AppPaths::init()
{
    if (g_initialized)
        return;
    g_initialized = true;
    const QString exeDir = QCoreApplication::applicationDirPath();
    g_portable = QFileInfo::exists(exeDir + QLatin1Char('/') + kPortableMarker);
    if (!g_portable)
        return;
    // 预建目录:便携版可能被解压到不可写位置(如 Program Files),数据将
    // 无法持久化 —— 告警并继续(应用仍可运行),不致命。
    const QString root = exeDir + QStringLiteral("/data");
    if (!QDir().mkpath(root + QStringLiteral("/config"))
        || !QDir().mkpath(root + QStringLiteral("/cache"))) {
        qWarning().noquote() << "AppPaths: 便携数据目录创建失败(位置不可写?),"
                                "配置与缓存将无法持久化:" << root;
    }
    qInfo().noquote() << "AppPaths: 便携模式,数据目录" << root;
}

bool AppPaths::portable()
{
    return g_portable;
}

QString AppPaths::configDir()
{
    if (g_portable)
        return QCoreApplication::applicationDirPath() + QStringLiteral("/data/config");
    return QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation);
}

QString AppPaths::cacheDir()
{
    if (g_portable)
        return QCoreApplication::applicationDirPath() + QStringLiteral("/data/cache");
    return QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
}

QString AppPaths::settingsFilePath()
{
    if (g_portable)
        return configDir() + QLatin1Char('/') + MoePlayer::kAppName
               + QStringLiteral(".ini");
    // 非便携:探测构造取得既有路径 —— 与四个持有者原先的平台分支构造参数
    // 完全同源,逐字节一致。探测只构造读取,不写文件(未 sync 不落盘)。
    // 缓存于首次调用(单线程初始化阶段,无并发)。
    static const QString path = [] {
#ifdef Q_OS_WIN
        QSettings probe{QSettings::IniFormat, QSettings::UserScope,
                        MoePlayer::kAppName, MoePlayer::kAppName};
#else
        QSettings probe{QSettings::NativeFormat, QSettings::UserScope,
                        MoePlayer::kAppName, MoePlayer::kAppName};
#endif
        return probe.fileName();
    }();
    return path;
}

QSettings::Format AppPaths::settingsFormat()
{
    if (g_portable)
        return QSettings::IniFormat;
#ifdef Q_OS_WIN
    return QSettings::IniFormat;
#else
    return QSettings::NativeFormat;
#endif
}
