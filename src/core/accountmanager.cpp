#include "accountmanager.h"

#include "core/configmanager.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>
#include <QUrl>
#include <QUuid>

#include <algorithm>

#include "core/apppaths.h"
#include "core/constants.h"
#include "core/embyclient.h"
#include "core/playbackhistory.h"
// 服务器版本是否支持首页建议过滤(/Suggestions 的 IncludeItemTypes,4.9+):
// 旧版本忽略该参数,建议内容为目录条目(Studio/Artist/Album),客户端跳过不发,
// hero 回退本地聚合。
static bool suggestionsSupported(const QString &version)
{
    const QStringList parts = version.split(QLatin1Char('.'));
    if (parts.size() < 2)
        return false;
    bool ok = false;
    const int major = parts.at(0).toInt(&ok);
    if (!ok)
        return false;
    const int minor = parts.at(1).toInt(&ok);
    if (!ok)
        return false;
    return major > 4 || (major == 4 && minor >= 9);
}


namespace {

// 混淆用固定 key(仅做简单保护,不构成加密)。
const QByteArray kObfuscationKey = QByteArrayLiteral("MoePlayer-account-v1");
// 文件夹预设色(hex):新建随机/修改选择 UI 共用,顺序即 UI 展示顺序。
const QStringList kPresetFolderColors = {
    QStringLiteral("#EF5350"), // 红
    QStringLiteral("#FF9800"), // 橙
    QStringLiteral("#FFC107"), // 琥珀
    QStringLiteral("#8BC34A"), // 浅绿
    QStringLiteral("#26A69A"), // 青
    QStringLiteral("#29B6F6"), // 浅蓝
    QStringLiteral("#5C6BC0"), // 靛
    QStringLiteral("#AB47BC"), // 紫
    QStringLiteral("#EC407A"), // 粉
    QStringLiteral("#78909C"), // 蓝灰
};
// 首页聚合缓存名(PersistMap saveCache/loadCache 的 name,拼 CacheLocation/<name>.json)。
const QString kHomeCacheName = QStringLiteral("home-rows");
// 服务器建议(首页 hero 推荐)缓存名:启动先展示上次推荐,后台按住账号覆盖替换。
const QString kHomeSuggCacheName = QStringLiteral("home-suggestions");

// 网络问题账号的定期重试间隔。
constexpr qint64 kNetRetryIntervalMs = 5LL * 60 * 1000;
// 播放结束后定点刷新该条明细的延时:Emby 在播放停止报告(Stopped)之后才写
// LastPlayedDate,立即 GET 可能拿到旧值(旧值非 0 ⇒ 合并不报错、症状照旧),
// 故延后拉一次。
constexpr int kHistoryItemRefreshDelayMs = 5000;
// 播放历史:列表最前 N 条每次都重取明细(见 onHistoryListReceived 的补全判据)。
// 代价是每次刷新 N 条轻量单条请求,换来"重看旧集也能刷新时间戳"。
constexpr int kHistoryTopAlwaysDetail = 15;
} // namespace

AccountManager::AccountManager(EmbyClient *client, PlaybackHistory *history,
                               ConfigManager *config, QObject *parent)
    : QObject(parent)
    , m_client(client)
    , m_playbackHistory(history)
    , m_config(config)
    , m_persist(AppPaths::cacheDir())
{
    m_homeRowsModel = new HomeRowsModel(this);
    m_customHomeRowsModel = new HomeRowsModel(this);
    // 自定义库规则/模式热改:由现有行集重聚合,不重拉网络。
    connect(m_config, &ConfigManager::customLibrariesChanged,
            this, [this] { rebuildCustomHomeRows(); });
    connect(m_config, &ConfigManager::customLibrariesModeChanged,
            this, [this] { rebuildCustomHomeRows(); });
    load(); // accounts.json 一次性读出(账号/文件夹/布局)

    // 网络问题账号定期重试:先 token 再账密,恢复后清除标记。
    m_netRetryTimer.setInterval(kNetRetryIntervalMs);
    connect(&m_netRetryTimer, &QTimer::timeout, this,
            &AccountManager::retryNetworkAccounts);

    // 播放历史:列表到位写入存储并入队明细补全;明细逐条回收并推进队列
    // (见 fetchPlaybackHistory)。
    connect(m_client, &EmbyClient::playbackHistoryReceived, this,
            &AccountManager::onHistoryListReceived);
    connect(m_client, &EmbyClient::itemUserDataReceived, this,
            [this](const QString &serverUrl, const QString &accountId, const QString &itemId,
                   int playCount, qint64 lastPlayedAt, double positionTicks, bool played) {
                // 并发槽归还与队列推进与 scope 无关:被删账号的在途响应也必须归还
                // 槽位并继续派发,否则槽位被它占满时其他账号排队的明细不再发出。
                const QString scope = serverUrl.trimmed() + QLatin1Char('|') + accountId;
                // 定点刷新(播放结束后拉刚播的那条)走独立通道:不占批处理的
                // 并发槽、也不受"本轮参与的 scope"门槛约束(那条约束是给批次
                // 用的,套在定点上会静默不写)。
                const bool oneShot =
                    m_historyOneShot.remove(scope + QLatin1Char('|') + itemId);
                if (!oneShot) {
                    if (m_historyDetailInFlight > 0)
                        --m_historyDetailInFlight;
                    drainHistoryDetails();
                    if (!m_historyScopes.contains(scope))
                        return; // 非本轮参与(账号已删除等):跳过写入与计数
                }
                if (positionTicks >= 0) {
                    m_playbackHistory->mergeItemUserData(serverUrl, accountId, itemId,
                                                         playCount, lastPlayedAt,
                                                         positionTicks, played);
                    m_historyFlushTimer.start(); // 防抖落盘(见 constants)
                }
                if (oneShot)
                    qInfo() << "AccountManager: 定点刷新合并(播放结束)" << itemId
                            << "次数" << playCount
                            << "位置" << qint64(positionTicks);
                if (!oneShot)
                    onHistoryTaskDone(scope);
            });
    // 后台明细的合并结果延迟落盘(逐条写文件过密,见 constants)。
    m_historyFlushTimer.setSingleShot(true);
    m_historyFlushTimer.setInterval(MoePlayer::kHistoryFlushDebounceMs);
    connect(&m_historyFlushTimer, &QTimer::timeout, this,
            [this] { m_playbackHistory->flush(); });
    // 详情页按需刷新:继续观看列表与整剧分集都回写本地播放历史。
    connect(m_client, &EmbyClient::resumeReceived, this, &AccountManager::onResumeReceived);
    connect(m_client, &EmbyClient::allEpisodesParsed, this, &AccountManager::onAllEpisodesParsed);

    // 登录成功:来自 addAccount(有 pending 且服务器匹配)则保存账号;
    // 否则(表单直连)由页面监听 loginSucceeded 自行浏览,不落账号。
    connect(m_client, &EmbyClient::loginSucceeded, this,
            [this](const QString &serverUrl, const QString &token, const QString &userId,
                   const QString &userName, const QString &accountId) {
                if (m_pending.isEmpty()
                    || accountId != m_pending.value(QStringLiteral("id")).toString())
                    return; // 非本类发起的登录(直连浏览/已清除),忽略
                AccountInfo acc;
                acc.id = m_pending.value(QStringLiteral("id")).toString();
                acc.name = m_pending.value(QStringLiteral("name")).toString();
                acc.serverUrl = serverUrl.trimmed();
                acc.userName = userName.isEmpty()
                                   ? m_pending.value(QStringLiteral("userName")).toString()
                                   : userName;
                acc.password = obfuscate(m_pending.value(QStringLiteral("password")).toString());
                acc.token = token;
                acc.userId = userId;
                acc.lastUsed = QDateTime::currentMSecsSinceEpoch();
                m_pending.clear();

                // 每次添加都是独立新账号(MoePlayer 固定新 id):不做同服+
                // 同名去重,全局一律按账号 id 路由(同服务器多账号互不串)。
                // 账号名后续由 serverPublicInfoReceived 按 id 回填,不入库去重。
                m_accounts.append(acc);
                m_layoutOrder.append(makeLayoutEntry(QLatin1String("account"), acc.id));
                save();
                emit accountsChanged();
                qInfo() << "AccountManager: 账号添加成功" << acc.id << "on" << acc.serverUrl;
                emit accountLoginFinished(true, QString());
                // 重跑首页聚合:Home 页只在实例化时拉一次,而新账号的库只能来自
                // 网络(删除走本地重排,新增没有等价物),不重跑就要等下次启动。
                // 在途时由 fetchHomeRows 排队合并,不并发打断孵化中的 delegate。
                if (m_homeLimit > 0)
                    fetchHomeRows(m_homeLimit);
                // 名称留空:登录成功后再拉 /System/Info/Public,用服务器端
                // ServerName 回填账号名(见 serverPublicInfoReceived)。
                if (acc.name.isEmpty())
                    m_client->fetchServerPublicInfo(acc.serverUrl);
                // 浏览器式解析服务器图标:仅添加时拉取(用户主动操作,图标
                // 可能已更新)。记录触发账号,回调按 id 路由(同服多账号时
                // 图标为服务器默认,内容相同,仅决定归属)。
                m_serverIconOwner.insert(acc.serverUrl, acc.id);
                m_client->fetchServerIcon(acc.serverUrl);
            });

    // 登录失败(带 pending 的 addAccount):通知失败,清除待保存状态。
    // 浏览类请求失败也走此信号,但 pending 为空时不产生副作用。
    connect(m_client, &EmbyClient::errorOccurred, this,
            [this](const QString &serverUrl, const QString &message) {
                if (m_pending.isEmpty())
                    return;
                const QString pendingServer =
                    m_pending.value(QStringLiteral("serverUrl")).toString().trimmed();
                if (pendingServer != serverUrl.trimmed())
                    return;
                m_pending.clear();
                // 401 = 凭据错误(Emby 返回 Unauthorized),给明确提示;
                // 其余保留原始错误(Qt errorString + HTTP 状态码)。
                const QString msg = message.contains(QLatin1String("401"))
                                        ? QStringLiteral("用户名或密码错误(HTTP 401)")
                                        : message;
                qWarning() << "AccountManager: 登录失败" << pendingServer << msg;
                emit accountLoginFinished(false, msg);
            });

    // 跨服务器请求失败:401 → 尝试账密重登(token 刷新),无密码/再失败标
    // invalid;其余(网络/服务器错误)不在此处标记,数据已按空处理。
    // 同服务器多账号时信号无 id,仅该服唯一账号才自动重登(避免错账号)。
    connect(m_client, &EmbyClient::serverRequestFailed, this,
            [this](const QString &serverUrl, const QString &message) {
                if (!message.contains(QLatin1String("401")))
                    return;
                // 找出该服唯一账号(多账号时无法定位,不自动重登)。
                QString uniqueId;
                int count = 0;
                for (const auto &a : m_accounts) {
                    if (a.serverUrl == serverUrl) {
                        ++count;
                        uniqueId = a.id;
                    }
                }
                if (count != 1 || m_loggingInAccountIds.contains(uniqueId))
                    return; // 多账号歧义 / 已在重登(由 serverLoginFinished 处理)
                if (m_invalidAccountIds.contains(uniqueId))
                    return; // 已确认失效,避免循环
                reloginFor(uniqueId);
            });
    // 账密重登结果:成功写回新 token(持久化)并解标失效;
    // 之后重拉各库数据(先展示缓存),恢复该服首页行。
    connect(m_client, &EmbyClient::serverLoginFinished, this,
            [this](const QString &serverUrl, bool ok, const QString &token,
                   const QString &userId, const QString &userName) {
                // 按重登发起时记录的 owner(账号 id)路由;loginFor 仅本类
                // reloginFor 调用,owner 必存在,不再回退 serverUrl。
                const QString accountId = m_reloginOwner.take(serverUrl);
                // 同服排队中的下一个账号接续重登(先递送本结果,清 owner)。
                m_loggingInAccountIds.remove(accountId);
                const int idx = accountIndexById(accountId);
                if (idx >= 0) {
                    AccountInfo &a = m_accounts[idx];
                    if (!ok) {
                        m_invalidAccountIds.insert(accountId);
                        m_networkAccountIds.remove(accountId);
                        emit accountsChanged();
                    } else {
                        qInfo().noquote() << "AccountManager: relogin ok on" << serverUrl;
                        a.token = token;
                        if (!userId.isEmpty())
                            a.userId = userId;
                        if (!userName.isEmpty())
                            a.userName = userName;
                        a.lastUsed = QDateTime::currentMSecsSinceEpoch();
                        m_invalidAccountIds.remove(accountId);
                        m_networkAccountIds.remove(accountId);
                        save();
                        emit accountsChanged();
                    }
                }
                if (m_networkAccountIds.isEmpty())
                    m_netRetryTimer.stop();
                // 接续该服排队的下一个重登(owner 已取空,可新发起)。
                QQueue<QString> &q = m_reloginQueue[serverUrl];
                if (!q.isEmpty())
                    reloginFor(q.dequeue());
                else
                    m_reloginQueue.remove(serverUrl);
                // token 校验/重登风暴结束(无账号仍在重登)后一次性重拉首页
                // 数据:避免每台重登完成就 fetch 一次——数据逐步恢复会让
                // 首页反复整体重建,Qt 引擎在 delegate 销毁期求值,打印
                // "QQmlVMEMetaObject: Internal error" 噪音。
                if (m_loggingInAccountIds.isEmpty())
                    fetchHomeRows(m_homeLimit);
            });

    // 服务器默认图标解析+下载结果(仅添加服务器时拉取):图片字节落盘
    // 本地缓存(文件名 = 内容 MD5,同图同文件去重),写账号 icon 字段。
    // 已有自定义图标(icon 非空)时不覆盖;失败(字节空)静默不动。
    connect(m_client, &EmbyClient::serverIconReceived, this,
            [this](const QString &serverUrl, const QString &iconUrl,
                   const QByteArray &imageData) {
                Q_UNUSED(iconUrl)
                // 按触发拉取时记录的账号 id 路由(不再用 serverUrl 取首账号)。
                const int idx = accountIndexById(m_serverIconOwner.take(serverUrl));
                if (idx < 0 || imageData.isEmpty())
                    return;
                AccountInfo &a = m_accounts[idx];
                if (!a.icon.isEmpty())
                    return; // 用户自定义图标优先,服务器默认不覆盖
                const QString localPath = writeIconCache(imageData);
                if (localPath.isEmpty() || a.icon == localPath)
                    return;
                a.icon = localPath;
                save();
                emit accountsChanged();
            });

    // 添加服务器未填名称:用拉到的 ServerName 回填该服名称仍为空的账号
    // (只回填未命名的,不覆盖用户已填/已改的名字);同服多账号只回填首个。
    connect(m_client, &EmbyClient::serverPublicInfoReceived, this,
            [this](const QString &serverUrl, const QString &name, const QString &version) {
                if (!version.isEmpty())
                    m_serverVersion.insert(serverUrl, version);
                if (!name.isEmpty()) {
                    for (auto &a : m_accounts) {
                        if (a.serverUrl == serverUrl && a.name.isEmpty()) {
                            a.name = name;
                            save();
                            emit accountsChanged();
                            // 首页聚合把账号名快照进 m_homeAccountOrder,并写进各行的
                            // serverName(行标题"服务器名 · 库名"前缀)。添加账号是
                            // "先入库(名字为空)再马上重跑聚合",回填若不同步这两处,
                            // 该账号的行会一直缺前缀,直到下次聚合。只对变化行 setRows:
                            // 模型内部只对变化行发信号,无整体重建噪音;缓存不在这里写
                            // (它要求整轮聚合完成才落,见 saveHomeCache 的调用点)。
                            const QString namedId = a.id;
                            for (auto &ord : m_homeAccountOrder) {
                                QVariantMap om = ord.toMap();
                                if (om.value(QStringLiteral("id")).toString() != namedId)
                                    continue;
                                om.insert(QStringLiteral("name"), name);
                                ord = om;
                            }
                            bool rowsTouched = false;
                            for (auto &row : m_homeRows) {
                                QVariantMap rm = row.toMap();
                                if (rm.value(QStringLiteral("accountId")).toString() != namedId
                                    || rm.value(QStringLiteral("serverName")).toString() == name)
                                    continue;
                                rm.insert(QStringLiteral("serverName"), name);
                                row = rm;
                                rowsTouched = true;
                            }
                            if (rowsTouched)
                                m_homeRowsModel->setRows(visibleHomeRows());
                                rebuildCustomHomeRows(false); // 账号名回填:逐账号一次,非终态
                            break;
                        }
                    }
                }
                // 版本回执后补发首页建议(见 fetchHomeRows 门控);<4.9 跳过。
                const auto waitIt = m_suggWaitVersion.find(serverUrl);
                if (waitIt == m_suggWaitVersion.end())
                    return;
                const QStringList ids = waitIt.value();
                m_suggWaitVersion.erase(waitIt);
                if (!suggestionsSupported(m_serverVersion.value(serverUrl)))
                    return;
                for (const QString &id : ids) {
                    const AccountInfo *a = accountById(id);
                    if (!a || m_homeSuggReqGen.value(id) != m_homeGen)
                        continue; // 账号已删或属过期代次,丢弃
                    m_client->fetchServerSuggestions(a->serverUrl, id, a->token, a->userId,
                                                     MoePlayer::kHomeSuggestLimit);
                }
            });
    connect(m_client, &EmbyClient::serverViewsReceived, this,
            [this](const QString &serverUrl, const QString &accountId, const QVariantList &views) {
                const AccountInfo *a = accountById(accountId);
                if (!a && m_homeReqGen.value(accountId) == m_homeGen) {
                    --m_homePending;
                    maybeAssembleHomeRows();
                    return;
                }
                if (!a || m_homeReqGen.value(accountId) != m_homeGen)
                    return; // 无对应账号或属过期代次,丢弃
                if (m_homeViews.contains(accountId))
                    return; // 本代已处理(旧代残留同数据回调),避免重复计数/发请求
                m_homeViews.insert(accountId, views);
                --m_homePending;
                for (const auto &v : views) {
                    ++m_homePending; // 每库一个条目请求
                    m_client->fetchServerItems(serverUrl, accountId, a->token, a->userId,
                                               v.toMap().value(QStringLiteral("id")).toString(),
                                               v.toMap().value(QStringLiteral("name")).toString(),
                                               m_homeLimit);
                }
                maybeAssembleHomeRows();
            });
    // 服务器建议到位:存账号建议列表并通知(hero 轮播用)。不参与
    // homePending 计数(建议失败不影响行聚合完成),代次过滤见 m_homeSuggReqGen。
    connect(m_client, &EmbyClient::serverSuggestionsReceived, this,
            [this](const QString &serverUrl, const QString &accountId, const QVariantList &items) {
                Q_UNUSED(serverUrl)
                if (accountIndexById(accountId) < 0 || m_homeSuggReqGen.value(accountId) != m_homeGen)
                    return; // 无对应账号或属过期代次,丢弃
                m_homeSuggByAccount.insert(accountId, items);
                saveHomeSuggestionCache(); // 与旧缓存合并后写(未回执的账号保留上次数据)
                emit suggestionsUpdated();
            });
    connect(m_client, &EmbyClient::serverItemsReceived, this,
            [this](const QString &serverUrl, const QString &accountId,
                   const QString &viewId, const QVariantList &items) {
                if (accountIndexById(accountId) < 0) {
                    if (m_homeReqGen.value(accountId) == m_homeGen) {
                        --m_homePending; // 删号在途票结算(同 views 回调)
                        maybeAssembleHomeRows();
                    }
                    return;
                }
                if (m_homeReqGen.value(accountId) != m_homeGen)
                    return; // 过期代次,丢弃
                const QString key = accountId + QLatin1Char('|') + viewId;
                if (m_homeRowByKey.contains(key))
                    return; // 本代已处理(旧代残留),避免重复递减计数
                QVariantMap row;
                row.insert(QStringLiteral("viewId"), viewId);
                row.insert(QStringLiteral("items"), items);
                m_homeRowByKey.insert(key, row);
                --m_homePending;
                maybeAssembleHomeRows();
            });
}

