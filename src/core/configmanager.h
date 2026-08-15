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
    QString configPath() const { return m_path; }

    // 从磁盘重读配置(丢弃内存未落盘改动;热重载内部也走这里)。
    Q_INVOKABLE void reload();
    // 恢复默认值并立即写回。
    Q_INVOKABLE void resetToDefaults();

signals:
    void monetEnabledChanged();
    void librarySortByChanged();
    void librarySortOrderChanged();

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
    QString m_path;
    QFileSystemWatcher *m_watcher = nullptr;
    QTimer *m_reloadTimer = nullptr;
    // 自己 commit 触发 fileChanged 时置位,避免自触发重载。
    bool m_suppressReload = false;
};
