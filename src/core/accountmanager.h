#pragma once

#include <QObject>
#include <QQueue>
#include <QSettings>
#include <QSet>
#include <QTimer>
#include <QVariantList>

#include "core/constants.h"
#include "core/persistmap.h"
#include "homerowsmodel.h"

class EmbyClient;
class PlaybackHistory;

//! 多账号与凭据持久化管理(QML 单例 "MoePlayer.Core AccountManager")。
//! 无"激活账号"概念:所有浏览请求按目标服务器显式携带凭据
//! (EmbyClient 无状态化),本类只负责账号存储/增删改与凭据查询。
//! 启动即聚合所有账号的媒体库(Home),跨服务器跳转无需切换会话。
class AccountManager : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList accounts READ accounts NOTIFY accountsChanged)
    // 账号数(只读标量):绑定/高频路径用,避免每次 accounts() 重建整表。
    Q_PROPERTY(int accountCount READ accountCount NOTIFY accountsChanged)
    // 服务器文件夹(分类):纯视觉分组,不影响账号列表与首页聚合顺序。
    // 每项 {id, name, accountIds:[账号id按加入顺序]}。成员卡展开时跟在
    // 文件夹卡后,收起时隐藏。持久化于 QSettings(accounts/folders)。
    Q_PROPERTY(QVariantList folders READ folders NOTIFY foldersChanged)
    // 管理页视觉顺序(混合序列):顶层元素 = 文件夹块 + 未分组账号,
    // 每项 {type: "folder"|"account", id};成员账号跟随所属文件夹块
    // (顺序 = 该文件夹 accountIds 加入顺序),不在序列中。顺序即管理页
    // 展示顺序,持久化于 QSettings(accounts/layoutOrder);账号视觉顺序
    // (展平:各文件夹块成员 + 未分组账号)恒等于 accounts 顺序,首页
    // 聚合与视觉一致。
    Q_PROPERTY(QVariantList layoutOrder READ layoutOrder NOTIFY layoutOrderChanged)
    // 首页聚合行模型:所有账号的媒体库按账号顺序排列,每行含
    // {accountId, serverUrl, serverName, viewName, posterId, items, loading}。
    // 按行增量更新(见 HomeRowsModel::setRows),只触发变化行的 delegate 重估。
    Q_PROPERTY(HomeRowsModel* homeRows READ homeRowsModel NOTIFY homeRowsReady)
    // 服务器建议(首页 hero 轮播数据源):全部账号的建议按账号顺序展平,
    // 每条含行条目字段 + {serverUrl, accountId}(posterId 已带服务器前缀);
    // 逐账号到位即发 suggestionsUpdated,新数据覆盖旧数据(不等待全部)。
    Q_PROPERTY(QVariantList suggestions READ suggestions NOTIFY suggestionsUpdated)