// 展平全部账号的服务器建议:按账号顺序拼接,每条补 serverUrl/accountId 与
// 海报前缀(解析时只带了 backdropId 前缀)。QML 端过滤无图条目后取前 N。
QVariantList AccountManager::suggestions() const
{
    QVariantList out;
    for (const auto &a : m_accounts) {
        if (!m_showHidden && accountHiddenStored(a))
            continue; // 隐藏账号的建议不进 hero(数据留在表里,露出即恢复)
        const auto it = m_homeSuggByAccount.constFind(a.id);
        if (it == m_homeSuggByAccount.constEnd())
            continue;
        for (const auto &v : it.value()) {
            QVariantMap m = v.toMap();
            m.insert(QStringLiteral("serverUrl"), a.serverUrl);
            m.insert(QStringLiteral("accountId"), a.id);
            const QString pid = m.value(QStringLiteral("posterId")).toString();
            if (!pid.isEmpty())
                m.insert(QStringLiteral("posterId"), serverPosterId(a.id, pid));
            out.append(m);
        }
    }
    return out;
}

QVariantList AccountManager::accounts() const
{
    QVariantList out;
    for (const auto &a : m_accounts) {
        QVariantMap m;
        m.insert(QStringLiteral("id"), a.id);
        m.insert(QStringLiteral("name"), a.name);
        m.insert(QStringLiteral("serverUrl"), a.serverUrl);
        m.insert(QStringLiteral("userName"), a.userName);
        m.insert(QStringLiteral("icon"), a.icon);
        m.insert(QStringLiteral("lastUsed"), a.lastUsed);
        m.insert(QStringLiteral("authStatus"), authStatusOf(a.id));
        // 自身标志(浮窗开关反映它)与"因所属文件夹隐藏"分开暴露:UI 需要
        // 区分"这台被单独隐藏"与"整个文件夹被隐藏",前者才好取消。
        m.insert(QStringLiteral("hidden"), a.hidden);
        const FolderInfo *folder = folderById(folderIdOfAccount(a.id));
        m.insert(QStringLiteral("hiddenByFolder"), folder && folder->hidden);
        m.insert(QStringLiteral("lines"), a.lines);
        m.insert(QStringLiteral("activeLine"), a.activeLine);
        out.append(m);
    }
    return out;
}

bool AccountManager::hasAccounts() const
{
    return !m_accounts.isEmpty();
}

// 隐藏判定(不含 showHidden):账号自身标志或所属文件夹标志。
bool AccountManager::accountHiddenStored(const AccountInfo &a) const
{
    if (a.hidden)
        return true;
    const FolderInfo *folder = folderById(folderIdOfAccount(a.id));
    return folder && folder->hidden;
}

bool AccountManager::accountHidden(const QString &accountId) const
{
    const AccountInfo *a = accountById(accountId);
    return a && a->hidden;
}

bool AccountManager::accountVisible(const QString &accountId) const
{
    const AccountInfo *a = accountById(accountId);
    return a && (m_showHidden || !accountHiddenStored(*a));
}

bool AccountManager::folderHidden(const QString &folderId) const
{
    const FolderInfo *f = folderById(folderId);
    return f && f->hidden;
}

void AccountManager::setAccountHidden(const QString &accountId, bool hidden)
{
    const int idx = accountIndexById(accountId);
    if (idx < 0 || m_accounts[idx].hidden == hidden)
        return;
    m_accounts[idx].hidden = hidden;
    save();
    applyHiddenChange();
    if (!hidden) {
        // 刚露出:隐藏期间跳过了聚合与校验,补一轮(令牌失效会被 401 路径接手重登)。
        checkAccountToken(accountId);
        fetchHomeRows(m_homeLimit);
    }
}

// 归一化:去空白 + 去尾斜杠(去重与比较的前提)。
static QString normLineUrl(QString u)
{
    u = u.trimmed();
    while (u.endsWith(QLatin1Char('/')))
        u.chop(1);
    return u;
}

void AccountManager::setAccountLines(const QString &accountId, const QVariantList &lines)
{
    const int idx = accountIndexById(accountId);
    if (idx < 0)
        return;
    QVariantList cleaned;
    QSet<QString> seen;
    for (const auto &v : lines) {
        const QVariantMap m = v.toMap();
        const QString url = normLineUrl(m.value(QStringLiteral("url")).toString());
        if (url.isEmpty() || seen.contains(url))
            continue;
        seen.insert(url);
        cleaned.append(QVariantMap{ { QStringLiteral("name"),
                                      m.value(QStringLiteral("name")).toString().trimmed() },
                                    { QStringLiteral("url"), url } });
    }
    AccountInfo &a = m_accounts[idx];
    a.lines = cleaned;
    if (a.activeLine >= a.lines.size())
        a.activeLine = -1;
    save();
    emit accountsChanged();
}

