#pragma once

#include <QObject>
#include <QSettings>
#include <QSet>
#include <QVariantList>

#include "core/constants.h"

class EmbyClient;

//! 多账号与凭据持久化管理(QML 单例 "MoePlayer.Core AccountManager")。
//! 无"激活账号"概念:所有浏览请求按目标服务器显式携带凭据
//! (EmbyClient 无状态化),本类只负责账号存储/增删改与凭据查询。
//! 启动即聚合所有账号的媒体库(Home),跨服务器跳转无需切换会话。
class AccountManager : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList accounts READ accounts NOTIFY accountsChanged)
    // 首页聚合行:所有账号的媒体库按账号顺序排列,每行含
    // {accountId, serverUrl, serverName, viewName, posterId, items}。
    Q_PROPERTY(QVariantList homeRows READ homeRows NOTIFY homeRowsReady)
public:
    explicit AccountManager(EmbyClient *client, QObject *parent = nullptr);

    QVariantList accounts() const;
    QVariantList homeRows() const { return m_homeRows; }

    // 是否已保存任何账号。
    Q_INVOKABLE bool hasAccounts() const;

    // 新增账号:使用给定凭据登录(异步),成功后保存账号。
    // 返回 true 表示已发起登录,结果经 accountLoginFinished(ok, message) 通知;
    // rememberPassword 为真时混淆保存密码(供 token 失效后免输入)。
    Q_INVOKABLE bool addAccount(const QString &name, const QString &serverUrl,
                                const QString &userName, const QString &password,
                                bool rememberPassword);

    // 删除账号:同时清理 EmbyClient 中该服务器的模型。
    Q_INVOKABLE void removeAccount(const QString &id);

    // 修改账号元数据(名称/服务器/用户名),token 与密码保留;
    // 仅改存储,下次聚合按新值生效。
    Q_INVOKABLE void updateAccount(const QString &id, const QString &name,
                                   const QString &serverUrl, const QString &userName);

    // 首页聚合:遍历全部账号(顺序即账号列表顺序),每服拉公开信息/视图/最近条目,
    // 全部就绪后填充 homeRows 并发 homeRowsReady。perLibraryLimit 为每库条目上限。
    Q_INVOKABLE void fetchHomeRows(int perLibraryLimit);
    // 启动校验:对所有有 token 的账号发轻量认证请求(/System/Info),
    // 401 即 token 失效(标红 + 记住密码自动重登),网络错误不算失效。
    Q_INVOKABLE void validateTokens();
    // 供海报提供方按服务器取 token(聚合行的跨服务器海报用)。
    QString tokenForServer(const QString &serverUrl) const;
    // 账号排序:在账号列表中上移/下移,顺序即首页聚合顺序与列表展示顺序。
    Q_INVOKABLE void moveAccountUp(const QString &id);
    Q_INVOKABLE void moveAccountDown(const QString &id);
    // 账号拖动排序:把 id 移动到 toIndex(移除后插入,其余顺移)。
    Q_INVOKABLE void moveAccount(const QString &id, int toIndex);

    // 供 UI 读取某账号的明文密码(仅当 rememberPassword;混淆解码)。
    Q_INVOKABLE QString passwordFor(const QString &id) const;

    // 浏览请求凭据查询:返回 {token, userId}(QML 组装无状态请求用);
    // 服务器无账号或 token 为空时返回空 map。
    Q_INVOKABLE QVariantMap credsForServer(const QString &serverUrl) const;

    // 跨服务器海报 id 前缀编码(URL 安全):<encodeServerKey(serverUrl)>~<itemId>~<tag>。
    static QString encodeServerKey(const QString &serverUrl);
    static QString decodeServerKey(const QString &key);

signals:
    void accountsChanged();
    // 登录/切换结果:ok=false 时 message 为失败原因。
    void accountLoginFinished(bool ok, const QString &message);
    // 首页聚合行就绪(见 fetchHomeRows)。
    void homeRowsReady();

private:
    struct AccountInfo {
        QString id;
        QString name;
        QString serverUrl;
        QString userName;
        QString userId; // 登录时获取(Emby 4.9 无 /Users/Me)
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
    // 待保存的登录(正在走 EmbyClient.login 的账号)。
    QVariantMap m_pending;
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
    // 账号检测状态:确认 token 失效且重登失败的服务器(UI 标红)。
    QSet<QString> m_invalidServers;
    QSet<QString> m_loggingInServers; // 正在账密重登的服务器(失败回调忽略重复处理)
    // 首页聚合缓存:上次成功数据,启动先展示再后台刷新。
    void loadHomeCache();
    void saveHomeCache();
};
