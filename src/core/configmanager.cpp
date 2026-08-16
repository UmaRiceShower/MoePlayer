#include "core/configmanager.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QSaveFile>
#include <QStandardPaths>
#include <QTimer>

// toml++ 单头(third_party/tomlplusplus,已加入 include 路径)。
#include <toml.hpp>

namespace {

// 配置文件相对 AppConfigLocation 的文件名。
constexpr auto kConfigFileName = "config.toml";

// 9 宫格位置枚举(海报/文字 grid 态共用)。
const QStringList kGrid9 = {
    QStringLiteral("top-left"), QStringLiteral("top-center"), QStringLiteral("top-right"),
    QStringLiteral("middle-left"), QStringLiteral("middle-center"), QStringLiteral("middle-right"),
    QStringLiteral("bottom-left"), QStringLiteral("bottom-center"), QStringLiteral("bottom-right"),
};
// 文字区位置枚举:followPoster + 9 宫格。
const QStringList kTextPos = {
    QStringLiteral("followPoster"),
    QStringLiteral("top-left"), QStringLiteral("top-center"), QStringLiteral("top-right"),
    QStringLiteral("middle-left"), QStringLiteral("middle-center"), QStringLiteral("middle-right"),
    QStringLiteral("bottom-left"), QStringLiteral("bottom-center"), QStringLiteral("bottom-right"),
};

// 写回模板:注释对用户手改友好(键/顺序/注释一次生成)。
QString renderToml(bool monetEnabled, const QString &sortBy, const QString &sortOrder,
                   bool detailSidebarLeft, const QString &detailPosterPos,
                   const QString &detailTextPos, const QString &detailButtonsPos,
                   int detailTextWidth, int detailTextHeight)
{
    return QStringLiteral(
               "# MoePlayer \u7528\u6237\u914d\u7f6e(TOML)\n"
               "# \u542f\u52a8\u65f6\u8bfb\u53d6;\u5916\u90e8\u4fee\u6539\u540e\u81ea\u52a8\u70ed\u91cd\u8f7d(\u7acb\u5373\u751f\u6548)\u3002\n"
               "# \u7f3a\u5931\u6216\u7c7b\u578b\u4e0d\u5408\u6cd5\u7684\u952e\u56de\u9000\u9ed8\u8ba4\u503c;\u5220\u9664\u672c\u6587\u4ef6\u5373\u6062\u590d\u51fa\u5382\u3002\n"
               "# \u654f\u611f\u6570\u636e(\u8d26\u53f7\u5bc6\u7801/\u51ed\u636e)\u4e0d\u5b58\u4e8e\u6b64,\u4ecd\u7531 QSettings \u7ba1\u7406\u3002\n"
               "\n"
               "[theme]\n"
               "monetEnabled = %1    # \u6d77\u62a5\u83ab\u5948\u52a8\u6001\u53d6\u8272(false \u56de\u9000\u9759\u6001\u4e3b\u9898\u8272)\n"
               "\n"
               "[library]\n"
               "sortBy = \"%2\"      # \u9ed8\u8ba4\u6392\u5e8f\u5b57\u6bb5(Emby SortBy \u503c)\n"
               "sortOrder = \"%3\"   # \u9ed8\u8ba4\u6392\u5e8f\u65b9\u5411(Ascending/Descending)\n"
               "\n"
               "[detail]\n"
               "sidebarLeft = %4   # \u8be6\u60c5\u9875\u9009\u96c6/\u5b63\u680f\u9760\u5de6(true)/\u9760\u53f3(false,\u9ed8\u8ba4)\n"
               "posterPos = \"%5\" # \u6d77\u62a5\u4f4d\u7f6e 9 \u5bab\u683c:top/middle/bottom \u00d7 left/center/right\n"
               "                  #   bottom-left(\u9ed8\u8ba4,\u5de6\u4e0b)/bottom-center/bottom-right/...\n"
               "textPos = \"%6\"   # \u6807\u9898+\u4ecb\u7ecd:followPoster(\u9ed8\u8ba4,\u8ddf\u968f\u6d77\u62a5)/9 \u5bab\u683c\n"
               "                  #   (top-left/top-center/top-right/middle-left/middle-center/...)\n"
               "buttonsPos = \"%7\"# \u64ad\u653e/\u6536\u85cf/\u5df2\u770b\u6309\u94ae\u7ec4:poster(\u6d77\u62a5,\u9ed8\u8ba4)/\n"
               "                  #   text(\u8ddf\u968f\u6807\u9898)/backdrop(\u80cc\u666f\u56fe\u5de6\u4e0b\u89d2,\u4f18\u5148)\n"
               "textWidth = %8     # \u6807\u9898+\u4ecb\u7ecd\u533a\u56fa\u5b9a\u5bbd\u5ea6(\u4e0d\u5360\u5269\u4f59\u5bbd\u5ea6,\u50cf\u7d20)\n"
               "textHeight = %9    # \u6807\u9898+\u4ecb\u7ecd\u533a\u56fa\u5b9a\u9ad8\u5ea6(\u4e0d\u968f\u5185\u5bb9\u81ea\u9002\u5e94,\u50cf\u7d20)\n")
        .arg(monetEnabled ? QStringLiteral("true") : QStringLiteral("false"))
        .arg(sortBy, sortOrder)
        .arg(detailSidebarLeft ? QStringLiteral("true") : QStringLiteral("false"))
        .arg(detailPosterPos)
        .arg(detailTextPos)
        .arg(detailButtonsPos)
        .arg(detailTextWidth)
        .arg(detailTextHeight);
}

} // namespace

