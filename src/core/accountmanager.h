#pragma once

#include <QObject>
#include <QQueue>
#include <QSet>
#include <QTimer>
#include <QVariantList>

#include "core/apppaths.h"
#include "core/constants.h"
#include "core/persistmap.h"

class ConfigManager;
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
    // 文件夹卡后,收起时隐藏。持久化于 accounts.json(folders 段)。
    Q_PROPERTY(QVariantList folders READ folders NOTIFY foldersChanged)
    // 管理页视觉顺序(混合序列):顶层元素 = 文件夹块 + 未分组账号,
    // 每项 {type: "folder"|"account", id};成员账号跟随所属文件夹块
    // (顺序 = 该文件夹 accountIds 加入顺序),不在序列中。顺序即管理页
    // 展示顺序,持久化于 accounts.json(layoutOrder 段);账号视觉顺序
    // (展平:各文件夹块成员 + 未分组账号)恒等于 accounts 顺序,首页
    // 聚合与视觉一致。
    Q_PROPERTY(QVariantList layoutOrder READ layoutOrder NOTIFY layoutOrderChanged)
    // 首页聚合行模型:所有账号的媒体库按账号顺序排列,每行含
    // {accountId, serverUrl, serverName, viewName, posterId, items, loading}。
    // 按行增量更新(见 HomeRowsModel::setRows),只触发变化行的 delegate 重估。
    Q_PROPERTY(HomeRowsModel* homeRows READ homeRowsModel NOTIFY homeRowsReady)
    // 自定义库聚合行模型:按 customLibraries 规则把多服库合并为自定义行
    // (跨服去重:同账号同 id → Tmdb/Imdb/Tvdb → 标题+年份);mode=off 时为空。
    // 行形 {custom:true, viewName:桶名, items, ...};未匹配库的行按 mode 保留/丢弃。
    Q_PROPERTY(HomeRowsModel* customHomeRows READ customHomeRowsModel NOTIFY homeRowsReady)
    // 服务器建议(首页 hero 轮播数据源):全部账号的建议按账号顺序展平,
    // 每条含行条目字段 + {serverUrl, accountId}(posterId 已带服务器前缀);
    // 逐账号到位即发 suggestionsUpdated,新数据覆盖旧数据(不等待全部)。
    Q_PROPERTY(QVariantList suggestions READ suggestions NOTIFY suggestionsUpdated)
    // 隐藏服务器(服务器管理页 Ctrl+点击浮窗 / 文件夹浮窗的开关):隐藏后
    // 首页行、推荐、搜索目标、播放历史、管理页都不可见,且**不参与网络
    // 聚合与 token 校验**(隐藏 = 不用它,露出时再拉)。文件夹隐藏时其成员
    // 一并隐藏(继承,不写成员自身标志)。
    // showHidden 是"临时露出隐藏项"的运行时开关(Alt+S,不持久化):
    // 打开后所有页面照常显示隐藏项,便于集中管理。
    Q_PROPERTY(bool showHidden READ showHidden WRITE setShowHidden NOTIFY hiddenChanged)