void AccountManager::setActiveLine(const QString &accountId, int index)
{
    const int idx = accountIndexById(accountId);
    if (idx < 0)
        return;
    AccountInfo &a = m_accounts[idx];
    // -1 = 主地址(登录地址);0..N-1 = 线路下标。线路表为空时恒回主地址。
    if (index < -1 || index >= a.lines.size() || index == a.activeLine)
        return;
    a.activeLine = index;
    save();
    emit accountsChanged();
}

QString AccountManager::accountIdFor(const QString &serverUrl, const QString &userId) const
{
    for (const auto &a : m_accounts) {
        if (normLineUrl(a.serverUrl) != normLineUrl(serverUrl))
            continue;
        if (!userId.isEmpty() && a.userId != userId)
            continue;
        return a.id;
    }
    return QString();
}

QString AccountManager::activeUrlFor(const QString &serverUrl, const QString &userId) const
{
    for (const auto &a : m_accounts) {
        if (normLineUrl(a.serverUrl) != normLineUrl(serverUrl))
            continue;
        if (!userId.isEmpty() && a.userId != userId)
            continue;
        if (a.lines.isEmpty() || a.activeLine < 0)
            return serverUrl;
        const int i = qBound(0, a.activeLine, a.lines.size() - 1);
        const QString url = normLineUrl(a.lines.at(i).toMap()
                                        .value(QStringLiteral("url")).toString());
        return url.isEmpty() ? serverUrl : url;
    }
    return serverUrl;
}

void AccountManager::setFolderHidden(const QString &folderId, bool hidden)
{
    FolderInfo *f = folderById(folderId);
    if (!f || f->hidden == hidden)
        return;
    f->hidden = hidden;
    save();
    emit foldersChanged();
    applyHiddenChange(); // accounts() 带 hiddenByFolder,成员卡的标识跟着变
    if (!hidden) {
        for (const QString &id : f->accountIds) // 成员一并补校验与聚合
            checkAccountToken(id);
        fetchHomeRows(m_homeLimit);
    }
}

void AccountManager::setShowHidden(bool show)
{
    if (m_showHidden == show)
        return;
    m_showHidden = show;
    applyHiddenChange();
    if (show) {
        for (const auto &a : m_accounts) // 露出前一律没校验过,补一轮
            if (!a.token.isEmpty() && accountHiddenStored(a))
                checkAccountToken(a.id);
        fetchHomeRows(m_homeLimit); // 同理补聚合(隐藏账号这轮参与,数据随即可用)
    }
}

// 首页行的可见子集:模型只喂可见账号的行。m_homeRows 保留上一轮装配结果
// (含刚被隐藏的账号,直到下一次聚合)——露出时先顶上旧行,随后由补拉替换。
QVariantList AccountManager::visibleHomeRows() const
{
    if (m_showHidden)
        return m_homeRows;
    QVariantList out;
    out.reserve(m_homeRows.size());
    for (const QVariant &v : m_homeRows) {
        const AccountInfo *a = accountById(v.toMap().value(QStringLiteral("accountId")).toString());
        if (!a)
            continue;
        if (!accountHiddenStored(*a))
            out.append(v);
    }
    return out;
}

// ---------- 自定义库聚合(多服库合并为自定义行) ----------
namespace {
struct CustomLibBucket {
    QString name;
    QList<QPair<QString, QRegularExpression>> rules; // field ∈ {name, collectionType}
};
} // namespace

// 规则来源:config customLibraries(JSON);空串 = 预置表。每条规则 =
// {field:name|collectionType, pattern:正则(大小写不敏感,部分匹配)}。
static QList<CustomLibBucket> customLibBuckets(ConfigManager *config)
{
    static const char *kPresets = R"([
{"name":"动画","rules":[{"field":"name","pattern":"动漫|动画|番剧|新番|国漫|剧场版|Anime"}]},
{"name":"剧集","rules":[{"field":"name","pattern":"电视剧|电视|剧集|美剧|韩剧|日剧|英剧|华语剧|追新|TV"}]},
{"name":"电影","rules":[{"field":"name","pattern":"电影|影片|院线|Movie"}]},
{"name":"演出","rules":[{"field":"name","pattern":"演唱会|音乐|Music|MV"}]},
{"name":"综艺","rules":[{"field":"name","pattern":"综艺"}]},
{"name":"儿童","rules":[{"field":"name","pattern":"儿童|少儿|Kids"}]},
{"name":"纪录片","rules":[{"field":"name","pattern":"纪录片|记录片|Documentary"}]}
])";
    QString raw = config->customLibraries();
    if (raw.trimmed().isEmpty())
        raw = QString::fromUtf8(kPresets);
    QList<CustomLibBucket> out;
    const QJsonArray arr = QJsonDocument::fromJson(raw.toUtf8()).array();
    for (const auto &bv : arr) {
        const QJsonObject bo = bv.toObject();
        CustomLibBucket b;
        b.name = bo.value(QLatin1String("name")).toString();
        if (b.name.isEmpty())
            continue;
        for (const auto &rv : bo.value(QLatin1String("rules")).toArray()) {
            const QJsonObject ro = rv.toObject();
            const QString field = ro.value(QLatin1String("field")).toString();
            const QString pattern = ro.value(QLatin1String("pattern")).toString();
            if (pattern.isEmpty())
                continue;
            const QRegularExpression re(pattern, QRegularExpression::CaseInsensitiveOption);
            if (!re.isValid()) {
                qWarning() << "AccountManager: 自定义库规则正则无效" << b.name << pattern;
                continue;
            }
            b.rules.append({ field, re });
        }
        if (!b.rules.isEmpty())
            out.append(b);
    }
    return out;
}

void AccountManager::rebuildCustomHomeRows(bool final)
{
    const QString mode = m_config->customLibrariesMode();
    if (mode == QLatin1String("off")) {
        m_customHomeRowsModel->setRows(QVariantList());
        return;
    }
    const QList<CustomLibBucket> buckets = customLibBuckets(m_config);
    const QVariantList orig = visibleHomeRows();

    // 桶工作区:按规则定义序建行;行内条目按 dateAdded 倒序收尾。
    struct BucketAcc {
        QVariantMap row;
        QList<QVariantMap> items;
        QSet<QString> idKeys;              // 同账号同条目(账号内/跨库重叠)
        QHash<QString, int> dedupToIndex;  // tmdb:/imdb:/tvdb:/ny: → items 下标
    };
    QList<BucketAcc> accs(buckets.size());
    QVariantList plainRows; // 未匹配库的原行(mode=on 时保留)
    for (int i = 0; i < buckets.size(); ++i) {
        QVariantMap row;
        row.insert(QStringLiteral("custom"), true);
        row.insert(QStringLiteral("viewId"), QStringLiteral("custom|") + buckets[i].name);
        row.insert(QStringLiteral("viewName"), buckets[i].name);
        row.insert(QStringLiteral("accountId"), QString());
        row.insert(QStringLiteral("serverUrl"), QString());
        row.insert(QStringLiteral("serverName"), QString());
        row.insert(QStringLiteral("loading"), false);
        accs[i].row = row;
    }

    for (const QVariant &rv : orig) {
        const QVariantMap row = rv.toMap();
        const QString viewName = row.value(QStringLiteral("viewName")).toString();
        const QString collType = row.value(QStringLiteral("collectionType")).toString();
        int bucketIdx = -1;
        for (int i = 0; i < buckets.size() && bucketIdx < 0; ++i)
            for (const auto &rule : buckets[i].rules) {
                const QString &subject = rule.first == QLatin1String("collectionType")
                                             ? collType : viewName;
                if (rule.second.match(subject).hasMatch()) {
                    bucketIdx = i;
                    break;
                }
            }
        if (bucketIdx < 0) {
            if (mode == QLatin1String("on"))
                plainRows.append(row); // 开启:未匹配库保留原行(排在自定义行之后)
            continue;
        }
        BucketAcc &acc = accs[bucketIdx];
        const QString rowAccount = row.value(QStringLiteral("accountId")).toString();
        for (const QVariant &iv : row.value(QStringLiteral("items")).toList()) {
            QVariantMap it = iv.toMap();
            const QString idKey = rowAccount + QLatin1Char('|')
                                  + it.value(QStringLiteral("id")).toString();
            if (acc.idKeys.contains(idKey))
                continue; // 同服重叠库(如"动漫"与"追新-动漫"同 id):无条件去重
            acc.idKeys.insert(idKey);
            // 跨服去重键:Tmdb → Imdb → Tvdb → 标题+年份;空键不参与。
            QStringList keys;
            const QString tmdb = it.value(QStringLiteral("tmdbId")).toString();
            const QString imdb = it.value(QStringLiteral("imdbId")).toString();
            const QString tvdb = it.value(QStringLiteral("tvdbId")).toString();
            if (!tmdb.isEmpty()) keys.append(QStringLiteral("tmdb:") + tmdb);
            if (!imdb.isEmpty()) keys.append(QStringLiteral("imdb:") + imdb);
            if (!tvdb.isEmpty()) keys.append(QStringLiteral("tvdb:") + tvdb);
            if (keys.isEmpty()) {
                const QString ny = QStringLiteral("ny:")
                                   + it.value(QStringLiteral("name")).toString().trimmed()
                                   + QLatin1Char('|')
                                   + QString::number(it.value(QStringLiteral("year")).toInt());
                keys.append(ny);
            }
            int dupAt = -1;
            for (const QString &k : keys)
                if (acc.dedupToIndex.contains(k)) {
                    dupAt = acc.dedupToIndex.value(k);
                    break;
                }
            if (dupAt >= 0) {
                // 合并:保留先到者(账号序),记多源计数(徽标/详情选源用)。
                QVariantMap cur = acc.items[dupAt];
                cur.insert(QStringLiteral("sourceCount"),
                           cur.value(QStringLiteral("sourceCount"), 1).toInt() + 1);
                acc.items[dupAt] = cur;
                continue;
            }
            it.insert(QStringLiteral("sourceCount"), 1);
            const int idx = acc.items.size();
            acc.items.append(it);
            for (const QString &k : keys)
                acc.dedupToIndex.insert(k, idx);
        }
    }

    // 桶收尾:条目按入库日期倒序混排;非空桶按定义序出列,空桶不占行。
    QVariantList customRows;
    for (BucketAcc &acc : accs) {
        if (acc.items.isEmpty())
            continue;
        std::sort(acc.items.begin(), acc.items.end(), [](const QVariantMap &a, const QVariantMap &b) {
            const QDateTime da = QDateTime::fromString(
                a.value(QStringLiteral("dateAdded")).toString(), Qt::ISODateWithMs);
            const QDateTime db = QDateTime::fromString(
                b.value(QStringLiteral("dateAdded")).toString(), Qt::ISODateWithMs);
            return da > db;
        });
        QVariantList items;
        items.reserve(acc.items.size());
        for (const QVariantMap &it : acc.items)
            items.append(it);
        acc.row.insert(QStringLiteral("items"), items);
        // 桶行海报:取首条目海报(媒体库卡条/空格回退用)。
        acc.row.insert(QStringLiteral("posterId"),
                       acc.items.first().value(QStringLiteral("posterId")).toString());
        customRows.append(acc.row);
        const int total = acc.row.value(QStringLiteral("items")).toList().size();
        int merged = 0;
        for (const QVariant &iv : acc.row.value(QStringLiteral("items")).toList())
            merged += iv.toMap().value(QStringLiteral("sourceCount"), 1).toInt();
        qDebug() << "AccountManager: 自定义桶" << acc.row.value(QStringLiteral("viewName")).toString()
                 << total << "条(合并前" << merged << ")";
    }
    // 汇总只在 final(整轮聚合完成/配置变更)发 info;中途增量重排走 debug。
    if (final)
        qInfo().noquote() << "AccountManager: 自定义库聚合" << customRows.size() << "桶 +"
                          << plainRows.size() << "未匹配原行";
    else
        qDebug().noquote() << "AccountManager: 自定义库聚合(增量)" << customRows.size()
                           << "桶 +" << plainRows.size() << "未匹配原行";
    m_customHomeRowsModel->setRows(customRows + plainRows);
}

// 隐藏状态变化后的统一收尾:行模型与推荐按可见性重过滤并通知。
// 不重拉网络(调用方按需触发),隐藏账号的数据原样留在内存与缓存里。
void AccountManager::applyHiddenChange()
{
    m_homeRowsModel->setRows(visibleHomeRows());
    rebuildCustomHomeRows();
    emit suggestionsUpdated();
    // 三个信号都要发:accountsChanged 让"遍历 accounts 求可见性"的绑定重算
    // (含 showHidden 切换),hiddenChanged 给显式监听者(QML 里的命令式重建)。
    emit accountsChanged();
    emit hiddenChanged();
}