ConfigManager::ConfigManager(QObject *parent)
    : QObject(parent)
{
    m_path = QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation) + QLatin1Char('/') + QString::fromLatin1(kConfigFileName);
    // AppConfigLocation 目录(Qt 不保证存在)须自建,QSaveFile 写回才可打开。
    QDir().mkpath(QFileInfo(m_path).absolutePath());

    // 首次启动:文件不存在则生成默认模板(便于用户直接编辑)。
    if (!QFile::exists(m_path))
        commit();

    loadFromFile();

    // 外部修改热重载:防抖 400ms(编辑器保存常分多次写),值变化才发 NOTIFY。
    m_watcher = new QFileSystemWatcher(this);
    m_watcher->addPath(m_path);
    connect(m_watcher, &QFileSystemWatcher::fileChanged, this, &ConfigManager::scheduleReload);
    m_reloadTimer = new QTimer(this);
    m_reloadTimer->setSingleShot(true);
    m_reloadTimer->setInterval(400);
    connect(m_reloadTimer, &QTimer::timeout, this, &ConfigManager::reload);
}

void ConfigManager::setMonetEnabled(bool v)
{
    if (v == m_monetEnabled)
        return;
    m_monetEnabled = v;
    emit monetEnabledChanged();
    commit();
}

void ConfigManager::setLibrarySortBy(const QString &v)
{
    if (v == m_librarySortBy)
        return;
    m_librarySortBy = v;
    emit librarySortByChanged();
    commit();
}

void ConfigManager::setLibrarySortOrder(const QString &v)
{
    if (v == m_librarySortOrder)
        return;
    m_librarySortOrder = v;
    emit librarySortOrderChanged();
    commit();
}

void ConfigManager::setDetailSidebarLeft(bool v)
{
    if (v == m_detailSidebarLeft)
        return;
    m_detailSidebarLeft = v;
    emit detailSidebarLeftChanged();
    commit();
}

void ConfigManager::setDetailPosterPos(const QString &v)
{
    // 仅接受 9 宫格枚举(非法值忽略,防手误写坏布局)。
    if (!kGrid9.contains(v))
        return;
    if (v == m_detailPosterPos)
        return;
    m_detailPosterPos = v;
    emit detailPosterPosChanged();
    commit();
}

void ConfigManager::setDetailTextPos(const QString &v)
{
    // followPoster + 9 宫格(非法值忽略,防手误写坏布局)。
    if (!kTextPos.contains(v))
        return;
    if (v == m_detailTextPos)
        return;
    m_detailTextPos = v;
    emit detailTextPosChanged();
    commit();
}

void ConfigManager::setDetailButtonsPos(const QString &v)
{
    // text/poster/backdrop 三态(非法值忽略)。
    if (v != QStringLiteral("text") && v != QStringLiteral("poster")
        && v != QStringLiteral("backdrop"))
        return;
    if (v == m_detailButtonsPos)
        return;
    m_detailButtonsPos = v;
    emit detailButtonsPosChanged();
    commit();
}

void ConfigManager::setDetailTextWidth(int v)
{
    if (v == m_detailTextWidth || v <= 0)
        return;
    m_detailTextWidth = v;
    emit detailTextWidthChanged();
    commit();
}

void ConfigManager::setDetailTextHeight(int v)
{
    if (v == m_detailTextHeight || v <= 0)
        return;
    m_detailTextHeight = v;
    emit detailTextHeightChanged();
    commit();
}

void ConfigManager::reload()
{
    // 文件被删除(用户 rm 重置):重挂监视(文件路径 watcher 已失效),保持当前值。
    if (!QFile::exists(m_path)) {
        m_watcher->addPath(m_path);
        return;
    }
    loadFromFile();
}