public:
    // history 为播放历史本地存储(拉取结果写入其中,不持有所有权)。
    explicit AccountManager(EmbyClient *client, PlaybackHistory *history,
                            ConfigManager *config, QObject *parent = nullptr);

    QVariantList accounts() const;
    int accountCount() const { return m_accounts.size(); }
    HomeRowsModel *homeRowsModel() const { return m_homeRowsModel; }
    HomeRowsModel *customHomeRowsModel() const { return m_customHomeRowsModel; }
    QVariantList folders() const;
    QVariantList layoutOrder() const { return m_layoutOrder; }
    QVariantList suggestions() const;

    // 是否已保存任何账号。
    Q_INVOKABLE bool hasAccounts() const;
    // 自定义库各桶当前命中统计(编辑器反馈):[{name, libraries:[服名·库名…], itemCount}];
    // 按实际归属(被高优先级桶收编的不计)。空数组 = 模式 off 或无规则。
    Q_INVOKABLE QVariantList customBucketStats() const;

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
    // 立即拉取列表(fetchPlaybackHistory 是启动一次性调度,页面刷新用这个):
    // 已在拉取中则由 startPlaybackHistoryFetch 的在途保护跳过。
    Q_INVOKABLE void refreshPlaybackHistory();
    // 定点刷新单条(播放结束后延后拉该条明细:服务器在 Stopped 报告之后才写
    // 上次播放时间),结果经独立通道合并,不占批处理并发槽。
    Q_INVOKABLE void refreshHistoryItem(const QString &serverUrl, const QString &accountId,
                                        const QString &itemId);
    // 按需刷新某账号的播放历史(详情页进入时调):拉该账号的继续观看列表并
    // 回写本地,结果经 accountHistoryRefreshed 返回;凭据不全时不发请求,
    // 调用方走本地回退。
    Q_INVOKABLE void refreshAccountHistory(const QString &accountId);
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
    // beforeAccountId 非空 = 插到该成员之前(默认末尾)。
    Q_INVOKABLE void addAccountToFolder(const QString &folderId, const QString &accountId,
                                        const QString &beforeAccountId = QString());
    // 从所在文件夹移除账号(回到未分组);不在任何文件夹则忽略。
    Q_INVOKABLE void removeAccountFromFolder(const QString &accountId);
    // 文件夹内排序:把 accountId 移到 beforeAccountId 之前(空 = 末尾)。
    Q_INVOKABLE void moveAccountInFolder(const QString &folderId, const QString &accountId,
                             const QString &beforeAccountId);

    // 浏览请求凭据查询:返回 {token, userId}(QML 组装无状态请求用);
    // 服务器无账号或 token 为空时返回空 map。
    // 该账号自身标了隐藏(不含文件夹继承;浮窗开关反映此项)。
    Q_INVOKABLE bool accountHidden(const QString &accountId) const;
    // 该账号的可见性(自身或所属文件夹隐藏 ⇒ 不可见;showHidden 打开时恒可见)。
    Q_INVOKABLE bool accountVisible(const QString &accountId) const;
    Q_INVOKABLE void setAccountHidden(const QString &accountId, bool hidden);
    // 线路表整体替换(编辑浮窗保存路径);url 归一化(去尾斜杠)、按 url 去重。
    Q_INVOKABLE void setAccountLines(const QString &accountId, const QVariantList &lines);
    Q_INVOKABLE void setActiveLine(const QString &accountId, int index);
    // 工作地址:该账号当前线路(无线路/越界 = serverUrl)。userId 消歧同服
    // 多账号;空 userId 取该服首个账号。所有请求的基址收口(EmbyClient
    // resolver、海报、取流都走这)。
    QString activeUrlFor(const QString &serverUrl, const QString &userId = QString()) const;
    // 反解账号 id(serverUrl+userId → id;空 = 未匹配)。
    QString accountIdFor(const QString &serverUrl, const QString &userId) const;
    Q_INVOKABLE bool folderHidden(const QString &folderId) const;
    Q_INVOKABLE void setFolderHidden(const QString &folderId, bool hidden);
    bool showHidden() const { return m_showHidden; }
    void setShowHidden(bool show);

    Q_INVOKABLE QVariantMap credsForServer(const QString &serverUrl) const;
    // 按账号 id 取凭据(同服务器多账号时精确定位,不依赖 serverUrl 首账号)。
    Q_INVOKABLE QVariantMap credsForAccount(const QString &accountId) const;

    // 海报 id 前缀编码(账号 id,URL 安全):<encodeServerKey(accountId)>~<itemId>~<tag>。
    static QString encodeServerKey(const QString &accountId);
    static QString decodeServerKey(const QString &key);