QVariantMap AccountManager::credsForServer(const QString &serverUrl) const
{
    const QString url = normLineUrl(serverUrl); // 归一化(去空白+尾斜杠)
    // 同服务器多账号:优先未标失效的(首个有效 token);全失效时取首个。
    for (int pass = 0; pass < 2; ++pass) {
        for (const auto &a : m_accounts) {
            if (normLineUrl(a.serverUrl) != url || a.token.isEmpty())
                continue;
            if (pass == 0 && m_invalidAccountIds.contains(a.id))
                continue;
            QVariantMap m;
            m.insert(QStringLiteral("token"), a.token);
            m.insert(QStringLiteral("userId"), a.userId);
            return m;
        }
    }
    return QVariantMap();
}

QVariantMap AccountManager::credsForAccount(const QString &accountId) const
{
    const AccountInfo *a = accountById(accountId);
    if (!a || a->token.isEmpty())
        return QVariantMap();
    QVariantMap m;
    m.insert(QStringLiteral("token"), a->token);
    m.insert(QStringLiteral("userId"), a->userId);
    m.insert(QStringLiteral("serverUrl"), a->serverUrl);
    return m;
}

// 启动校验:对所有有 token 的账号发轻量认证请求(/System/Info)。
void AccountManager::validateTokens()
{
    int n = 0;
    for (const auto &a : m_accounts)
        if (!a.token.isEmpty() && (m_showHidden || !accountHiddenStored(a))) { // 隐藏账号不校验
            ++n;
            checkAccountToken(a.id);
        }
    qInfo() << "AccountManager: 启动 token 校验" << n << "个账号";
}

// 账号认证状态(invalid/network/ok;供 accounts() 暴露 authStatus)。
QString AccountManager::authStatusOf(const QString &accountId) const
{
    if (m_invalidAccountIds.contains(accountId))
        return QStringLiteral("invalid");
    if (m_networkAccountIds.contains(accountId))
        return QStringLiteral("network");
    return QStringLiteral("ok");
}

// 对某账号发起一次 token 校验;结果经回调自决标记与重试。
void AccountManager::checkAccountToken(const QString &accountId)
{
    const int idx = accountIndexById(accountId);
    if (idx < 0)
        return;
    const AccountInfo &a = m_accounts.at(idx);
    if (a.token.isEmpty())
        return;
    m_client->validateToken(a.serverUrl, a.token, a.userId,
                            [this, accountId](int result) { onTokenChecked(accountId, result); });
}

// token 校验结果:0=有效(清标记);1=401(账密重登);2=网络(标记+定时重试)。
void AccountManager::onTokenChecked(const QString &accountId, int result)
{
    if (accountIndexById(accountId) < 0)
        return; // 账号已删,过期回调丢弃
    if (result == 0) {
        qInfo() << "AccountManager: token 有效" << accountId;
        if (m_invalidAccountIds.remove(accountId) || m_networkAccountIds.remove(accountId))
            emit accountsChanged();
        if (m_networkAccountIds.isEmpty())
            m_netRetryTimer.stop();
        {
            const int idx = accountIndexById(accountId);
            if (idx >= 0) {
                AccountInfo &a = m_accounts[idx];
                if (!a.icon.isEmpty() && !QFileInfo::exists(QUrl(a.icon).toLocalFile())) {
                    qInfo() << "AccountManager: 图标文件失踪,重拉" << accountId;
                    a.icon.clear();
                    m_serverIconOwner.insert(a.serverUrl, a.id);
                    m_client->fetchServerIcon(a.serverUrl);
                }
            }
        }
        return;
    }
    if (result == 2) {
        // 网络不可达/服务器错误:标记 network,定时重试(先 token 再账密)。
        m_invalidAccountIds.remove(accountId);
        if (!m_networkAccountIds.contains(accountId)) {
            m_networkAccountIds.insert(accountId);
            emit accountsChanged();
        }
        qWarning() << "AccountManager: token 校验网络/服务器错误" << accountId;
        ensureNetRetryTimer();
        return;
    }
    // 401:token 失效 → 账密重登;失败标 invalid(见 serverLoginFinished)。
    qWarning() << "AccountManager: token 401 失效,发起账密重登" << accountId;
    m_networkAccountIds.remove(accountId);
    reloginFor(accountId);
}

// 用账号密码重登(guard 防并发;失败标 invalid,结果经 serverLoginFinished)。
// Emby 允许无密码账号:密码为空也照常发 AuthenticateByName(空密码合法)。
// 同服同时至多一个在途重登,其余排队(m_reloginQueue),保证 owner 无歧义。
void AccountManager::reloginFor(const QString &accountId)
{
    if (m_loggingInAccountIds.contains(accountId))
        return;
    const int idx = accountIndexById(accountId);
    if (idx < 0)
        return;
    const AccountInfo &a = m_accounts.at(idx);
    const QString srv = a.serverUrl;
    if (m_reloginOwner.contains(srv)) {
        // 该服已有重登在途:排队等前一个完成,避免 owner 被覆盖。
        if (!m_reloginQueue[srv].contains(accountId)) {
            qDebug() << "AccountManager: 重登在途,排队" << accountId;
            m_reloginQueue[srv].enqueue(accountId);
        }
        return;
    }
    qInfo() << "AccountManager: 自动重登发起" << srv;
    m_loggingInAccountIds.insert(accountId);
    m_reloginOwner.insert(srv, accountId); // 路由 serverLoginFinished 回账号
    m_client->loginFor(srv, a.userName, deobfuscate(a.password));
}

// 定时重试网络问题的账号:先 token,401 再账密;恢复清标记,仍网络保持。
void AccountManager::retryNetworkAccounts()
{
    if (m_networkAccountIds.isEmpty()) {
        m_netRetryTimer.stop();
        return;
    }
    const auto ids = m_networkAccountIds;
    qDebug() << "AccountManager: 重试网络问题账号" << ids.size() << "个";
    for (const QString &id : ids) {
        const AccountInfo *a = accountById(id);
        if (a && !m_showHidden && accountHiddenStored(*a))
            continue; // 隐藏账号不重试(露出后由该轮校验接手)
        checkAccountToken(id);
    }
}

void AccountManager::ensureNetRetryTimer()
{
    if (!m_networkAccountIds.isEmpty() && !m_netRetryTimer.isActive())
        m_netRetryTimer.start();
}

bool AccountManager::addAccount(const QString &name, const QString &serverUrl,
                                const QString &userName, const QString &password)
{
    if (serverUrl.trimmed().isEmpty() || userName.trimmed().isEmpty())
        return false;
    m_pending = QVariantMap{
        { QStringLiteral("id"), QUuid::createUuid().toString(QUuid::WithoutBraces) },
        { QStringLiteral("name"), name.trimmed() },
        { QStringLiteral("serverUrl"), serverUrl.trimmed() },
        { QStringLiteral("userName"), userName.trimmed() },
        { QStringLiteral("password"), password },
    };
    qInfo() << "AccountManager: 登录发起" << userName.trimmed() << "on" << serverUrl.trimmed();
    m_client->login(serverUrl.trimmed(), userName.trimmed(), password,
                    m_pending.value(QStringLiteral("id")).toString());
    return true;
}

// ---------- 首页聚合(所有账号的媒体库,顺序即账号列表顺序) ----------
// 先展示缓存,随后按视图/条目到达增量刷新:每服 views 到位立即出库壳,
// 每库 items 到位原地刷新该行(见 maybeAssembleHomeRows),不等待全部。
void AccountManager::fetchHomeRows(int perLibraryLimit)
{
    m_homeLimit = qBound(1, perLibraryLimit, MoePlayer::kHomePerLibraryLimit);
    // 上一轮仍在途(启动拉取与重登/账号变化可能重叠):合并,当前轮
    // 完成后再按最新状态重跑,避免并发 fill 打断孵化中的 delegate。
    if (m_homeFetchActive) {
        m_homeFetchQueued = true;
        return;
    }
    m_homeFetchActive = true;
    qInfo() << "AccountManager: 首页聚合启动" << m_accounts.size() << "个账号,每库" << m_homeLimit << "条";
    // 重叠重拉(排序/增删快速操作)时旧代次的回调可能仍在途,其归位索引已
    // 失效,须按代次丢弃;否则会污染本次聚合的视图与计数。
    ++m_homeGen;
    const int gen = m_homeGen;
    m_homeViews.clear();
    m_homeRowByKey.clear();
    m_homeAccountOrder.clear();
    m_homePending = 0;
    // 先展示缓存(上次成功数据),随后增量刷新逐行覆盖;无缓存则清空等待。
    // 缓存与当前展示相同则不 emit(避免无意义重建:重登/重复拉取常返回
    // 相同数据,Home 行整体重建会触发 Qt 引擎在 delegate 销毁期的内部
    // 警告 "QQmlVMEMetaObject: Internal error ... invalid context")。
    const QVariantList cached = loadHomeCache();
    m_homeRows = cached;
    m_homeRowsModel->setRows(visibleHomeRows()); // 缓存里可能有已隐藏账号的行
    rebuildCustomHomeRows(false); // 缓存先显,终态行在聚合完成时记
    // 推荐(服务器建议)缓存必须在 homeRowsReady **之前**载入:否则 hero 会先被
    // 本地聚合兜底数据填一次、随即又被推荐替换(启动时可见的一次"换一批")。
    loadHomeSuggestionCache();
    emit homeRowsReady();

    for (int i = 0; i < m_accounts.size(); ++i) {
        const AccountInfo &a = m_accounts.at(i);
        if (a.token.isEmpty())
            continue; // 无凭据的账号跳过,不参与聚合
        if (!m_showHidden && accountHiddenStored(a))
            continue; // 隐藏账号不拉取;露出模式下照常拉(Alt+S 后数据随即可用)
        QVariantMap order;
        order.insert(QStringLiteral("id"), a.id);
        order.insert(QStringLiteral("serverUrl"), a.serverUrl);
        order.insert(QStringLiteral("name"), a.name);
        m_homeAccountOrder.append(order);
        m_homeReqGen.insert(a.id, gen);
        // 服务器建议(hero 轮播):按版本门控——4.9+ 直接发;版本未知
        // 先探测(/System/Info/Public 轻量公开端点),回执后按版本补发;
        // <4.9 跳过(旧版建议为目录条目,无可用内容)。
        m_homeSuggReqGen.insert(a.id, gen);
        const QString ver = m_serverVersion.value(a.serverUrl);
        if (ver.isEmpty()) {
            auto &wait = m_suggWaitVersion[a.serverUrl];
            if (!wait.contains(a.id))
                wait.append(a.id);
            if (wait.size() == 1) // 同服首账号触发探测,其余共享回执
                m_client->fetchServerPublicInfo(a.serverUrl);
        } else if (suggestionsSupported(ver)) {
            m_client->fetchServerSuggestions(a.serverUrl, a.id, a.token, a.userId,
                                             MoePlayer::kHomeSuggestLimit);
        }
        ++m_homePending; // 该服视图请求
        m_client->fetchServerViews(a.serverUrl, a.id, a.token, a.userId);
    }
    if (m_homePending == 0)
        finishHomeFetch();
}

// 结束本轮聚合:释放串行标记;飞行中排队的触发(账号状态已变)重跑一次。
void AccountManager::finishHomeFetch()
{
    qDebug() << "AccountManager: 首页聚合完成,行数" << m_homeRows.size();
    m_homeFetchActive = false;
    if (m_homeFetchQueued) {
        m_homeFetchQueued = false;
        fetchHomeRows(m_homeLimit);
    }
}

// 账号顺序变化(拖拽/上移下移/删除)时按新顺序本地重排首页聚合行。
// 数据未变,仅顺序变化——不重拉网络,否则会撞上重登中的 token 失效,
// 401 触发连锁重登并导致首页反复重建(触发 Qt 引擎 delegate 销毁期噪音)。
void AccountManager::reorderHomeRows()
{
    if (m_homeRows.isEmpty())
        return;
    QVariantList out;
    for (const auto &acc : m_accounts) {
        for (const auto &row : m_homeRows) {
            if (row.toMap().value(QStringLiteral("accountId")).toString() == acc.id)
                out.append(row);
        }
    }
    // 顺序路径 out 含全部行(重排);删除路径 out 已剔除被删服的行。
    m_homeRows = out;
    m_homeRowsModel->setRows(visibleHomeRows());
    rebuildCustomHomeRows();
}

