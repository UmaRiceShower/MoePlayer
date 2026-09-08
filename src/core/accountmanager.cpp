#include "accountmanager.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRandomGenerator>
#include <QStandardPaths>
#include <QUrl>
#include <QUuid>

#include <algorithm>

#include "core/constants.h"
#include "core/embyclient.h"
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
// QSettings 键。
const QString kAccountsKey = QStringLiteral("accounts/list");
const QString kFoldersKey = QStringLiteral("accounts/folders");
const QString kLayoutOrderKey = QStringLiteral("accounts/layoutOrder");
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
// 首页聚合缓存文件名(CacheLocation 下)。
const QString kHomeCacheFileName = QStringLiteral("/home-rows.json");
// 网络问题账号的定期重试间隔。
constexpr qint64 kNetRetryIntervalMs = 5LL * 60 * 1000;
} // namespace

AccountManager::AccountManager(EmbyClient *client, QObject *parent)
    : QObject(parent)
    , m_client(client)
{
    m_homeRowsModel = new HomeRowsModel(this);
    load();
    loadFolders();
    loadLayoutOrder();

    // 网络问题账号定期重试:先 token 再账密,恢复后清除标记。
    m_netRetryTimer.setInterval(kNetRetryIntervalMs);
    connect(&m_netRetryTimer, &QTimer::timeout, this,
            &AccountManager::retryNetworkAccounts);

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
                persistLayoutOrder();
                save();
                emit accountsChanged();
                qInfo() << "AccountManager: 账号添加成功" << acc.id << "on" << acc.serverUrl;
                emit accountLoginFinished(true, QString());
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
                emit suggestionsUpdated();
            });
    connect(m_client, &EmbyClient::serverItemsReceived, this,
            [this](const QString &serverUrl, const QString &accountId,
                   const QString &viewId, const QVariantList &items) {
                if (accountIndexById(accountId) < 0 || m_homeReqGen.value(accountId) != m_homeGen)
                    return; // 无对应账号或属过期代次,丢弃
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
        const auto it = m_homeSuggByAccount.constFind(a.id);
        if (it == m_homeSuggByAccount.constEnd())
            continue;
        for (const auto &v : it.value()) {
            QVariantMap m = v.toMap();
            m.insert(QStringLiteral("serverUrl"), a.serverUrl);
            m.insert(QStringLiteral("accountId"), a.id);
            const QString pid = m.value(QStringLiteral("posterId")).toString();
            if (!pid.isEmpty())
                m.insert(QStringLiteral("posterId"), serverPosterId(a.serverUrl, pid));
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
        out.append(m);
    }
    return out;
}

bool AccountManager::hasAccounts() const
{
    return !m_accounts.isEmpty();
}

QVariantMap AccountManager::credsForServer(const QString &serverUrl) const
{
    const QString url = serverUrl.trimmed();
    // 同服务器多账号:优先未标失效的(首个有效 token);全失效时取首个。
    for (int pass = 0; pass < 2; ++pass) {
        for (const auto &a : m_accounts) {
            if (a.serverUrl != url || a.token.isEmpty())
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
    return m;
}

// 启动校验:对所有有 token 的账号发轻量认证请求(/System/Info)。
void AccountManager::validateTokens()
{
    int n = 0;
    for (const auto &a : m_accounts)
        if (!a.token.isEmpty()) {
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
    for (const QString &id : ids)
        checkAccountToken(id);
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
    m_homeRowsModel->setRows(cached); // setRows 内部只对变化行发信号
    emit homeRowsReady();

    for (int i = 0; i < m_accounts.size(); ++i) {
        const AccountInfo &a = m_accounts.at(i);
        if (a.token.isEmpty())
            continue; // 无凭据的账号跳过,不参与聚合
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
    m_homeRowsModel->setRows(out);
}

void AccountManager::maybeAssembleHomeRows()
{
    const bool allDone = (m_homePending == 0);
    QVariantList out;
    for (const auto &ord : m_homeAccountOrder) {
        const QVariantMap om = ord.toMap();
        const QString accountId = om.value(QStringLiteral("id")).toString();
        const QString serverUrl = om.value(QStringLiteral("serverUrl")).toString();
        const QString serverName = om.value(QStringLiteral("name")).toString();
        const QVariantList views = m_homeViews.value(accountId);
        if (!m_homeViews.contains(accountId)) {
            // 视图仍在途:先沿用该服现有行(缓存/上轮),等壳到位再换。
            for (const auto &old : m_homeRows)
                if (old.toMap().value(QStringLiteral("accountId")).toString() == accountId)
                    out.append(old);
            continue;
        }
        if (views.isEmpty())
            continue; // 该服视图失败/无毒:跳过,不显示(仅保留成功服)
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
                        it.insert(QStringLiteral("posterId"), serverPosterId(serverUrl, pid));
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
            QVariantMap row;
            row.insert(QStringLiteral("viewId"), viewId);
            row.insert(QStringLiteral("viewName"), viewName);
            row.insert(QStringLiteral("accountId"), accountId);
            row.insert(QStringLiteral("serverUrl"), serverUrl);
            row.insert(QStringLiteral("serverName"), serverName);
            row.insert(QStringLiteral("posterId"),
                       serverPosterId(serverUrl,
                                      vm.value(QStringLiteral("posterId")).toString()));
            // loading:新鲜未到位(占位/缓存回退);到位后 false。
            row.insert(QStringLiteral("items"), items);
            row.insert(QStringLiteral("loading"), !fresh);
            out.append(row);
        }
    }
    // 逐行增量更新模型(setRows 内部只对变化的行发 per-row 信号),
    // 渲染只重估变化行;homeRows 快照同步供缓存与语义比较。
    m_homeRows = out;
    m_homeRowsModel->setRows(out);
    if (allDone)
        saveHomeCache(); // 全部完成才缓存,保证缓存是完整可依赖集合
    emit homeRowsReady();
    if (allDone)
        finishHomeFetch();
}

// ---- 服务器文件夹(分类)----
// 纯视觉分组:不影响账号列表/首页聚合顺序,只决定服务器管理页的展示
// 归属。持久化于 QSettings 独立 key(accounts/folders),账号结构不动。

QVariantList AccountManager::folders() const
{
    QVariantList out;
    for (const auto &f : m_folders) {
        QVariantMap m;
        m.insert(QLatin1String("id"), f.id);
        m.insert(QLatin1String("name"), f.name);
        m.insert(QLatin1String("color"), f.color);
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
    const QStringList visual = visualAccountOrder(order);
    bool changed = visual.size() != m_accounts.size();
    if (!changed) {
        for (int i = 0; i < m_accounts.size(); ++i)
            if (m_accounts.at(i).id != visual.at(i)) {
                changed = true;
                break;
            }
    }
    if (changed) {
        QList<AccountInfo> reordered;
        reordered.reserve(visual.size());
        for (const auto &id : visual)
            reordered.append(*accountById(id));
        m_accounts = reordered;
    }
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
    persistLayoutOrder();
    if (foldersReordered) {
        saveFolders();
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

void AccountManager::loadLayoutOrder()
{
    // 旧数据无 key → 合成默认(全部文件夹 + 全部未分组账号按 accounts
    // 顺序),与升级前视觉一致;有 key → 读入经 setLayoutOrder 规范化
    // (过滤已删账号/文件夹、重复项、成员账号项,补全缺失),持久化结果。
    QVariantList order;
    const QString raw = m_settings.value(kLayoutOrderKey).toString();
    if (!raw.isEmpty()) {
        const QJsonArray arr = QJsonDocument::fromJson(raw.toUtf8()).array();
        for (const auto &v : arr) {
            const QJsonObject o = v.toObject();
            const QString type = o.value(QLatin1String("type")).toString();
            const QString id = o.value(QLatin1String("id")).toString();
            if (type == QLatin1String("folder") || type == QLatin1String("account"))
                order.append(makeLayoutEntry(type, id));
        }
    }
    setLayoutOrder(order);
}

void AccountManager::persistLayoutOrder()
{
    QJsonArray arr;
    for (const auto &v : m_layoutOrder) {
        const QVariantMap m = v.toMap();
        QJsonObject o;
        o.insert(QLatin1String("type"), m.value(QLatin1String("type")).toString());
        o.insert(QLatin1String("id"), m.value(QLatin1String("id")).toString());
        arr.append(o);
    }
    m_settings.setValue(kLayoutOrderKey,
                        QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact)));
    m_settings.sync();
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
    persistLayoutOrder();
    saveFolders();
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
        persistLayoutOrder();
        saveFolders();
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
    saveFolders();
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
    saveFolders();
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

void AccountManager::addAccountToFolder(const QString &folderId, const QString &accountId)
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
    f->accountIds.append(accountId);
    // 成员不占视觉位:从 layoutOrder 移除账号项,并按展平顺序重排
    // accounts(账号进文件夹块,首页聚合跟随视觉)。
    removeFromLayoutOrder(QLatin1String("account"), accountId);
    const bool acctChanged = reorderAccountsToVisual(m_layoutOrder);
    persistLayoutOrder();
    saveFolders();
    if (acctChanged) {
        reorderHomeRows();
        save();
        emit accountsChanged();
        emit homeRowsReady();
    }
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
        persistLayoutOrder();
        saveFolders();
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

void AccountManager::loadFolders()
{
    const QJsonArray arr =
        QJsonDocument::fromJson(m_settings.value(kFoldersKey).toString().toUtf8()).array();
    for (const auto &v : arr) {
        const QJsonObject o = v.toObject();
        FolderInfo f;
        f.id = o.value(QLatin1String("id")).toString();
        f.name = o.value(QLatin1String("name")).toString();
        f.color = o.value(QLatin1String("color")).toString();
        const QJsonArray ids = o.value(QLatin1String("accountIds")).toArray();
        for (const auto &id : ids) {
            const QString aid = id.toString();
            // 防御:引用已删除账号的成员记录直接丢弃。
            if (!accountById(aid) || f.accountIds.contains(aid))
                continue;
            f.accountIds.append(aid);
        }
        if (!f.id.isEmpty())
            m_folders.append(f);
    }
}

void AccountManager::saveFolders()
{
    QJsonArray arr;
    for (const auto &f : m_folders) {
        QJsonObject o;
        o.insert(QLatin1String("id"), f.id);
        o.insert(QLatin1String("name"), f.name);
        o.insert(QLatin1String("color"), f.color);
        QJsonArray ids;
        for (const auto &id : f.accountIds)
            ids.append(id);
        o.insert(QLatin1String("accountIds"), ids);
        arr.append(o);
    }
    m_settings.setValue(kFoldersKey, QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact)));
    m_settings.sync();
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
    const QString path = QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
                         + kHomeCacheFileName;
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return {};
    return QJsonDocument::fromJson(f.readAll()).array().toVariantList();
}

void AccountManager::saveHomeCache()
{
    if (m_homeRows.isEmpty())
        return;
    const QString path = QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
                         + kHomeCacheFileName;
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly)) {
        qWarning().noquote() << "AccountManager: 首页缓存写入失败" << path << f.errorString();
        return;
    }
    f.write(QJsonDocument(QJsonArray::fromVariantList(m_homeRows))
                .toJson(QJsonDocument::Compact));
}

QString AccountManager::serverPosterId(const QString &serverUrl, const QString &posterId)
{
    if (posterId.isEmpty())
        return QString();
    // 跨服务器海报 id:<encodeServerKey(serverUrl)>~<itemId>~<tag>,
    // 与 PosterProvider 的解析约定一致。
    return encodeServerKey(serverUrl) + QLatin1Char('~') + posterId;
}

QString AccountManager::encodeServerKey(const QString &serverUrl)
{
    // Base64URL(无填充):输出仅含字母数字与 - _,可安全放进 image:// URL。
    return QString::fromLatin1(serverUrl.toUtf8().toBase64(
        QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals));
}

// 图标图片落盘本地缓存(CacheLocation/account-icons/):文件名 = 内容 MD5
// (同图同文件,跨账号去重),后缀统一 .img(Qt Image 按内容解码)。返回
// file:// URL(QML Image.source 裸绝对路径会被 qrc 解析失败,须显式 file://),
// 写失败返回空。
QString AccountManager::writeIconCache(const QByteArray &imageData)
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
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
    QFile f(file);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qWarning().noquote() << "AccountManager: 图标缓存写入失败" << file << f.errorString();
        return QString();
    }
    if (f.write(imageData) != imageData.size()) {
        qWarning().noquote() << "AccountManager: 图标缓存写短" << file;
        f.close();
        f.remove();
        return QString();
    }
    f.close();
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
    // 视觉顺序同步:未分组账号项移除(成员账号不在序列中;folder.accountIds
    // 残留由 loadFolders 下次过滤,运行时 visualSequence 按卡映射跳过)。
    removeFromLayoutOrder(QLatin1String("account"), id);
    persistLayoutOrder();
    m_client->dropServerModels(serverUrl); // 清理该服浏览模型,防无界增长
    reorderHomeRows(); // 被删服的行一并移除,本地重排不重拉网络(见 moveAccount)
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
        a.name = name.trimmed();
        a.serverUrl = serverUrl.trimmed();
        a.userName = userName.trimmed();
        save();
        emit accountsChanged();
        return;
    }
}

void AccountManager::load()
{
    const QJsonArray arr =
        QJsonDocument::fromJson(m_settings.value(kAccountsKey).toString().toUtf8()).array();
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
        if (!a.id.isEmpty())
            m_accounts.append(a);
    }
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
        arr.append(o);
    }
    m_settings.setValue(kAccountsKey, QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact)));
    m_settings.sync();
    if (m_settings.status() != QSettings::NoError)
        qWarning() << "AccountManager: 账号配置写入失败" << int(m_settings.status());
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
