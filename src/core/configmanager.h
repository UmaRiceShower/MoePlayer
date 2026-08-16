#pragma once

#include <QNetworkProxy>
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
    // 详情页海报位置:9 宫格 top/middle/bottom × left/center/right
    // (默认 bottom-left = 左下,原"靠左+沉底")。
    Q_PROPERTY(QString detailPosterPos READ detailPosterPos WRITE setDetailPosterPos NOTIFY detailPosterPosChanged)
    // 详情页"标题+介绍"区位置:followPoster(跟随海报,默认)/9 宫格
    // (相对 hero 内容区,优先级高于海报)。
    Q_PROPERTY(QString detailTextPos READ detailTextPos WRITE setDetailTextPos NOTIFY detailTextPosChanged)
    // 详情页播放/收藏/已看按钮组位置:text(跟随标题,上下与标题对齐)/
    // poster(跟随海报,底部与海报底对齐,默认)/backdrop(背景图左下角,
    // 优先于另两组)。
    Q_PROPERTY(QString detailButtonsPos READ detailButtonsPos WRITE setDetailButtonsPos NOTIFY detailButtonsPosChanged)
    // 详情页标题+介绍区固定宽度/高度(不随内容自适应,不占剩余宽度)。
    Q_PROPERTY(int detailTextWidth READ detailTextWidth WRITE setDetailTextWidth NOTIFY detailTextWidthChanged)
    Q_PROPERTY(int detailTextHeight READ detailTextHeight WRITE setDetailTextHeight NOTIFY detailTextHeightChanged)
    // 全局代理(空=直连):http://host:port 或 https://host:port(HTTP 代理,
    // https 目标走 CONNECT 隧道),可带 user:pass@ 认证。仅支持 HTTP(SOCKS
    // 不支持:mpv 播放流无 SOCKS;mihomo mixed-port 同端口说 HTTP 方言,
    // 填 http:// 即可)。非法值忽略回退直连。
    Q_PROPERTY(QString proxy READ proxy WRITE setProxy NOTIFY proxyChanged)
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
    QString detailPosterPos() const { return m_detailPosterPos; }
    void setDetailPosterPos(const QString &v);
    QString detailTextPos() const { return m_detailTextPos; }
    void setDetailTextPos(const QString &v);
    QString detailButtonsPos() const { return m_detailButtonsPos; }
    void setDetailButtonsPos(const QString &v);
    int detailTextWidth() const { return m_detailTextWidth; }
    void setDetailTextWidth(int v);
    int detailTextHeight() const { return m_detailTextHeight; }
    void setDetailTextHeight(int v);
    QString proxy() const { return m_proxy; }
    void setProxy(const QString &v);
    // 当前代理(按 proxy 串解析;空/非法 = NoProxy)。网络层每请求现取,
    // 热重载后新请求自动用新代理。
    QNetworkProxy proxyObject() const;
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
    void detailPosterPosChanged();
    void detailTextPosChanged();
    void detailButtonsPosChanged();
    void detailTextWidthChanged();
    void detailTextHeightChanged();
    void proxyChanged();

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
    QString m_detailPosterPos = QStringLiteral("bottom-left");
    QString m_detailTextPos = QStringLiteral("followPoster");
    QString m_detailButtonsPos = QStringLiteral("poster");
    // 默认 280 = 原实现文字区下限(hero 有选季栏时宽 550,280+海报 200+
    // margin 才放得下;更大值需拉宽窗口)。
    int m_detailTextWidth = 280;
    // 默认 140:容纳 标题30+元数据14+简介2行40+间距 的内容高(~100)有余。
    int m_detailTextHeight = 140;
    // 空 = 直连。
    QString m_proxy;
    QString m_path;
    QFileSystemWatcher *m_watcher = nullptr;
    QTimer *m_reloadTimer = nullptr;
    // 自己 commit 触发 fileChanged 时置位,避免自触发重载。
    bool m_suppressReload = false;
};