// 播放历史拉取(见 fetchPlaybackHistory):延迟到首页聚合之后开拉,已调度
// 则忽略重复调用。
void AccountManager::fetchPlaybackHistory()
{
    if (m_historyScheduled)
        return;
    m_historyScheduled = true;
    QTimer::singleShot(MoePlayer::kHistoryStartupDelayMs, this,
                       &AccountManager::startPlaybackHistoryFetch);
}

void AccountManager::refreshPlaybackHistory()
{
    // 上一批次的明细补全仍在排队/在途时不开新批次:startPlaybackHistoryFetch 会清空
    // 明细队列并把在途计数归零(见实现),被丢的条目因 dateFetched 仍缺会在新批次里
    // 重新入队,明细请求翻倍 —— 而"列表就绪"在列表到位时就已置位,不足以代表明细排空。
    // 进行中的批次会把记录填好并经 historyChanged 通知页面,页面不缺新鲜度。
    if (m_historyActive || !m_historyDetailQueue.isEmpty() || m_historyDetailInFlight > 0)
        return;
    startPlaybackHistoryFetch();
}

void AccountManager::refreshHistoryItem(const QString &serverUrl, const QString &accountId,
                                        const QString &itemId)
{
    if (serverUrl.trimmed().isEmpty() || accountId.isEmpty() || itemId.isEmpty())
        return;
    // 延时拉:Stopped 报告之后服务器才写 LastPlayedDate(见 constants),拉早了
    // 只会把旧值原样合回去。
    const QString url = serverUrl.trimmed();
    QTimer::singleShot(kHistoryItemRefreshDelayMs, this, [this, url, accountId, itemId]() {
        const AccountInfo *acc = accountById(accountId);
        if (!acc || acc->token.isEmpty() || acc->userId.isEmpty())
            return;
        m_historyOneShot.insert(url + QLatin1Char('|') + accountId + QLatin1Char('|') + itemId);
        m_client->fetchItemUserData(url, accountId, acc->token, acc->userId, itemId);
    });
}

void AccountManager::startPlaybackHistoryFetch()
{
    if (m_historyActive)
        return; // 已在拉取(启动批次或上一次触发未结束):跳过,避免重复批次互相踩
    m_historyScopes.clear();
    m_historyOutstanding.clear();
    m_historyAccum.clear();
    m_historyPages.clear();
    m_historyPhase.clear();
    m_historyDetailQueue.clear();
    m_historyDetailInFlight = 0;
    for (const AccountInfo &acc : std::as_const(m_accounts)) {
        if (acc.token.isEmpty() || acc.userId.isEmpty())
            continue; // 未登录/凭据不全的账号跳过(下次启动再试)
        if (!m_showHidden && accountHiddenStored(acc))
            continue; // 隐藏账号不拉历史(条目按可见性过滤,见 hiddenChanged)
        const QString scope = acc.serverUrl.trimmed() + QLatin1Char('|') + acc.id;
        m_historyScopes.insert(scope);
        // 先记列表请求这一票:否则某账号先返回空结果时会被误判为"全部完成"。
        // 逐页回补的后续页不单独记票(只到整账号收尾时才结算)。
        m_historyOutstanding.insert(scope, 1);
        m_client->fetchPlaybackHistory(acc.serverUrl, acc.id, acc.token, acc.userId,
                                       0, MoePlayer::kHistoryFetchLimit, false);
    }
    m_historyActive = !m_historyScopes.isEmpty();
    if (!m_historyActive)
        emit playbackHistoryReady();
}

QVariantList AccountManager::historyItemsWithPosterIds(const QVariantList &items,
                                                        const QString &accountId) const
{
    QVariantList out;
    out.reserve(items.size());
    for (const QVariant &v : items) {
        QVariantMap m = v.toMap();
        const QString pid = m.value(QStringLiteral("posterId")).toString();
        if (!pid.isEmpty())
            m.insert(QStringLiteral("posterId"), serverPosterId(accountId, pid));
        const QString sid = m.value(QStringLiteral("seriesPosterId")).toString();
        if (!sid.isEmpty())
            m.insert(QStringLiteral("seriesPosterId"), serverPosterId(accountId, sid));
        out.append(m);
    }
    return out;
}

void AccountManager::onHistoryListReceived(const QString &serverUrl, const QString &accountId,
                                           int startIndex, const QVariantList &items, int total, bool ok)
{
    const QString scope = serverUrl.trimmed() + QLatin1Char('|') + accountId;
    if (!m_historyScopes.contains(scope) || !accountById(accountId))
        return; // 非本轮参与或账号已删除
    // 失败与"成功但确有零条播放记录"都会带空列表:失败时必须保留既有条目与
    // fetchedAt(后者目前只写不读,为将来按陈旧度触发拉取保留),只结算列表这一票。
    if (!ok) {
        qInfo() << "AccountManager: 播放历史拉取失败,保留既有数据" << scope;
        m_historyAccum.remove(scope);
        m_historyPages.remove(scope);
        m_historyPhase.remove(scope);
        onHistoryTaskDone(scope);
        return;
    }
    // 两段式取全:先取"窗口页"(不带服务器过滤,与既有语义一致:含"在看"),再进入
    // **过滤段**取更早的已看条目。过滤会换一套下标空间(实测:窗口页拿到 200 条后
    // 带 Filters=IsPlayed 且 StartIndex=200 的请求返回 0 条),故过滤段的 StartIndex
    // 必须从 0 重新数起,按过滤后的 total 推进。
    // 窗口页与过滤段头部重叠(过滤段 StartIndex 从 0 重数),同一 id 会来两次;
    // 只收首次出现的那份(= 窗口页,seq 更小),并在这里重排**全局** seq:每页
    // 响应的 seq 都从 0 重数,直接沿用会让"列表最前 N 条"命中每一页的头部。
    QVariantList accum = m_historyAccum.value(scope);
    QSet<QString> accumIds;
    for (const QVariant &v : std::as_const(accum))
        accumIds.insert(v.toMap().value(QStringLiteral("id")).toString());
    int dupSkipped = 0;
    for (const QVariant &v : items) {
        QVariantMap m = v.toMap();
        const QString id = m.value(QStringLiteral("id")).toString();
        if (accumIds.contains(id)) {
            ++dupSkipped;
            continue;
        }
        accumIds.insert(id);
        m.insert(QStringLiteral("seq"), accum.size());
        accum.append(m);
    }
    if (dupSkipped > 0)
        qInfo() << "AccountManager: 播放历史跳过重复条目" << dupSkipped << scope;
    const AccountInfo *acc = accountById(accountId);
    const bool canContinue = acc != nullptr && !acc->token.isEmpty() && !acc->userId.isEmpty();
    const int phase = m_historyPhase.value(scope, 0);
    // 窗口页的"还有更多"只能用"整页"判:它不带过滤,TotalRecordCount 是整个媒体库的
    // 条目数,按它推进会一路翻到页数上限且几乎全是未播条目。整页(== Limit)才说明
    // 库里还有更早的条目,也才需要过滤段去取更早的**已看**条目;没拉满说明整个库
    // 都在这一页里,已播集合必然已在其中,过滤段可以整个跳过。
    if (phase == 0 && items.size() >= MoePlayer::kHistoryFetchLimit && canContinue) {
        // 窗口页到手(且整页)→ 开过滤段(StartIndex 0)。
        m_historyAccum.insert(scope, accum);
        m_historyPages.insert(scope, 0);
        m_historyPhase.insert(scope, 1);
        m_client->fetchPlaybackHistory(acc->serverUrl, acc->id, acc->token, acc->userId,
                                       0, MoePlayer::kHistoryFetchLimit, true);
        return; // 本轮不结算:等过滤段
    }
    const int next = startIndex + items.size();
    const int pages = m_historyPages.value(scope) + 1;
    if (phase >= 1 && !items.isEmpty() && next < total
        && pages < MoePlayer::kHistoryMaxHistoryPages && canContinue) {
        m_historyAccum.insert(scope, accum);
        m_historyPages.insert(scope, pages);
        m_client->fetchPlaybackHistory(acc->serverUrl, acc->id, acc->token, acc->userId,
                                       next, MoePlayer::kHistoryFetchLimit, true);
        return; // 本轮不结算:等下一页
    }
    const int pageCount = pages + 1; // 窗口页 + 过滤段页数
    m_historyAccum.remove(scope);
    m_historyPages.remove(scope);
    m_historyPhase.remove(scope);
    // 海报键与首页条目同构,仅差服务器前缀(补上后图片提供器跨服通用)。
    const QVariantList stored = historyItemsWithPosterIds(accum, accountId);
    // 变更检测:先留一份本地旧条目再整体覆盖(见 PlaybackHistory::setItems)。
    // 列表端点不返回上次播放时间,故以 (id, 观看进度, 已看) 是否有变化、以及
    // 时间戳是否已知为判据,只对"新增/有变化/尚无时间戳"的条目逐条补明细;
    // 未变且有时间的条目一条请求都不发(稳态明细请求为 0,见 constants)。
    QHash<QString, QVariantMap> before;
    const QVariantList oldItems = m_playbackHistory->items(serverUrl, accountId);
    for (const QVariant &v : oldItems) {
        const QVariantMap m = v.toMap();
        before.insert(m.value(QStringLiteral("id")).toString(), m);
    }
    m_playbackHistory->setItems(serverUrl, accountId, stored);
    m_playbackHistory->flush(); // 列表即刻落盘:UI 可立即消费,不等后台明细
    int needDetail = 0;
    int skipped = 0;
    int untraced = 0;
    for (const QVariant &v : std::as_const(stored)) { // 列表按最近播放倒序
        if (needDetail >= MoePlayer::kHistoryDetailLimit)
            break;
        const QVariantMap m = v.toMap();
        // 无播放痕迹的条目不会入库(见 hasPlayTrace):补明细也留不下结果。
        if (!hasPlayTrace(m)) {
            ++untraced;
            continue;
        }
        const QString id = m.value(QStringLiteral("id")).toString();
        const QVariantMap old = before.value(id);
        // 变化判据:新增/进度或已看状态变化/尚无时间戳,以及**列表最前的若干条**。
        // 列表端点不给上次播放时间(实测:PlayCount 恒为 0、追加 Fields 也拿不到
        // 日期),唯一可靠的是它按 DatePlayed 倒序 ⇒ 被重播的条目必然被提升到
        // 最前;而重看同一集时进度与"已看"可能一字不变(续播点没动),只比这两项
        // 会让时间戳永远停在第一次补全的结果上(旧实现即如此)。故最前
        // kHistoryTopAlwaysDetail 条无条件重取明细,更早的条目若被重播也一定会
        // 进入这个窗口,不会漏。
        const bool changed =
            old.isEmpty()
            || m.value(QStringLiteral("seq")).toInt() < kHistoryTopAlwaysDetail
            || old.value(QStringLiteral("positionTicks")).toDouble()
                   != m.value(QStringLiteral("positionTicks")).toDouble()
            || old.value(QStringLiteral("played")).toBool()
                   != m.value(QStringLiteral("played")).toBool();
        const bool dateKnown = old.value(QStringLiteral("lastPlayedAt")).toLongLong() > 0
                               || old.value(QStringLiteral("dateFetched")).toBool();
        if (!changed && dateKnown) {
            ++skipped;
            continue;
        }
        m_historyDetailQueue.enqueue({ scope, id });
        ++needDetail;
    }
    qInfo() << "AccountManager: 播放历史列表" << stored.size() << "条(回补" << pageCount << "页),补明细"
            << needDetail
            << "条(未变且有时间的" << skipped << "条跳过,无播放痕迹的" << untraced
            << "条不入库)" << scope;
    if (needDetail > 0)
        drainHistoryDetails();
    onHistoryTaskDone(scope); // 该账号仅"列表"一票
}

// 按并发上限从队列派发明细请求(账号已删除/凭据失效直接计完成)。
void AccountManager::drainHistoryDetails()
{
    while (m_historyDetailInFlight < MoePlayer::kHistoryDetailConcurrency
           && !m_historyDetailQueue.isEmpty()) {
        const QPair<QString, QString> task = m_historyDetailQueue.dequeue();
        const QString accountId = task.first.mid(task.first.lastIndexOf(QLatin1Char('|')) + 1);
        const AccountInfo *acc = accountById(accountId);
        if (!acc || acc->token.isEmpty()) {
            onHistoryTaskDone(task.first);
            continue;
        }
        ++m_historyDetailInFlight;
        m_client->fetchItemUserData(acc->serverUrl, acc->id, acc->token, acc->userId, task.second);
    }
}

