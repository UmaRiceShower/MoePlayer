#pragma once

#include <QObject>
#include <QSettings>
#include <QSet>
#include <QVariantList>

#include "core/constants.h"

class EmbyClient;

//! 多账号与会话持久化管理(QML 单例 "MoePlayer.Core AccountManager")。
//! 账号列表(服务器/用户名/token/可选密码)存 QSettings,密码做简单混淆;
//! 启动经 autoLogin 用最后使用的账号免登录进入,切换账号重配 EmbyClient 会话。
//! 纯函数层:不提供 UI,界面接入方监听信号驱动登录/账号管理界面。
class AccountManager : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList accounts READ accounts NOTIFY accountsChanged)
    // 当前激活账号 id(空表示未登录)。
    Q_PROPERTY(QString activeAccountId READ activeAccountId NOTIFY activeAccountChanged)
    // 当前激活账号的显示名(供 UI 展示,空表示未登录)。
    Q_PROPERTY(QString activeAccountName READ activeAccountName NOTIFY activeAccountChanged)
    // 首页聚合行:所有账号的媒体库按账号顺序排列,每行含
    // {accountId, serverUrl, serverName, viewName, posterId, items}。
    Q_PROPERTY(QVariantList homeRows READ homeRows NOTIFY homeRowsReady)
public:
    explicit AccountManager(EmbyClient *client, QObject *parent = nullptr);

    QVariantList accounts() const;
    QString activeAccountId() const { return m_activeId; }
    QString activeAccountName() const;
    QVariantList homeRows() const { return m_homeRows; }

    // 是否已保存任何账号。
    Q_INVOKABLE bool hasAccounts() const;

    // 新增账号:使用给定凭据登录(异步),成功后保存账号并激活。
    // 返回 true 表示已发起登录,结果经 accountLoginFinished(ok, message) 通知;
    // rememberPassword 为真时混淆保存密码(供 token 失效后免输入)。
    Q_INVOKABLE bool addAccount(const QString &name, const QString &serverUrl,
                                const QString &userName, const QString &password,
                                bool rememberPassword);

    // 切换到已保存账号(异步):重配 EmbyClient 会话并重新拉取视图,
    // 结果经 accountLoginFinished(ok, message) 通知。
    Q_INVOKABLE bool switchAccount(const QString &id);

    // 删除账号(当前激活账号被删除后自动清空会话)。
    Q_INVOKABLE void removeAccount(const QString &id);

    // 修改账号元数据(名称/服务器/用户名),token 与密码保留;
    // 仅改存储,切换或下次 autoLogin 时按新值生效。
    Q_INVOKABLE void updateAccount(const QString &id, const QString &name,
                                   const QString &serverUrl, const QString &userName);

    // 启动自动登录:取最后使用的账号,用保存的 token 直接配置会话。
    // 返回 true 表示有可用账号且已发起登录,结果经 autoLoginFinished(ok) 通知;
    // 返回 false 表示无账号或 token 为空(调用方应展示登录入口)。
    Q_INVOKABLE bool autoLogin();

    // 首页聚合:遍历全部账号(顺序即账号列表顺序),每服拉公开信息/视图/最近条目,
    // 全部就绪后填充 homeRows 并发 homeRowsReady。perLibraryLimit 为每库条目上限。
    Q_INVOKABLE void fetchHomeRows(int perLibraryLimit);
    // 供海报提供方按服务器取 token(聚合行的跨服务器海报用)。
    QString tokenForServer(const QString &serverUrl) const;
    // 账号排序:在账号列表中上移/下移,顺序即首页聚合顺序与列表展示顺序。
    Q_INVOKABLE void moveAccountUp(const QString &id);
    Q_INVOKABLE void moveAccountDown(const QString &id);

    // 供 UI 读取某账号的明文密码(仅当 rememberPassword;混淆解码)。
    Q_INVOKABLE QString passwordFor(const QString &id) const;

    // 跨服务器海报 id 前缀编码(URL 安全):<encodeServerKey(serverUrl)>~<itemId>~<tag>。
    static QString encodeServerKey(const QString &serverUrl);
    static QString decodeServerKey(const QString &key);

