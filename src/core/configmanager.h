#pragma once

#include <QObject>
#include <QString>

class QFileSystemWatcher;
class QTimer;

//! TOML 用户配置(QML 单例 "MoePlayer.Core ConfigManager")。
//!
//! 文件:QStandardPaths::AppConfigLocation/config.toml(默认
//! ~/.config/MoePlayer/config.toml)。用户可直接编辑:启动时读取,
//! 外部修改经 QFileSystemWatcher 热重载(值变化才发 NOTIFY,QML 绑定
//! 自动更新,无需重启)。
//!
//! 后端 toml++ v3.4.0(third_party/tomlplusplus,MIT 单头);写回用
//! QSaveFile 原子替换(临时文件 + rename,崩溃不损坏旧配置)。
//!
//! 范围约定:敏感数据(账号密码/凭据)与服务器地址仍由 QSettings
//! (SettingsStore/AccountManager)管理,不落入明文 TOML;本类只管
//! 用户可自定义的展示/浏览设置。
class ConfigManager : public QObject
{
    Q_OBJECT
    // 海报莫奈动态取色开关(默认开,与接入前的行为一致)。
    Q_PROPERTY(bool monetEnabled READ monetEnabled WRITE setMonetEnabled NOTIFY monetEnabledChanged)
    // 媒体库默认排序字段(Emby SortBy 值;仅在无浏览状态恢复时生效)。
    Q_PROPERTY(QString librarySortBy READ librarySortBy WRITE setLibrarySortBy NOTIFY librarySortByChanged)
    // 媒体库默认排序方向(Emby SortOrder 值)。
    Q_PROPERTY(QString librarySortOrder READ librarySortOrder WRITE setLibrarySortOrder NOTIFY librarySortOrderChanged)
    // 详情页选集/季栏靠左(默认 false = 靠右,现状)。
    Q_PROPERTY(bool detailSidebarLeft READ detailSidebarLeft WRITE setDetailSidebarLeft NOTIFY detailSidebarLeftChanged)
    // 详情页海报靠左(默认 true = 靠左,现状;false = 海报靠右)。
    Q_PROPERTY(bool detailPosterLeft READ detailPosterLeft WRITE setDetailPosterLeft NOTIFY detailPosterLeftChanged)
    // 详情页"标题+介绍"区位置预设:top-left/top-right/bottom-left/
    // bottom-right(hero 四角;水平位置与海报同侧时自动内缩不重叠)。
    Q_PROPERTY(QString detailTextPos READ detailTextPos WRITE setDetailTextPos NOTIFY detailTextPosChanged)
    // 详情页播放/收藏/已看按钮组跟随目标:"poster"(海报内侧,现状)/
    // "text"(标题区外侧)。
    Q_PROPERTY(QString detailButtonsFollow READ detailButtonsFollow WRITE setDetailButtonsFollow NOTIFY detailButtonsFollowChanged)
    // 详情页标题+介绍区固定宽度/高度(不随内容自适应,不占剩余宽度)。
    Q_PROPERTY(int detailTextWidth READ detailTextWidth WRITE setDetailTextWidth NOTIFY detailTextWidthChanged)
    Q_PROPERTY(int detailTextHeight READ detailTextHeight WRITE setDetailTextHeight NOTIFY detailTextHeightChanged)
    // 配置文件绝对路径(只读,供 UI 展示/排障)。
    Q_PROPERTY(QString configPath READ configPath CONSTANT)
public:
    explicit ConfigManager(QObject *parent = nullptr);

    bool monetEnabled() const { return m_monetEnabled; }
    void setMonetEnabled(bool v);
    QString librarySortBy() const { return m_librarySortBy; }
    void setLibrarySortBy(const QString &v);
    QString librarySortOrder() const { return m_librarySortOrder; }
    void setLibrarySortOrder(const QString &v);
    bool detailSidebarLeft() const { return m_detailSidebarLeft; }
    void setDetailSidebarLeft(bool v);
    bool detailPosterLeft() const { return m_detailPosterLeft; }
    void setDetailPosterLeft(bool v);
    QString detailTextPos() const { return m_detailTextPos; }
    void setDetailTextPos(const QString &v);
    QString detailButtonsFollow() const { return m_detailButtonsFollow; }
    void setDetailButtonsFollow(const QString &v);
    int detailTextWidth() const { return m_detailTextWidth; }
    void setDetailTextWidth(int v);
    int detailTextHeight() const { return m_detailTextHeight; }
    void setDetailTextHeight(int v);
    QString configPath() const { return m_path; }

    // 从磁盘重读配置(丢弃内存未落盘改动;热重载内部也走这里)。
    Q_INVOKABLE void reload();
    // 恢复默认值并立即写回。
    Q_INVOKABLE void resetToDefaults();

signals:
    void monetEnabledChanged();
    void librarySortByChanged();
    void librarySortOrderChanged();
    void detailSidebarLeftChanged();
    void detailPosterLeftChanged();
    void detailTextPosChanged();
    void detailButtonsFollowChanged();
    void detailTextWidthChanged();
    void detailTextHeightChanged();

private:
    // 解析文件并应用(缺失/类型不合法回退默认值;解析失败仅告警不崩溃)。
    void loadFromFile();
    // 以当前内存值重写文件(带注释模板;原子写)。
    void commit();
    // 外部修改入队:防抖后重载(自写回经 m_suppressReload 跳过)。
    void scheduleReload();

    bool m_monetEnabled = true;
    QString m_librarySortBy = QStringLiteral("DateModified");
    QString m_librarySortOrder = QStringLiteral("Descending");
    bool m_detailSidebarLeft = false;
    bool m_detailPosterLeft = true;
    QString m_detailTextPos = QStringLiteral("top-left");
    QString m_detailButtonsFollow = QStringLiteral("poster");
    // 默认 280 = 原实现文字区下限(hero 有选季栏时宽 550,280+海报 200+
    // margin 才放得下;更大值需拉宽窗口)。
    int m_detailTextWidth = 280;
    // 默认 140:容纳 标题30+元数据14+简介2行40+间距 的内容高(~100)有余。
    int m_detailTextHeight = 140;
    QString m_path;
    QFileSystemWatcher *m_watcher = nullptr;
    QTimer *m_reloadTimer = nullptr;
    // 自己 commit 触发 fileChanged 时置位,避免自触发重载。
    bool m_suppressReload = false;
};