void AccountManager::onHistoryTaskDone(const QString &scope)
{
    const auto it = m_historyOutstanding.find(scope);
    if (it == m_historyOutstanding.end())
        return;
    if (--it.value() > 0)
        return;
    m_historyOutstanding.erase(it);
    finishHistoryScope(scope);
}

// 该账号拉取收尾(列表已在到位时落盘):所有账号收尾后发就绪,不等后台明细。
void AccountManager::finishHistoryScope(const QString &scope)
{
    Q_UNUSED(scope);
    if (!m_historyOutstanding.isEmpty() || !m_historyActive)
        return;
    m_historyActive = false;
    qInfo() << "AccountManager: 播放历史列表就绪(明细后台补全中),账号数"
            << m_historyScopes.size();
    emit playbackHistoryReady();
}

// 账号在拉取途中被删除:撤出本轮(票数与存储一并清理),避免批次永远等不到收尾。
void AccountManager::abandonHistoryScope(const QString &scope)
{
    if (!m_historyScopes.remove(scope))
        return;
    m_historyOutstanding.remove(scope);
    if (m_historyOutstanding.isEmpty() && m_historyActive) {
        m_historyActive = false;
        emit playbackHistoryReady();
    }
}

// 详情页进入时的按需刷新:只拉该账号的继续观看列表(服务器按上次播放倒序,
// 含"有进度"与"下一未看集"两类),结果回写本地并发 accountHistoryRefreshed。
void AccountManager::refreshAccountHistory(const QString &accountId)
{
    const AccountInfo *acc = accountById(accountId);
    if (!acc || acc->token.isEmpty() || acc->userId.isEmpty())
        return; // 凭据不全:调用方走本地回退
    if (!m_showHidden && accountHiddenStored(*acc))
        return; // 隐藏账号:不拉(其条目也不展示)
    m_client->fetchResume(acc->serverUrl, accountId, acc->token, acc->userId,
                          MoePlayer::kResumeLimit);
}

void AccountManager::onResumeReceived(const QString &serverUrl, const QString &accountId,
                                      const QVariantList &items)
{
    if (!items.isEmpty() && accountById(accountId)) {
        m_playbackHistory->upsertItems(serverUrl, accountId,
                                       historyItemsWithPosterIds(items, accountId));
        m_historyFlushTimer.start();
    }
    // 空列表(失败/确无目标)照常转发:调用方按"无目标"处理并走其它回退。
    emit accountHistoryRefreshed(serverUrl, accountId, items);
}

void AccountManager::onAllEpisodesParsed(const QString &serverUrl, const QString &accountId,
                                         const QString &seriesId, const QVariantList &items)
{
    Q_UNUSED(seriesId);
    if (items.isEmpty() || !accountById(accountId))
        return;
    // 逐季分集回写:选集栏的展示仍走 EmbyClient 的全季模型,这里只补本地记录。
    m_playbackHistory->upsertItems(serverUrl, accountId,
                                   historyItemsWithPosterIds(items, accountId));
    m_historyFlushTimer.start();
}

void AccountManager::maybeAssembleHomeRows()
{
    const bool allDone = (m_homePending == 0);
    QVariantList out;
    for (const auto &ord : m_homeAccountOrder) {
        const QVariantMap om = ord.toMap();
        const QString accountId = om.value(QStringLiteral("id")).toString();
        const QString serverUrl = om.value(QStringLiteral("serverUrl")).toString();
        QString serverName = om.value(QStringLiteral("name")).toString();
        if (serverName.isEmpty()) {
            const int ai = accountIndexById(accountId);
            if (ai >= 0)
                serverName = m_accounts[ai].userName;
        }
        const QVariantList views = m_homeViews.value(accountId);
        if (!m_homeViews.contains(accountId)) {
            // 视图仍在途:先沿用该服现有行(缓存/上轮),等壳到位再换。
            for (const auto &old : m_homeRows)
                if (old.toMap().value(QStringLiteral("accountId")).toString() == accountId)
                    out.append(old);
            continue;
        }
        if (views.isEmpty())
            continue; // 该服视图失败/无果:跳过,不显示(仅保留成功服)
        // 库壳已到:逐库建行。items 优先级 = 新鲜 > 上次缓存 > 空占位(加载中)。
        for (const auto &v : views) {
            const QVariantMap vm = v.toMap();
            const QString viewId = vm.value(QStringLiteral("id")).toString();
            const QString viewName = vm.value(QStringLiteral("name")).toString();
            const QString key = accountId + QLatin1Char('|') + viewId;
            QVariantList items;
            const bool fresh = m_homeRowByKey.contains(key);
            if (fresh) {
                items = m_homeRowByKey.value(key).value(QStringLiteral("items")).toList();
                // 新鲜条目海报未加前缀,此处补上(缓存条目已带前缀,不再重复)。
                for (int i = 0; i < items.size(); ++i) {
                    QVariantMap it = items.at(i).toMap();
                    const QString pid = it.value(QStringLiteral("posterId")).toString();
                    if (!pid.isEmpty())
                        it.insert(QStringLiteral("posterId"), serverPosterId(accountId, pid));
                    items[i] = it;
                }
            } else {
                // 未到新鲜:沿用上次行的缓存 items(已带前缀)。
                for (const auto &old : m_homeRows) {
                    const QVariantMap orow = old.toMap();
                    if (orow.value(QStringLiteral("accountId")).toString() == accountId
                        && orow.value(QStringLiteral("viewId")).toString() == viewId) {
                        items = orow.value(QStringLiteral("items")).toList();
                        break;
                    }
                }
            }
            // 新鲜结果为空:库无内容(空库/权限不可见/请求失败),不占首页行。
            if (fresh && items.isEmpty())
                continue;
            if (!fresh && items.isEmpty())
                continue;
            QVariantMap row;
            row.insert(QStringLiteral("viewId"), viewId);
            row.insert(QStringLiteral("viewName"), viewName);
            row.insert(QStringLiteral("collectionType"),
                       vm.value(QStringLiteral("collectionType")).toString());
            row.insert(QStringLiteral("accountId"), accountId);
            row.insert(QStringLiteral("serverUrl"), serverUrl);
            row.insert(QStringLiteral("serverName"), serverName);
            row.insert(QStringLiteral("posterId"),
                       serverPosterId(accountId,
                                      vm.value(QStringLiteral("posterId")).toString()));
            // loading:新鲜未到位(占位/缓存回退);到位后 false。
            row.insert(QStringLiteral("items"), items);
            row.insert(QStringLiteral("loading"), !fresh);
            out.append(row);
        }
    }
    // 本轮未参与(隐藏被跳过)的账号:沿用其现有行 —— 否则隐藏期间的行会被抹掉,
    // 露出后首页要空等网络;带上后露出即时可见,随即被露出触发的重拉覆盖。
    for (const auto &a : m_accounts) {
        if (!accountHiddenStored(a))
            continue;
        bool inRound = false;
        for (const auto &ord : m_homeAccountOrder)
            if (ord.toMap().value(QStringLiteral("id")).toString() == a.id) {
                inRound = true;
                break;
            }
        if (inRound)
            continue;
        for (const auto &old : m_homeRows)
            if (old.toMap().value(QStringLiteral("accountId")).toString() == a.id)
                out.append(old);
    }
    // 按账号顺序归一(沿用行插回原位;聚合本身即按账号顺序产出)。
    QVariantList ordered;
    ordered.reserve(out.size());
    for (const auto &a : m_accounts) {
        for (const auto &row : out) {
            if (row.toMap().value(QStringLiteral("accountId")).toString() == a.id)
                ordered.append(row);
        }
    }
    // 逐行增量更新模型(setRows 内部只对变化的行发 per-row 信号),
    // 渲染只重估变化行;homeRows 快照同步供缓存与语义比较。
    m_homeRows = ordered;
    m_homeRowsModel->setRows(visibleHomeRows());
    rebuildCustomHomeRows(allDone);
    if (allDone)
        saveHomeCache(); // 全部完成才缓存,保证缓存是完整可依赖集合
    emit homeRowsReady();
    if (allDone)
        finishHomeFetch();
}

// ---- 服务器文件夹(分类)----
// 纯视觉分组:不影响账号列表/首页聚合顺序,只决定服务器管理页的展示
// 归属。持久化于 accounts.json(folders 段),账号结构不动。

QVariantList AccountManager::folders() const
{
    QVariantList out;
    for (const auto &f : m_folders) {
        QVariantMap m;
        m.insert(QLatin1String("id"), f.id);
        m.insert(QLatin1String("name"), f.name);
        m.insert(QLatin1String("color"), f.color);
        m.insert(QLatin1String("hidden"), f.hidden);
        QVariantList ids;
        for (const auto &id : f.accountIds)
            ids.append(id);
        m.insert(QLatin1String("accountIds"), ids);
        out.append(m);
    }
    return out;
}

// ---- 视觉顺序(混合序列)----
// 顶层元素 = 文件夹块 + 未分组账号,顺序即管理页展示顺序。账号视觉
// 顺序(展平)恒等于 accounts 顺序:任何重排同步 accounts 顺序,首页
// 聚合(reorderHomeRows)跟随视觉,不重拉网络。

QVariantMap AccountManager::makeLayoutEntry(const QString &type, const QString &id)
{
    QVariantMap m;
    m.insert(QLatin1String("type"), type);
    m.insert(QLatin1String("id"), id);
    return m;
}

QStringList AccountManager::visualAccountOrder(const QVariantList &order) const
{
    QStringList out;
    for (const auto &v : order) {
        const QVariantMap m = v.toMap();
        const QString type = m.value(QLatin1String("type")).toString();
        if (type == QLatin1String("folder")) {
            const auto *f = folderById(m.value(QLatin1String("id")).toString());
            if (f)
                out.append(f->accountIds);
        } else if (type == QLatin1String("account")) {
            out.append(m.value(QLatin1String("id")).toString());
        }
    }
    return out;
}

bool AccountManager::reorderFoldersToLayout(const QVariantList &order)
{
    QList<FolderInfo> reordered;
    for (const auto &v : order) {
        const QVariantMap m = v.toMap();
        if (m.value(QLatin1String("type")).toString() != QLatin1String("folder"))
            continue;
        const auto *f = folderById(m.value(QLatin1String("id")).toString());
        if (f)
            reordered.append(*f);
    }
    bool changed = reordered.size() != m_folders.size();
    if (!changed) {
        for (int i = 0; i < m_folders.size(); ++i)
            if (m_folders.at(i).id != reordered.at(i).id) {
                changed = true;
                break;
            }
    }
    if (changed)
        m_folders = reordered;
    return changed;
}

bool AccountManager::reorderAccountsToVisual(const QVariantList &order)
{
    // 视觉序可能含已删账号的残留 id(文件夹成员表历史数据):按 id 取回
    // 可能为空,跳过而非解引用(空指针即崩溃)。
    const QStringList visual = visualAccountOrder(order);
    QList<AccountInfo> reordered;
    reordered.reserve(m_accounts.size());
    QSet<QString> taken;
    for (const auto &id : visual) {
        const auto *a = accountById(id);
        if (!a || taken.contains(id))
            continue;
        taken.insert(id);
        reordered.append(*a);
    }
    // 视觉序未覆盖的账号(异常数据)按原顺序补回,不丢账号。
    for (const auto &a : m_accounts)
        if (!taken.contains(a.id))
            reordered.append(a);

    bool changed = reordered.size() != m_accounts.size();
    if (!changed) {
        for (int i = 0; i < m_accounts.size(); ++i)
            if (m_accounts.at(i).id != reordered.at(i).id) {
                changed = true;
                break;
            }
    }
    if (changed)
        m_accounts = reordered;
    return changed;
}