signals:
    void accountsChanged();
    void activeAccountChanged();
    // 登录/切换结果:ok=false 时 message 为失败原因。
    void accountLoginFinished(bool ok, const QString &message);
    // 启动自动登录结果(ok=false 表示 token 失效或网络失败,应回登录流程)。
    void autoLoginFinished(bool ok);
    // 首页聚合行就绪(见 fetchHomeRows)。
    void homeRowsReady();

private:
    struct AccountInfo {
        QString id;
        QString name;
        QString serverUrl;
        QString userName;
        QString userId; // 登录时获取,autoLogin 直接使用(Emby 4.9 无 /Users/Me)
        QString token;
        bool rememberPassword = false;
        QString password; // 混淆存储
        qint64 lastUsed = 0;
    };

    void load();
    void save();
    // 简单混淆(XOR + base64):防随手翻看,不防专业取证。
    static QString obfuscate(const QString &plain);
    static QString deobfuscate(const QString &cipher);
    // 把账号会话应用到 EmbyClient 并重新拉取视图。
    void applySession(const AccountInfo &acc);
    void setActive(const QString &id);
    QString findIdByName(const QString &name) const;
    // 首页聚合:全部请求完成后按账号顺序组装 homeRows 并发 homeRowsReady。
    void maybeAssembleHomeRows();
    // 服务器显示名(ServerName)持久化于 QSettings,启动时读入,拉取成功后刷新。
    void loadServerNames();
    void persistServerNames();
    // 按服务器地址取账号索引(聚合回调归位用),找不到返回 -1。
    int accountIndexByServer(const QString &serverUrl) const;
    // 按账号 id 取账号(只读),找不到返回 nullptr。
    const AccountInfo *accountById(const QString &id) const;
    // 为行/条目海报 id 加服务器前缀(跨服务器海报用)。
    static QString serverPosterId(const QString &serverUrl, const QString &posterId);

    EmbyClient *m_client;
    QSettings m_settings;
    QList<AccountInfo> m_accounts;
    QString m_activeId;
    // 待保存的登录(正在走 EmbyClient.login 的账号)。
    QVariantMap m_pending;
    // 自动登录校验进行中(401 时据此发 autoLoginFinished(false))。
    bool m_autoLoginInFlight = false;
    // 首页聚合状态(见 fetchHomeRows)。
    QVariantList m_homeRows;
    QHash<QString, QString> m_serverNames; // serverUrl -> ServerName(持久化缓存)
    int m_homeLimit = MoePlayer::kHomePerLibraryLimit;
    int m_homePending = 0; // 聚合请求未完成计数
    int m_homeGen = 0; // 聚合代次:重叠重拉时丢弃旧代次的回调
    QHash<int, int> m_homeReqGen; // 账号索引 -> 发起聚合的代次
    QHash<int, QVariantList> m_homeViews; // 账号索引 -> 该服视图列表
    QHash<QString, QVariantMap> m_homeRowByKey; // "<账号索引>|<viewId>" -> 行(含 items)
    QVariantList m_homeAccountOrder; // 本次聚合的账号顺序快照 [{index,id,serverUrl,name}]
    // 账号检测状态(见 autoLogin/聚合 401 处理)。
    QSet<QString> m_invalidServers; // 确认 token 失效且重登失败的服务器(UI 标红)
    QSet<QString> m_loggingInServers; // 正在账密重登的服务器(失败回调忽略重复处理)
    bool m_autoRetry = false; // 自动登录的 token 失效,正在用账密重登
    // 首页聚合缓存:上次成功数据,启动先展示再后台刷新。
    void loadHomeCache();
    void saveHomeCache();
};