public:
    // history 为播放历史本地存储(拉取结果写入其中,不持有所有权)。
    explicit AccountManager(EmbyClient *client, PlaybackHistory *history,
                            QObject *parent = nullptr);

    QVariantList accounts() const;
    int accountCount() const { return m_accounts.size(); }
    HomeRowsModel *homeRowsModel() const { return m_homeRowsModel; }
    QVariantList folders() const;
    QVariantList layoutOrder() const { return m_layoutOrder; }
    QVariantList suggestions() const;

    // 是否已保存任何账号。
    Q_INVOKABLE bool hasAccounts() const;

    // 新增账号:使用给定凭据登录(异步),成功后保存账号。
    // 返回 true 表示已发起登录,结果经 accountLoginFinished(ok, message) 通知;
    // 登录成功后混淆保存密码(供 token 失效后免输入自动重登)。
    Q_INVOKABLE bool addAccount(const QString &name, const QString &serverUrl,
                                const QString &userName, const QString &password);

    // 删除账号:同时清理 EmbyClient 中该服务器的模型。
    Q_INVOKABLE void removeAccount(const QString &id);

    // 修改账号元数据(名称/服务器/用户名),token 与密码保留;
    // 仅改存储,下次聚合按新值生效。
    Q_INVOKABLE void updateAccount(const QString &id, const QString &name,
                                   const QString &serverUrl, const QString &userName);

    // 首页聚合:遍历全部账号(顺序即账号列表顺序),每服拉公开信息/视图/最近条目,
    // 全部就绪后填充 homeRows 并发 homeRowsReady。perLibraryLimit 为每库条目上限。
    Q_INVOKABLE void fetchHomeRows(int perLibraryLimit);
    // 播放历史拉取:对全部账号拉最近播放列表(写入存储并立即落盘),随后
    // 在后台逐条补全最靠前的若干条的播放次数/上次播放时间(列表端点不返回
    // 这两个字段;并发与落盘防抖见 constants)。列表全部到位即发
    // playbackHistoryReady,不等明细 —— 明细到达经 PlaybackHistory::
    // historyChanged 增量通知。
    // 触发条件当前仅"应用启动"(Home 页 onCompleted 调一次,见该处注释)。
    Q_INVOKABLE void fetchPlaybackHistory();
    // 启动校验:对所有有 token 的账号发轻量认证请求(/System/Info),
    // 401 即 token 失效(标红 + 记住密码自动重登),网络错误不算失效。
    Q_INVOKABLE void validateTokens();
    // 提交新的管理页视觉顺序(跨类排序统一入口):规范化(过滤未知/
    // 重复、成员不占位、缺失补全)后按序重排文件夹与账号(首页聚合
    // 跟随视觉),持久化并发信号。
    Q_INVOKABLE void setLayoutOrder(const QVariantList &order);

    // 设置账号自定义图标(图片 URL;空串 = 恢复名称首字)。
    // 立即持久化并通知 UI,无需额外保存操作。
    Q_INVOKABLE void setAccountIcon(const QString &id, const QString &icon);

    // ---- 服务器文件夹(分类)----
    // 新建文件夹(name 空自动命名"文件夹 N";color 空自动随机挑预设色),
    // 返回新文件夹 id。
    Q_INVOKABLE QString addFolder(const QString &name, const QString &color = QString());
    // 删除文件夹:成员自动释放为未分组,账号本身不删。
    Q_INVOKABLE void removeFolder(const QString &id);
    Q_INVOKABLE void renameFolder(const QString &id, const QString &name);
    // 修改文件夹颜色(hex "#RRGGBB",空值忽略)。
    Q_INVOKABLE void setFolderColor(const QString &id, const QString &color);
    // 预设颜色列表(新建随机/修改选择 UI 共用)。
    Q_INVOKABLE QStringList presetFolderColors() const;
    // 账号所在文件夹 id(空串 = 未分组)。
    Q_INVOKABLE QString folderIdOfAccount(const QString &accountId) const;
    // 把账号加入文件夹(已在目标文件夹则忽略;已在其他文件夹则转移)。
    Q_INVOKABLE void addAccountToFolder(const QString &folderId, const QString &accountId);
    // 从所在文件夹移除账号(回到未分组);不在任何文件夹则忽略。
    Q_INVOKABLE void removeAccountFromFolder(const QString &accountId);

    // 浏览请求凭据查询:返回 {token, userId}(QML 组装无状态请求用);
    // 服务器无账号或 token 为空时返回空 map。
    Q_INVOKABLE QVariantMap credsForServer(const QString &serverUrl) const;
    // 按账号 id 取凭据(同服务器多账号时精确定位,不依赖 serverUrl 首账号)。
    Q_INVOKABLE QVariantMap credsForAccount(const QString &accountId) const;

    // 跨服务器海报 id 前缀编码(URL 安全):<encodeServerKey(serverUrl)>~<itemId>~<tag>。
    static QString encodeServerKey(const QString &serverUrl);
    static QString decodeServerKey(const QString &key);

signals:
    void accountsChanged();
    void foldersChanged();
    void layoutOrderChanged();
    // 登录/切换结果:ok=false 时 message 为失败原因。
    void accountLoginFinished(bool ok, const QString &message);
    // 首页聚合行就绪(见 fetchHomeRows)。
    void homeRowsReady();
    // 某个账号的服务器建议到位(见 fetchHomeRows)。
    void suggestionsUpdated();
    // 播放历史拉取批次结束(见 fetchPlaybackHistory);拉取中的进度经
    // PlaybackHistory::historyChanged 通知。
    void playbackHistoryReady();