void AccountManager::setLayoutOrder(const QVariantList &order)
{
    // 1. 过滤:未知/重复项丢弃;成员账号不占视觉位(跟随所属文件夹块)。
    QVariantList cleaned;
    QSet<QString> seen;
    auto push = [&](const QString &type, const QString &id) {
        const QString key = type + QLatin1Char(':') + id;
        if (seen.contains(key))
            return;
        seen.insert(key);
        cleaned.append(makeLayoutEntry(type, id));
    };
    for (const auto &v : order) {
        const QVariantMap m = v.toMap();
        const QString type = m.value(QLatin1String("type")).toString();
        const QString id = m.value(QLatin1String("id")).toString();
        if (type == QLatin1String("folder")) {
            if (folderIndexById(id) >= 0)
                push(type, id);
        } else if (type == QLatin1String("account")) {
            if (accountById(id) && folderIdOfAccount(id).isEmpty())
                push(type, id);
        }
    }
    // 2. 补全:未出现的文件夹(现顺序)与未分组账号(accounts 顺序)追加尾部。
    for (const auto &f : m_folders)
        push(QLatin1String("folder"), f.id);
    for (const auto &a : m_accounts)
        if (folderIdOfAccount(a.id).isEmpty())
            push(QLatin1String("account"), a.id);

    // 3. 按序重排文件夹与账号(仅顺序,不动数据)。
    const bool foldersReordered = reorderFoldersToLayout(cleaned);
    const bool accountsReordered = reorderAccountsToVisual(cleaned);
    m_layoutOrder = cleaned;
    save();
    if (foldersReordered) {
        save();
        emit foldersChanged();
    }
    if (accountsReordered) {
        reorderHomeRows();
        save();
        emit accountsChanged();
        emit homeRowsReady(); // 首页聚合行顺序已变,通知 UI 重建
    }
    emit layoutOrderChanged();
}



void AccountManager::removeFromLayoutOrder(const QString &type, const QString &id)
{
    for (int i = 0; i < m_layoutOrder.size(); ++i) {
        const QVariantMap m = m_layoutOrder.at(i).toMap();
        if (m.value(QLatin1String("type")).toString() == type
            && m.value(QLatin1String("id")).toString() == id) {
            m_layoutOrder.removeAt(i);
            return;
        }
    }
}

QString AccountManager::addFolder(const QString &name, const QString &color)
{
    FolderInfo f;
    f.id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    // 颜色:显式传入优先,空则随机挑预设色。
    f.color = color.trimmed();
    if (f.color.isEmpty())
        f.color = kPresetFolderColors.at(QRandomGenerator::global()
                                             ->bounded(kPresetFolderColors.size()));
    // 空名自动命名:取未占用的"文件夹 N"(N 从 2 起递增,避免与"文件夹 1"
    // 歧义;首个空名即"文件夹 1")。
    if (name.trimmed().isEmpty()) {
        f.name = QStringLiteral("文件夹 1");
        for (int n = 2;; ++n) {
            bool taken = false;
            for (const auto &e : m_folders) {
                if (e.name == f.name) {
                    taken = true;
                    break;
                }
            }
            if (!taken)
                break;
            f.name = QStringLiteral("文件夹 %1").arg(n);
        }
    } else {
        f.name = name.trimmed();
    }
    m_folders.append(f);
    m_layoutOrder.append(makeLayoutEntry(QLatin1String("folder"), f.id));
    save();
    emit foldersChanged();
    return f.id;
}

void AccountManager::removeFolder(const QString &id)
{
    for (int i = 0; i < m_folders.size(); ++i) {
        if (m_folders.at(i).id != id)
            continue;
        const QStringList members = m_folders.at(i).accountIds;
        m_folders.removeAt(i);
        // 视觉顺序:删文件夹项;成员释放为未分组,占位插到该文件夹项
        // 原位置(按加入顺序),保持视觉连续。
        int pos = -1;
        for (int j = 0; j < m_layoutOrder.size(); ++j) {
            const QVariantMap m = m_layoutOrder.at(j).toMap();
            if (m.value(QLatin1String("type")).toString() == QLatin1String("folder")
                && m.value(QLatin1String("id")).toString() == id) {
                pos = j;
                break;
            }
        }
        if (pos >= 0) {
            m_layoutOrder.removeAt(pos);
            for (int k = members.size() - 1; k >= 0; --k)
                m_layoutOrder.insert(pos, makeLayoutEntry(QLatin1String("account"), members.at(k)));
        }
        const bool acctChanged = reorderAccountsToVisual(m_layoutOrder);
        save();
        if (acctChanged) {
            reorderHomeRows();
            save();
            emit accountsChanged();
            emit homeRowsReady();
        }
        emit foldersChanged();
        return;
    }
}

void AccountManager::renameFolder(const QString &id, const QString &name)
{
    FolderInfo *f = folderById(id);
    if (!f)
        return;
    const QString n = name.trimmed();
    if (n.isEmpty() || f->name == n)
        return;
    f->name = n;
    save();
    emit foldersChanged();
}

void AccountManager::setFolderColor(const QString &id, const QString &color)
{
    FolderInfo *f = folderById(id);
    if (!f)
        return;
    const QString c = color.trimmed();
    if (c.isEmpty() || f->color == c)
        return;
    f->color = c;
    save();
    emit foldersChanged();
}

QStringList AccountManager::presetFolderColors() const
{
    return kPresetFolderColors;
}

QString AccountManager::folderIdOfAccount(const QString &accountId) const
{
    for (const auto &f : m_folders)
        if (f.accountIds.contains(accountId))
            return f.id;
    return QString();
}

void AccountManager::addAccountToFolder(const QString &folderId, const QString &accountId,
                                        const QString &beforeAccountId)
{
    FolderInfo *f = folderById(folderId);
    if (!f)
        return;
    if (f->accountIds.contains(accountId))
        return; // 已在目标文件夹:忽略
    // 在其他文件夹:先移出(一个账号只属于一个文件夹)。
    for (auto &e : m_folders) {
        if (e.id == folderId)
            continue;
        if (e.accountIds.removeOne(accountId))
            break;
    }
    int ins = f->accountIds.indexOf(beforeAccountId);
    if (ins < 0)
        ins = f->accountIds.size();
    f->accountIds.insert(ins, accountId);
    // 成员不占视觉位:从 layoutOrder 移除账号项,并按展平顺序重排
    // accounts(账号进文件夹块,首页聚合跟随视觉)。
    removeFromLayoutOrder(QLatin1String("account"), accountId);
    const bool acctChanged = reorderAccountsToVisual(m_layoutOrder);
    save();
    if (acctChanged) {
        reorderHomeRows();
        save();
        emit accountsChanged();
        emit homeRowsReady();
    }
    emit foldersChanged();
}

void AccountManager::moveAccountInFolder(const QString &folderId, const QString &accountId,
                                         const QString &beforeAccountId)
{
    FolderInfo *f = folderById(folderId);
    if (!f || !f->accountIds.contains(accountId) || accountId == beforeAccountId)
        return;
    // 落点语义 = 占据目标格位:前拖后插目标之后,后拖前插目标之前
    // (否则相邻前移 = 原地不动的假死)。
    const int fromIdx = f->accountIds.indexOf(accountId);
    const int toOrig = f->accountIds.indexOf(beforeAccountId);
    f->accountIds.removeAll(accountId);
    int pos = f->accountIds.indexOf(beforeAccountId);
    if (pos < 0)
        pos = f->accountIds.size();
    else if (toOrig > fromIdx)
        pos += 1;
    f->accountIds.insert(pos, accountId);
    save();
    emit foldersChanged();
}

void AccountManager::removeAccountFromFolder(const QString &accountId)
{
    for (auto &f : m_folders) {
        if (!f.accountIds.removeOne(accountId))
            continue;
        // 账号回到未分组:占位插入 layoutOrder 末尾;拖出目标位由 QML
        // 紧接 setLayoutOrder 调整(同步执行,无渲染中间态)。
        m_layoutOrder.append(makeLayoutEntry(QLatin1String("account"), accountId));
        const bool acctChanged = reorderAccountsToVisual(m_layoutOrder);
        save();
        if (acctChanged) {
            reorderHomeRows();
            save();
            emit accountsChanged();
            emit homeRowsReady();
        }
        emit foldersChanged();
        return;
    }
}

int AccountManager::folderIndexById(const QString &id) const
{
    for (int i = 0; i < m_folders.size(); ++i)
        if (m_folders.at(i).id == id)
            return i;
    return -1;
}

const AccountManager::FolderInfo *AccountManager::folderById(const QString &id) const
{
    const int i = folderIndexById(id);
    return i >= 0 ? &m_folders.at(i) : nullptr;
}

AccountManager::FolderInfo *AccountManager::folderById(const QString &id)
{
    const int i = folderIndexById(id);
    return i >= 0 ? &m_folders[i] : nullptr;
}



// 设置图标:来源可为远程 URL(下载字节)或本地图片(file:///已有路径,
// 直接读字节);统一落盘 MD5 命名本地缓存后写 icon。来源空 → 清除 icon
// (回退名称首字)。用户自定义图标优先于服务器默认。

// 读取本地图片原始字节(本地绝对路径;读失败/文件不存在返回空)。
static QByteArray readLocalImageFile(const QString &path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return QByteArray();
    return f.readAll();
}

// 写入图标缓存并按 id 落位:内容去重(同图不重写),账号不存在忽略。
void AccountManager::applyAccountIcon(const QString &id, const QByteArray &imageData)
{
    const QString localPath = writeIconCache(imageData);
    if (localPath.isEmpty())
        return;
    for (auto &a : m_accounts) {
        if (a.id != id)
            continue;
        if (a.icon == localPath)
            return;
        a.icon = localPath;
        save();
        emit accountsChanged();
        return;
    }
}

void AccountManager::setAccountIcon(const QString &id, const QString &icon)
{
    const QString src = icon.trimmed();
    if (src.isEmpty()) {
        for (auto &a : m_accounts) {
            if (a.id != id)
                continue;
            if (a.icon.isEmpty())
                return;
            a.icon.clear();
            save();
            emit accountsChanged();
            return;
        }
        return;
    }
    // 本地图片:file:// 或已有的本地路径直接读字节落缓存(不经网络);
    // 否则按远程 URL 下载,失败静默保留当前图标。
    const QUrl u(src);
    if (u.isLocalFile() || QFileInfo::exists(src)) {
        const QString path = u.isLocalFile() ? u.toLocalFile() : src;
        const QByteArray data = readLocalImageFile(path);
        if (!data.isEmpty())
            applyAccountIcon(id, data);
        return;
    }
    m_client->downloadImage(src, [this, id](const QByteArray &data) {
        if (data.isEmpty())
            return;
        applyAccountIcon(id, data);
    });
}

int AccountManager::accountIndexById(const QString &id) const
{
    for (int i = 0; i < m_accounts.size(); ++i)
        if (m_accounts.at(i).id == id)
            return i;
    return -1;
}

const AccountManager::AccountInfo *AccountManager::accountById(const QString &id) const
{
    for (const auto &a : m_accounts)
        if (a.id == id)
            return &a;
    return nullptr;
}

// 首页聚合缓存:上次成功数据落盘(视图列表 + 每库最近条目),启动先展示。
QVariantList AccountManager::loadHomeCache()
{
    QVariant val;
    if (!m_persist.loadCache(kHomeCacheName, val))
        return {};
    return val.toList();
}

void AccountManager::saveHomeCache()
{
    if (m_homeRows.isEmpty())
        return;
    m_persist.saveCache(kHomeCacheName, m_homeRows);
}

// 删号后重写:过滤掉该账号的行并落盘(空表也落——否则缓存原样复活
// 幽灵行;saveHomeCache 的空表早退是给正常聚合用的,不适用删号)。
void AccountManager::saveHomeCacheWithout(const QString &accountId)
{
    QVariantList rows;
    for (const QVariant &v : m_homeRows) {
        if (v.toMap().value(QStringLiteral("accountId")).toString() != accountId)
            rows.append(v);
    }
    m_persist.saveCache(kHomeCacheName, rows);
}

// 推荐缓存:上次各账号的服务器建议。启动先展示,后台回执逐账号覆盖替换。
void AccountManager::loadHomeSuggestionCache()
{
    QVariant val;
    if (!m_persist.loadCache(kHomeSuggCacheName, val))
        return;
    QHash<QString, QVariantList> loaded;
    for (const auto &v : val.toList()) {
        const QVariantMap m = v.toMap();
        const QString id = m.value(QStringLiteral("id")).toString();
        if (id.isEmpty() || accountIndexById(id) < 0)
            continue; // 切片无主(账号已删):作废
        loaded.insert(id, m.value(QStringLiteral("items")).toList());
    }
    if (loaded.isEmpty() || loaded == m_homeSuggByAccount)
        return; // 无可用缓存,或与当前一致:不 emit(hero 重建=可见闪烁)
    m_homeSuggByAccount = loaded;
    int n = 0;
    for (const auto &items : loaded)
        n += items.size();
    qInfo() << "AccountManager: 推荐缓存载入" << loaded.size() << "个账号," << n << "条建议";
    emit suggestionsUpdated();
}