signals:
    void accountsChanged();
    void foldersChanged();
    void layoutOrderChanged();
    // 任意隐藏状态变化(账号/文件夹/showHidden):QML 重算过滤的依赖。
    void hiddenChanged();
    // 登录/切换结果:ok=false 时 message 为失败原因。
    void accountLoginFinished(bool ok, const QString &message);
    // 首页聚合行就绪(见 fetchHomeRows)。
    void homeRowsReady();
    // 某个账号的服务器建议到位(见 fetchHomeRows)。
    void suggestionsUpdated();
    // 播放历史拉取批次结束(见 fetchPlaybackHistory);拉取中的进度经
    // PlaybackHistory::historyChanged 通知。
    void playbackHistoryReady();
    // 继续观看列表到位(见 refreshAccountHistory):items 字段与播放历史条目
    // 同构(含剧集归属),请求失败为空列表。
    void accountHistoryRefreshed(const QString &serverUrl, const QString &accountId,
                                 const QVariantList &items);
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
        bool hidden = false; // 隐藏(不从界面出现、不参与网络聚合,见 hiddenChanged)
        // 多线路(同一服务器的替代入口:直连/CDN/内网)。身份键恒为
        // serverUrl(登录地址),线路只是工作地址;请求经 activeUrlFor 收口。
        QVariantList lines; // [{name,url}]
        int activeLine = -1; // -1 = 主地址(登录地址);0..N-1 = 线路下标
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
    // 由原始行集(visibleHomeRows 结果)构建自定义聚合行并写入
    // m_customHomeRowsModel;配置/隐藏变化时也要重跑(不重拉网络)。
    // final=true 时才发 info 级汇总(聚合完成/配置变更等一次性事件);
    // 增量中途重排解 debug,不刷屏。
    void rebuildCustomHomeRows(bool final = true);
    // 首页聚合串行化:结束本轮,飞行中排队的触发重跑一次。
    void finishHomeFetch();
    // 文件夹结构(见 folders 属性)。
    struct FolderInfo {
        QString id;
        QString name;
        QString color; // 预设色 hex("#RRGGBB"),卡片背景用
        QStringList accountIds; // 成员账号 id,按加入顺序
        bool hidden = false; // 隐藏:成员账号继承(见 hiddenChanged)
    };
    // 文件夹读写(独立 key,账号结构不动)。
    // 视觉顺序读写(accounts/layoutOrder,见 layoutOrder 属性)。
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
    // 隐藏判定(不看 showHidden):该账号自身或其文件夹配了隐藏。
    bool accountHiddenStored(const AccountInfo &a) const;
    // 首页行的可见子集(隐藏账号的行不展示;m_homeRows 保留全量以便露出)。
    QVariantList visibleHomeRows() const;
    // 隐藏状态变化后的统一收尾:过滤行/推荐并通知。
    void applyHiddenChange();
    // 按账号 id 取索引,找不到返回 -1。
    int accountIndexById(const QString &id) const;
    // 为行/条目海报 id 加服务器前缀(跨服务器海报用)。
    static QString serverPosterId(const QString &accountId, const QString &posterId);
    // 播放历史条目入库前统一补海报前缀:历史条目来自分集/继续观看等端点,
    // posterId 一律不带前缀(见 EmbyClient::parseHomeItem 的契约),而
    // image://emby/ 需要前缀(backdropId 已自带,不处理)。
    QVariantList historyItemsWithPosterIds(const QVariantList &items,
const QString &accountId) const;

    EmbyClient *m_client;
    // 存储路径经 AppPaths 统一分配(便携模式重定向,详见 apppaths.h)。

    // 缓存文件 JSON 持久化(CacheLocation;账号域走 accounts.json,不经此类)。
    PersistMap m_persist;
    QList<AccountInfo> m_accounts;
    QList<FolderInfo> m_folders;
    QVariantList m_layoutOrder; // 规范化后的视觉顺序 [{type, id}](见属性注释)
    bool m_showHidden = false; // 临时露出隐藏项(Alt+S;不持久化)
    // 待保存的登录(正在走 EmbyClient.login 的账号)。
    QVariantMap m_pending;
    // 首页聚合状态(见 fetchHomeRows)。
    QVariantList m_homeRows;
    // 首页聚合行模型(QML 渲染按行增量;m_homeRows 为快照,供缓存/语义比较)。
    ConfigManager *m_config = nullptr;
    HomeRowsModel *m_homeRowsModel = nullptr;
    HomeRowsModel *m_customHomeRowsModel = nullptr;
    // 首页聚合串行化:飞行中收到新触发(启动拉取/重登/账号变化)时排队,
    // 本轮完成后重跑一次。避免并发 fill 打断正在孵化的 ListView delegate
    // (Qt 报 "Object or context destroyed during incubation")。
    bool m_homeFetchActive = false;
    bool m_homeFetchQueued = false;
    int m_homeLimit = MoePlayer::kHomePerLibraryLimit;
    int m_homePending = 0; // 聚合请求未完成计数
    int m_homeGen = 0; // 聚合代次:重叠重拉时丢弃旧代次的回调
    QHash<QString, int> m_homeReqGen; // 账号 id -> 发起聚合的代次
    // 系列最近内容入库时间(Latest 派生):账号 id → seriesId → 最新集 DateCreated。
    // 桶内混排排序键用;缺失回落条目 dateAdded(=DateCreated)。
    QHash<QString, QHash<QString, QDateTime>> m_seriesRecency;
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
    // scope(serverUrl|账号 id)、各 scope 未完成列表任务数(每 scope 恒 1 票,
    // 覆盖窗口页 + 过滤段逐页回补;明细不记票)、逐页回补的累积行、
    // 明细待发队列与飞行中计数。
    bool m_historyScheduled = false;
    bool m_historyActive = false;
    QSet<QString> m_historyScopes;
    QHash<QString, int> m_historyOutstanding;
    QHash<QString, QVariantList> m_historyAccum;  // scope → 本轮已回补的行(按页序)
    QHash<QString, int> m_historyPages;           // scope → 过滤段已回补页数
    QHash<QString, int> m_historyPhase;           // scope → 0=窗口页(未过滤) 1=过滤段
    QQueue<QPair<QString, QString>> m_historyDetailQueue; // scope + itemId
    int m_historyDetailInFlight = 0;
    // 定点刷新的在途键(scope|accountId|itemId):响应到达时据此走独立通道。
    QSet<QString> m_historyOneShot;
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
    void saveHomeCacheWithout(const QString &accountId);
    // 推荐(服务器建议)缓存:启动先展示上次推荐,后台各服回执逐账号覆盖替换。
    // 载入丢弃已删账号的切片;与当前内容一致不 emit(hero 无重建)。
    void loadHomeSuggestionCache();
    // 写回:已回执账号覆盖、未回执账号沿用旧缓存;内容未变不落盘。
    void saveHomeSuggestionCache();
    // 账号顺序变化(拖拽/上移下移/删除)时按新顺序本地重排聚合行,不重拉
    // 网络(避免撞上重登中的 token 失效触发连锁重登与首页反复重建)。
    void reorderHomeRows();

    // ---- 播放历史拉取(见 fetchPlaybackHistory)----
    // 延迟到首页聚合之后开拉;已调度则忽略重复调用。
    void startPlaybackHistoryFetch();
    // 某账号的列表到位(ok=false 为请求失败):成功则补海报服务器前缀后写入
    // 存储并立即落盘,再把最靠前的若干条入队交由后台补全;失败保留既有存储。
    void onHistoryListReceived(const QString &serverUrl, const QString &accountId,
                               int startIndex, const QVariantList &items, int total, bool ok);
    // 按并发上限从队列派发后台明细请求(账号已删除/凭据失效直接跳过)。
    void drainHistoryDetails();
    // 该 scope 的列表任务结算(见 startPlaybackHistoryFetch 的预置票):归零即
    // 收尾该账号;不等待后台明细。
    void onHistoryTaskDone(const QString &scope);
    // 该账号拉取收尾:所有账号都收尾后发 playbackHistoryReady。
    void finishHistoryScope(const QString &scope);
    // 账号在拉取途中被删除:撤出本轮(票数与存储一并清理),避免批次卡住。
    void abandonHistoryScope(const QString &scope);
    // 继续观看列表到位:回写本地播放历史并发 accountHistoryRefreshed。
    void onResumeReceived(const QString &serverUrl, const QString &accountId,
                          const QVariantList &items);
    // 全季分集解析结果到位:回写本地播放历史(选集栏展示仍走 EmbyClient 模型)。
    void onAllEpisodesParsed(const QString &serverUrl, const QString &accountId,
                             const QString &seriesId, const QVariantList &items);
};