void ConfigManager::resetToDefaults()
{
    m_monetEnabled = true;
    m_librarySortBy = QStringLiteral("DateModified");
    m_librarySortOrder = QStringLiteral("Descending");
    m_detailSidebarLeft = false;
    m_detailPosterPos = QStringLiteral("bottom-left");
    m_detailTextPos = QStringLiteral("followPoster");
    m_detailButtonsPos = QStringLiteral("poster");
    m_detailTextWidth = 280;
    m_detailTextHeight = 140;
    emit monetEnabledChanged();
    emit librarySortByChanged();
    emit librarySortOrderChanged();
    emit detailSidebarLeftChanged();
    emit detailPosterPosChanged();
    emit detailTextPosChanged();
    emit detailButtonsPosChanged();
    emit detailTextWidthChanged();
    emit detailTextHeightChanged();
    commit();
}

void ConfigManager::loadFromFile()
{
    try {
        const toml::table cfg = toml::parse_file(m_path.toStdString());

        const auto theme = cfg["theme"];
        if (theme.is_table())
            m_monetEnabled = theme["monetEnabled"].value_or(m_monetEnabled);

        const auto library = cfg["library"];
        if (library.is_table()) {
            m_librarySortBy = QString::fromStdString(library["sortBy"].value_or(m_librarySortBy.toStdString()));
            m_librarySortOrder = QString::fromStdString(library["sortOrder"].value_or(m_librarySortOrder.toStdString()));
        }

        const auto detail = cfg["detail"];
        if (detail.is_table()) {
            m_detailSidebarLeft = detail["sidebarLeft"].value_or(m_detailSidebarLeft);
            const auto posterPos = detail["posterPos"].value_or(m_detailPosterPos.toStdString());
            m_detailPosterPos = QString::fromStdString(posterPos);
            if (!kGrid9.contains(m_detailPosterPos))
                m_detailPosterPos = QStringLiteral("bottom-left"); // 非法值回退默认
            m_detailTextPos = QString::fromStdString(detail["textPos"].value_or(m_detailTextPos.toStdString()));
            if (!kTextPos.contains(m_detailTextPos))
                m_detailTextPos = QStringLiteral("followPoster"); // 非法值回退默认
            m_detailButtonsPos = QString::fromStdString(detail["buttonsPos"].value_or(m_detailButtonsPos.toStdString()));
            if (m_detailButtonsPos != QStringLiteral("text") && m_detailButtonsPos != QStringLiteral("poster")
                && m_detailButtonsPos != QStringLiteral("backdrop"))
                m_detailButtonsPos = QStringLiteral("poster"); // 非法值回退默认
            m_detailTextWidth = detail["textWidth"].value_or(m_detailTextWidth);
            m_detailTextHeight = detail["textHeight"].value_or(m_detailTextHeight);
        }
        // 值全部来自文件:无条件发 NOTIFY(值相同的绑定更新是幂等的,
        // 避免手改后 QML 侧漏刷新)。
        emit monetEnabledChanged();
        emit librarySortByChanged();
        emit librarySortOrderChanged();
        emit detailSidebarLeftChanged();
        emit detailPosterPosChanged();
        emit detailTextPosChanged();
        emit detailButtonsPosChanged();
        emit detailTextWidthChanged();
        emit detailTextHeightChanged();
    } catch (const toml::parse_error &e) {
        qWarning().noquote() << "ConfigManager: TOML parse failed, keeping current values:"
                             << QString::fromUtf8(e.description().data(), qsizetype(e.description().size()));
    }
}

void ConfigManager::commit()
{
    // 自写回不触发热重载(否则 fileChanged → reload → 无意义重解析)。
    m_suppressReload = true;
    QSaveFile file(m_path);
    if (file.open(QIODevice::WriteOnly)) {
        file.write(renderToml(m_monetEnabled, m_librarySortBy, m_librarySortOrder,
                              m_detailSidebarLeft, m_detailPosterPos, m_detailTextPos,
                              m_detailButtonsPos, m_detailTextWidth, m_detailTextHeight)
                       .toUtf8());
        if (!file.commit())
            qWarning().noquote() << "ConfigManager: failed to commit" << m_path << file.errorString();
    } else {
        qWarning().noquote() << "ConfigManager: failed to open for write" << m_path << file.errorString();
    }
    m_suppressReload = false;
}

void ConfigManager::scheduleReload()
{
    if (m_suppressReload)
        return;
    // 编辑器保存/原子替换常更换文件 inode,QFileSystemWatcher 在首次
    // fileChanged 后即失效(仍监视旧 inode),须重新挂载,否则后续修改
    // 不再触发(实测:sed -i 一次后热重载即断)。
    m_watcher->removePath(m_path);
    m_watcher->addPath(m_path);
    m_reloadTimer->start();
}