// 写推荐缓存:已回执账号用本轮数据,未回执账号沿用旧缓存(避免半轮覆盖把
// 其他账号的缓存抹掉);账号顺序按当前账号表;内容未变则跳过写盘。
void AccountManager::saveHomeSuggestionCache()
{
    QVariant prevVal;
    const bool havePrev = m_persist.loadCache(kHomeSuggCacheName, prevVal);
    QHash<QString, QVariantList> merged;
    if (havePrev) {
        for (const auto &v : prevVal.toList()) {
            const QVariantMap m = v.toMap();
            const QString id = m.value(QStringLiteral("id")).toString();
            if (!id.isEmpty() && accountIndexById(id) >= 0)
                merged.insert(id, m.value(QStringLiteral("items")).toList());
        }
    }
    for (auto it = m_homeSuggByAccount.constBegin(); it != m_homeSuggByAccount.constEnd(); ++it) {
        if (accountIndexById(it.key()) >= 0)
            merged.insert(it.key(), it.value());
    }
    QVariantList out;
    for (const auto &a : m_accounts) {
        const auto it = merged.constFind(a.id);
        if (it == merged.constEnd() || it.value().isEmpty())
            continue;
        QVariantMap row;
        row.insert(QStringLiteral("id"), a.id);
        row.insert(QStringLiteral("items"), it.value());
        out.append(row);
    }
    if (out.isEmpty() || (havePrev && prevVal.toList() == out))
        return; // 无可写内容或内容未变:不落盘(QVariant 跨数值类型按 C++ 提升规则比较,实测相等)
    if (m_persist.saveCache(kHomeSuggCacheName, out))
        qInfo() << "AccountManager: 推荐缓存已写" << out.size() << "个账号";
}

QString AccountManager::serverPosterId(const QString &accountId, const QString &posterId)
{
    if (posterId.isEmpty())
        return QString();
    // 跨服务器海报 id:<encodeServerKey(accountId)>~<itemId>~<tag>
    // (账号 id 为不可变身份,改地址/切线路免疫),与 PosterProvider 约定一致。
    return encodeServerKey(accountId) + QLatin1Char('~') + posterId;
}

QString AccountManager::encodeServerKey(const QString &accountId)
{
    // Base64URL(无填充):输出仅含字母数字与 - _,可安全放进 image:// URL。
    return QString::fromLatin1(accountId.toUtf8().toBase64(
        QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals));
}

// 图标图片落盘用户数据目录(DataLocation/account-icons/):账号身份的一部分,
// 文件名 = 内容 MD5
// (同图同文件,跨账号去重),后缀统一 .img(Qt Image 按内容解码)。返回
// file:// URL(QML Image.source 裸绝对路径会被 qrc 解析失败,须显式 file://),
// 写失败返回空。
QString AccountManager::writeIconCache(const QByteArray &imageData)
{
    const QString dir = AppPaths::dataDir();
    if (dir.isEmpty())
        return QString();
    const QString iconDir = dir + QStringLiteral("/account-icons");
    QDir d;
    if (!d.mkpath(iconDir)) {
        qWarning().noquote() << "AccountManager: 图标缓存目录创建失败" << iconDir;
        return QString();
    }
    const QString file = iconDir + QLatin1Char('/')
                         + QString::fromLatin1(QCryptographicHash::hash(
                             imageData, QCryptographicHash::Md5).toHex())
                         + QStringLiteral(".img");
    QSaveFile f(file);
    if (!f.open(QIODevice::WriteOnly)) {
        qWarning().noquote() << "AccountManager: 图标缓存写入失败" << file << f.errorString();
        return QString();
    }
    if (f.write(imageData) != imageData.size()) {
        qWarning().noquote() << "AccountManager: 图标缓存写短" << file;
        f.cancelWriting(); // 丢弃临时文件,保留原文件(内容寻址:同 MD5 即同内容)
        return QString();
    }
    if (!f.commit()) {
        qWarning().noquote() << "AccountManager: 图标缓存提交失败" << file << f.errorString();
        return QString();
    }
    return QUrl::fromLocalFile(file).toString();
}

QString AccountManager::decodeServerKey(const QString &key)
{
    return QString::fromUtf8(QByteArray::fromBase64(key.toLatin1(),
                                                    QByteArray::Base64UrlEncoding));
}

void AccountManager::removeAccount(const QString &id)
{
    for (const auto &a : m_accounts) {
        if (a.id == id && !a.token.isEmpty()) {
            m_client->logout(a.serverUrl, a.token, a.userId);
            break;
        }
    }
    auto it = std::remove_if(m_accounts.begin(), m_accounts.end(),
                             [id](const AccountInfo &a) { return a.id == id; });
    if (it == m_accounts.end()) {
        qDebug() << "AccountManager: removeAccount 未找到账号" << id;
        return;
    }
    const QString serverUrl = it->serverUrl;
    m_accounts.erase(it, m_accounts.end());
    // 视觉顺序同步:未分组账号项移除(成员账号不在序列中)。
    removeFromLayoutOrder(QLatin1String("account"), id);
    save();
    // 成员表同步:残留已删 id 会被视觉序展平计入,重排时取不到账号。
    bool foldersTouched = false;
    for (auto &f : m_folders) {
        if (f.accountIds.removeAll(id) > 0)
            foldersTouched = true;
    }
    if (foldersTouched) {
        save();
        emit foldersChanged();
    }
    // 播放历史:删号即撤出本轮拉取(防批次永远等不到收尾),并清除该账号
    // scope 的存储(同服多账号只清被删账号)。
    abandonHistoryScope(serverUrl.trimmed() + QLatin1Char('|') + id);
    m_playbackHistory->removeScope(serverUrl, id);
    m_client->dropServerModels(serverUrl); // 清理该服浏览模型,防无界增长
    reorderHomeRows(); // 被删服的行一并移除,本地重排不重拉网络(见 moveAccount)
    saveHomeCacheWithout(id); // 缓存同步剔除(否则下次启动幽灵行复活)
    save();
    emit accountsChanged();
    emit homeRowsReady();
}

void AccountManager::updateAccount(const QString &id, const QString &name,
                                   const QString &serverUrl, const QString &userName)
{
    for (auto &a : m_accounts) {
        if (a.id != id)
            continue;
        const QString oldUrl = a.serverUrl;
        a.name = name.trimmed();
        a.serverUrl = serverUrl.trimmed();
        a.userName = userName.trimmed();
        // 地址变更:旧身份数据不迁即死(模型键/历史 scope 都含 serverUrl)——
        // 历史 scope 迁移 + 旧模型整清 + 首页重聚合。
        if (oldUrl != a.serverUrl) {
            m_playbackHistory->renameScopeServer(id, oldUrl, a.serverUrl);
            m_client->dropServerModels(oldUrl);
            fetchHomeRows(m_homeLimit);
        }
        save();
        emit accountsChanged();
        return;
    }
}

void AccountManager::load()
{
    const QString path = AppPaths::configDir() + QStringLiteral("/accounts.json");
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return; // 首次启动无文件:常态,静默
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    const QJsonObject data = doc.object().value(QStringLiteral("data")).toObject();
    if (data.isEmpty()) {
        if (!doc.isNull())
            qWarning().noquote() << "AccountManager: accounts.json 结构异常,回空" << path;
        return;
    }
    const QJsonArray arr = data.value(QStringLiteral("accounts")).toArray();
    for (const auto &v : arr) {
        const QJsonObject o = v.toObject();
        AccountInfo a;
        a.id = o.value(QLatin1String("id")).toString();
        a.name = o.value(QLatin1String("name")).toString();
        a.serverUrl = o.value(QLatin1String("serverUrl")).toString();
        a.userName = o.value(QLatin1String("userName")).toString();
        a.userId = o.value(QLatin1String("userId")).toString();
        a.token = o.value(QLatin1String("token")).toString();
        a.password = o.value(QLatin1String("password")).toString();
        a.icon = o.value(QLatin1String("icon")).toString();
        a.lastUsed = o.value(QLatin1String("lastUsed")).toVariant().toLongLong();
        a.hidden = o.value(QLatin1String("hidden")).toBool();
        a.lines = o.value(QLatin1String("lines")).toArray().toVariantList();
        a.activeLine = o.value(QLatin1String("activeLine")).toInt(-1);
        if (!a.id.isEmpty())
            m_accounts.append(a);
    }
    // 文件夹(成员引用已删账号的记录丢弃)
    const QJsonArray farr = data.value(QStringLiteral("folders")).toArray();
    for (const auto &v : farr) {
        const QJsonObject o = v.toObject();
        FolderInfo fdr;
        fdr.id = o.value(QLatin1String("id")).toString();
        fdr.name = o.value(QLatin1String("name")).toString();
        fdr.color = o.value(QLatin1String("color")).toString();
        fdr.hidden = o.value(QLatin1String("hidden")).toBool();
        const QJsonArray ids = o.value(QLatin1String("accountIds")).toArray();
        for (const auto &id : ids) {
            const QString aid = id.toString();
            if (!accountById(aid) || fdr.accountIds.contains(aid))
                continue;
            fdr.accountIds.append(aid);
        }
        if (!fdr.id.isEmpty())
            m_folders.append(fdr);
    }
    // 布局序(经 setLayoutOrder 规范化:滤已删项/重复/成员项,补缺失)
    QVariantList parsed;
    for (const auto &v : data.value(QStringLiteral("layoutOrder")).toArray()) {
        const QVariantMap m = v.toObject().toVariantMap();
        const QString type = m.value(QLatin1String("type")).toString();
        const QString id = m.value(QLatin1String("id")).toString();
        if (type == QLatin1String("folder") || type == QLatin1String("account"))
            parsed.append(makeLayoutEntry(type, id));
    }
    setLayoutOrder(parsed);
}

void AccountManager::save()
{
    QJsonArray arr;
    for (const auto &a : m_accounts) {
        QJsonObject o;
        o.insert(QLatin1String("id"), a.id);
        o.insert(QLatin1String("name"), a.name);
        o.insert(QLatin1String("serverUrl"), a.serverUrl);
        o.insert(QLatin1String("userName"), a.userName);
        o.insert(QLatin1String("userId"), a.userId);
        o.insert(QLatin1String("token"), a.token);
        o.insert(QLatin1String("password"), a.password);
        o.insert(QLatin1String("icon"), a.icon);
        o.insert(QLatin1String("lastUsed"), a.lastUsed);
        o.insert(QLatin1String("hidden"), a.hidden);
        o.insert(QLatin1String("lines"), QJsonArray::fromVariantList(a.lines));
        o.insert(QLatin1String("activeLine"), a.activeLine);
        arr.append(o);
    }
    // folders 段
    QJsonArray farr;
    for (const auto &f : m_folders) {
        QJsonObject o;
        o.insert(QLatin1String("id"), f.id);
        o.insert(QLatin1String("name"), f.name);
        o.insert(QLatin1String("color"), f.color);
        o.insert(QLatin1String("hidden"), f.hidden);
        o.insert(QLatin1String("accountIds"), QJsonArray::fromStringList(f.accountIds));
        farr.append(o);
    }
    const QJsonObject root{
        { QStringLiteral("v"), 1 },
        { QStringLiteral("data"),
          QJsonObject{
              { QStringLiteral("accounts"), arr },
              { QStringLiteral("folders"), farr },
              { QStringLiteral("layoutOrder"), QJsonArray::fromVariantList(m_layoutOrder) },
          } },
    };
    // 凭据文件:原子写 + 0600(token/密码在内,组/其他不可读)。
    // QSaveFile::setPermissions 是 Qt 6.12+ 的 override,6.11 落基类空转
    // (commit 后仍 644)→ commit 后显式补,任何版本都生效。
    const QString path = AppPaths::configDir() + QStringLiteral("/accounts.json");
    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly)) {
        qWarning().noquote() << "AccountManager: accounts.json 打开失败" << f.errorString();
        return;
    }
    f.write(QJsonDocument(root).toJson(QJsonDocument::Compact));
    if (!f.commit()) {
        qWarning().noquote() << "AccountManager: accounts.json 写入失败" << f.errorString();
        return;
    }
    QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
}

QString AccountManager::obfuscate(const QString &plain)
{
    QByteArray b = plain.toUtf8();
    for (int i = 0; i < b.size(); ++i)
        b[i] = b[i] ^ kObfuscationKey[i % kObfuscationKey.size()];
    return QString::fromLatin1(b.toBase64());
}

QString AccountManager::deobfuscate(const QString &cipher)
{
    QByteArray b = QByteArray::fromBase64(cipher.toLatin1());
    for (int i = 0; i < b.size(); ++i)
        b[i] = b[i] ^ kObfuscationKey[i % kObfuscationKey.size()];
    return QString::fromUtf8(b);
}