private:
    struct AccountInfo {
        QString id;
        QString name;
        QString serverUrl;
        QString userName;
        QString userId; // 登录时获取(Emby 4.9 无 /Users/Me)
        QString token;
        QString password; // 混淆存储(始终保存,供 token 失效自动重登)
        QString icon; // 统一图标:本地缓存 file:// URL(MD5 命名;空 = 名称首字)。
        qint64 lastUsed = 0;
    };

    void load();
    void save();
    // 图标图片落盘本地缓存:文件名 = 图片内容 MD5(去重,同图同文件),
    // 返回 file:// URL(失败空)。
    static QString writeIconCache(const QByteArray &imageData);
    // 写入图标缓存并按 id 落位(下载/本地读取共用);缓存成功且账号在
    // 且内容不同才更新并通知。
    void applyAccountIcon(const QString &id, const QByteArray &imageData);
    // 简单混淆(XOR + base64):防随手翻看,不防专业取证。
    static QString obfuscate(const QString &plain);
    static QString deobfuscate(const QString &cipher);
    // 首页聚合:全部请求完成后按账号顺序组装 homeRows 并发 homeRowsReady。
    void maybeAssembleHomeRows();
    // 首页聚合串行化:结束本轮,飞行中排队的触发重跑一次。
    void finishHomeFetch();
    // 文件夹结构(见 folders 属性)。
    struct FolderInfo {
        QString id;
        QString name;
        QString color; // 预设色 hex("#RRGGBB"),卡片背景用
        QStringList accountIds; // 成员账号 id,按加入顺序
    };
    // 文件夹读写(独立 key,账号结构不动)。
    void loadFolders();
    void saveFolders();
    // 视觉顺序读写(accounts/layoutOrder,见 layoutOrder 属性)。
    void loadLayoutOrder();
    void persistLayoutOrder();
    // 展平视觉账号顺序:遍历 layoutOrder,folder 项 → 其成员(按
    // accountIds 加入顺序),account 项 → 该账号。与 accounts 顺序
    // 恒一致(首页聚合跟随视觉)。
    QStringList visualAccountOrder(const QVariantList &order) const;
    // 按 layoutOrder 的文件夹顺序重排 m_folders,返回是否变化。
    bool reorderFoldersToLayout(const QVariantList &order);
    // 按展平视觉账号顺序重排 m_accounts,返回是否变化(仅顺序,不动数据)。
    bool reorderAccountsToVisual(const QVariantList &order);
    // 从 layoutOrder 移除指定项(结构变化维护:账号进文件夹不占位)。
    void removeFromLayoutOrder(const QString &type, const QString &id);
    // 构造 {type, id} 项。
    static QVariantMap makeLayoutEntry(const QString &type, const QString &id);
    // 按 id 取文件夹,找不到返回 nullptr;const/非 const 重载给出只读/可写访问。
    const FolderInfo *folderById(const QString &id) const;
    FolderInfo *folderById(const QString &id);
    int folderIndexById(const QString &id) const;
    // 按账号 id 取账号(只读),找不到返回 nullptr。
    const AccountInfo *accountById(const QString &id) const;
    // 按账号 id 取索引,找不到返回 -1。
    int accountIndexById(const QString &id) const;
    // 为行/条目海报 id 加服务器前缀(跨服务器海报用)。
    static QString serverPosterId(const QString &serverUrl, const QString &posterId);

    EmbyClient *m_client;
    QSettings m_settings;
    // 程序文档持久化(配置键 JSON + 缓存文件 JSON),注入本实例的
    // QSettings 与 CacheLocation(见 persistmap-design.md)。
    PersistMap m_persist;
    QList<AccountInfo> m_accounts;
    QList<FolderInfo> m_folders;
    QVariantList m_layoutOrder; // 规范化后的视觉顺序 [{type, id}](见属性注释)
    // 待保存的登录(正在走 EmbyClient.login 的账号)。
    QVariantMap m_pending;
    // 首页聚合状态(见 fetchHomeRows)。
    QVariantList m_homeRows;
    // 首页聚合行模型(QML 渲染按行增量;m_homeRows 为快照,供缓存/语义比较)。
    HomeRowsModel *m_homeRowsModel = nullptr;
    // 首页聚合串行化:飞行中收到新触发(启动拉取/重登/账号变化)时排队,
    // 本轮完成后重跑一次。避免并发 fill 打断正在孵化的 ListView delegate
    // (Qt 报 "Object or context destroyed during incubation")。
    bool m_homeFetchActive = false;
    bool m_homeFetchQueued = false;
    int m_homeLimit = MoePlayer::kHomePerLibraryLimit;
    int m_homePending = 0; // 聚合请求未完成计数
    int m_homeGen = 0; // 聚合代次:重叠重拉时丢弃旧代次的回调
    QHash<QString, int> m_homeReqGen; // 账号 id -> 发起聚合的代次
    // 服务器建议:账号 id -> 建议列表(带代次过滤,见 m_homeSuggReqGen)。
    QHash<QString, QVariantList> m_homeSuggByAccount;
    QHash<QString, int> m_homeSuggReqGen; // 账号 id -> 发起建议请求的代次
    // 服务器版本缓存(/System/Info/Public 的 Version):首页建议按版本门控
    // (4.9+ 的 /Suggestions 支持 IncludeItemTypes;旧版返回目录条目,跳过)。
    QHash<QString, QString> m_serverVersion;
    // 等待版本回执的服务器:serverUrl -> 该服等待中的账号 id 列表
    // (版本到位后按版本决定补发建议或跳过)。
    QHash<QString, QStringList> m_suggWaitVersion;
    QHash<QString, QVariantList> m_homeViews; // 账号 id -> 该服视图列表
    QHash<QString, QVariantMap> m_homeRowByKey; // "<账号id>|<viewId>" -> 行(含 items)
    QVariantList m_homeAccountOrder; // 本轮聚合的账号顺序快照 [{id,serverUrl,name}]
    // 账号检测状态按**账号 id** 键控(同服务器可多账号,serverUrl 会串):
    // 确认 token 失效且重登失败的账号(authStatus="invalid")。
    QSet<QString> m_invalidAccountIds;
    // 网络不可达/服务器错误(非 401)的账号(authStatus="network"),定时重试。
    QSet<QString> m_networkAccountIds;
    QSet<QString> m_loggingInAccountIds; // 正在账密重登的账号(失败回调忽略重复处理)
    // 重登进行中:serverUrl -> 正在重登的账号 id(EmbyClient 回调仅携带
    // serverUrl,用它路由回账号)。同服多账号同时需重登时,同一时刻只发
    // 一个,其余进 m_reloginQueue 按序处理,保证 owner 不被覆盖。
    QHash<QString, QString> m_reloginOwner;
    QHash<QString, QQueue<QString>> m_reloginQueue; // serverUrl -> 等待重登的账号 id 队列
    // 服务器默认图标回填:serverUrl -> 触发拉取该图标的账号 id(同服多账号
    // 时图标为服务器默认,内容相同,仅决定归属账号)。
    QHash<QString, QString> m_serverIconOwner;
    QTimer m_netRetryTimer; // 网络问题账号定期重试
    // 播放历史本地存储(构造注入,不持有所有权)。
    PlaybackHistory *m_playbackHistory;
    // 播放历史拉取状态(见 fetchPlaybackHistory):调度标记、本轮参与的
    // scope(serverUrl|账号 id)、各 scope 未完成任务数(列表 1 项 + 入队的
    // 明细数)、明细待发队列与飞行中计数。
    bool m_historyScheduled = false;
    bool m_historyActive = false;
    QSet<QString> m_historyScopes;
    QHash<QString, int> m_historyOutstanding;
    QQueue<QPair<QString, QString>> m_historyDetailQueue; // scope + itemId
    int m_historyDetailInFlight = 0;
    // 后台明细合并后的落盘防抖(见 constants):逐条写文件过密,合并写一次。
    QTimer m_historyFlushTimer;
    // 账号认证状态(accounts() 暴露 authStatus):invalid/network/ok。
    QString authStatusOf(const QString &accountId) const;
    // 对某账号发起一次 token 校验(结果经 validateToken 回调处理)。
    void checkAccountToken(const QString &accountId);
    // token 校验结果分发:0=有效,1=401→账密重登,2=网络→标记+定时重试。
    void onTokenChecked(const QString &accountId, int result);
    // 尝试用账号密码重登(guard 防并发;失败标 invalid)。Emby 允许无密码
    // 账号,密码为空也照常发起登录。
    void reloginFor(const QString &accountId);
    // 定时重试网络问题的账号(先 token 再账密)。
    void retryNetworkAccounts();
    void ensureNetRetryTimer();
    // 首页聚合缓存:上次成功数据,启动先展示再后台刷新。返回缓存数据,
    // 由调用方与当前展示比较后决定是否重建(相同则跳过,避免无意义重建)。
    QVariantList loadHomeCache();
    void saveHomeCache();
    // 账号顺序变化(拖拽/上移下移/删除)时按新顺序本地重排聚合行,不重拉
    // 网络(避免撞上重登中的 token 失效触发连锁重登与首页反复重建)。
    void reorderHomeRows();

    // ---- 播放历史拉取(见 fetchPlaybackHistory)----
    // 延迟到首页聚合之后开拉;已调度则忽略重复调用。
    void startPlaybackHistoryFetch();
    // 某账号的列表到位(ok=false 为请求失败):成功则补海报服务器前缀后写入
    // 存储并立即落盘,再把最靠前的若干条入队交由后台补全;失败保留既有存储。
    void onHistoryListReceived(const QString &serverUrl, const QString &accountId,
                               const QVariantList &items, bool ok);
    // 按并发上限从队列派发后台明细请求(账号已删除/凭据失效直接跳过)。
    void drainHistoryDetails();
    // 该 scope 的列表任务结算(见 startPlaybackHistoryFetch 的预置票):归零即
    // 收尾该账号;不等待后台明细。
    void onHistoryTaskDone(const QString &scope);
    // 该账号拉取收尾:所有账号都收尾后发 playbackHistoryReady。
    void finishHistoryScope(const QString &scope);
    // 账号在拉取途中被删除:撤出本轮(票数与存储一并清理),避免批次卡住。
    void abandonHistoryScope(const QString &scope);
};
