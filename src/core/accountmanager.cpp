#include "accountmanager.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QUuid>

#include <algorithm>

#include "core/constants.h"
#include "core/embyclient.h"

namespace {
// QSettings 键。
const QString kAccountsKey = QStringLiteral("accounts/list");
const QString kServerNamesKey = QStringLiteral("accounts/serverNames");
// 混淆用固定 key(仅做简单保护,不构成加密)。
const QByteArray kObfuscationKey = QByteArrayLiteral("MoePlayer-account-v1");
// 首页聚合缓存文件名(CacheLocation 下)。
const QString kHomeCacheFileName = QStringLiteral("/home-rows.json");
} // namespace

AccountManager::AccountManager(EmbyClient *client, QObject *parent)
    : QObject(parent)
    , m_client(client)
{
    load();
    loadServerNames();

    // 登录成功:来自 addAccount(有 pending 且服务器匹配)则保存账号;
    // 否则(表单直连)由页面监听 loginSucceeded 自行浏览,不落账号。
    connect(m_client, &EmbyClient::loginSucceeded, this,
            [this](const QString &serverUrl, const QString &token, const QString &userId,
                   const QString &userName) {
                if (m_pending.isEmpty()
                    || m_pending.value(QStringLiteral("serverUrl")).toString().trimmed() != serverUrl.trimmed())
                    return;
                AccountInfo acc;
                acc.id = m_pending.value(QStringLiteral("id")).toString();
                acc.name = m_pending.value(QStringLiteral("name")).toString();
                acc.serverUrl = serverUrl.trimmed();
                acc.userName = userName.isEmpty()
                                   ? m_pending.value(QStringLiteral("userName")).toString()
                                   : userName;
                acc.rememberPassword = m_pending.value(QStringLiteral("rememberPassword")).toBool();
                acc.password = acc.rememberPassword
                                   ? obfuscate(m_pending.value(QStringLiteral("password")).toString())
                                   : QString();
                acc.token = token;
                acc.userId = userId;
                acc.lastUsed = QDateTime::currentMSecsSinceEpoch();
                m_pending.clear();

                // 同服务器+用户已存在则更新,否则新增。
                // 更新时名称留空视为"不改名":保留原账号名(新增时才用
                // 服务器端 ServerName 回填,见 serverPublicInfoReceived)。
                auto it = std::find_if(m_accounts.begin(), m_accounts.end(),
                                       [&acc](const AccountInfo &a) {
                                           return a.serverUrl == acc.serverUrl
                                                  && a.userName == acc.userName;
                                       });
                if (it != m_accounts.end()) {
                    if (acc.name.isEmpty())
                        acc.name = it->name;
                    acc.id = it->id; // 账号 id 是稳定标识,更新不换
                    *it = acc;
                } else {
                    m_accounts.append(acc);
                }
                save();
                emit accountsChanged();
                emit accountLoginFinished(true, QString());
                // 名称留空:登录成功后再拉 /System/Info/Public,用服务器端
                // ServerName 回填账号名(见 serverPublicInfoReceived)。
                if (acc.name.isEmpty())
                    m_client->fetchServerPublicInfo(acc.serverUrl);
                // 浏览器式解析服务器图标:仅添加/重新添加时拉取(用户主动
                // 操作,图标可能已更新),此后不再重复请求。
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
                emit accountLoginFinished(false, msg);
            });

    // 跨服务器请求失败:401 且账号记住密码 → 尝试账密重登(token 刷新);
    // 401 且无密码 → 标失效;其余为网络错误,数据已按空处理,不标红。
    connect(m_client, &EmbyClient::serverRequestFailed, this,
            [this](const QString &serverUrl, const QString &message) {
                if (m_loggingInServers.contains(serverUrl))
                    return; // 登录请求自身的失败,由 serverLoginFinished 处理
                const int idx = accountIndexByServer(serverUrl);
                if (idx < 0 || !message.contains(QLatin1String("401")))
                    return;
                if (m_invalidServers.contains(serverUrl))
                    return; // 已确认失效(重登失败过),不再重复尝试,避免循环
                const AccountInfo &a = m_accounts.at(idx);
                if (a.rememberPassword && !deobfuscate(a.password).isEmpty()) {
                    m_loggingInServers.insert(serverUrl);
                    m_client->loginFor(serverUrl, a.userName, deobfuscate(a.password));
                } else {
                    m_invalidServers.insert(serverUrl);
                    emit accountsChanged();
                }
            });
    // 账密重登结果:成功写回新 token(持久化)并解标失效;
    // 之后重拉各库数据(先展示缓存),恢复该服首页行。
    connect(m_client, &EmbyClient::serverLoginFinished, this,
            [this](const QString &serverUrl, bool ok, const QString &token,
                   const QString &userId, const QString &userName) {
                m_loggingInServers.remove(serverUrl);
                const int idx = accountIndexByServer(serverUrl);
                if (idx >= 0) {
                    AccountInfo &a = m_accounts[idx];
                    if (!ok) {
                        m_invalidServers.insert(serverUrl);
                        emit accountsChanged();
                    } else {
                        qInfo() << "Emby: relogin ok on" << serverUrl;
                        a.token = token;
                        if (!userId.isEmpty())
                            a.userId = userId;
                        if (!userName.isEmpty())
                            a.userName = userName;
                        a.lastUsed = QDateTime::currentMSecsSinceEpoch();
                        m_invalidServers.remove(serverUrl);
                        save();
                        emit accountsChanged();
                    }
                }
                // token 校验/重登风暴结束(无账号仍在重登)后一次性重拉首页
                // 数据:避免每台重登完成就 fetch 一次——数据逐步恢复会让
                // 首页反复整体重建,Qt 引擎在 delegate 销毁期求值,打印
                // "QQmlVMEMetaObject: Internal error" 噪音。
                if (m_loggingInServers.isEmpty())
                    fetchHomeRows(m_homeLimit);
            });

    // 浏览器式图标解析结果(仅添加服务器时拉取):写入该服务器账号的
    // serverIcon 字段(持久化)。解析失败(空)静默:不写、不记录、不重试,
    // 卡片回退名称首字。
    connect(m_client, &EmbyClient::serverIconReceived, this,
            [this](const QString &serverUrl, const QString &iconUrl) {
                if (iconUrl.isEmpty())
                    return;
                const int idx = accountIndexByServer(serverUrl);
                if (idx < 0)
                    return;
                AccountInfo &a = m_accounts[idx];
                if (a.serverIcon == iconUrl)
                    return;
                a.serverIcon = iconUrl;
                save();
                emit accountsChanged();
            });

    // 首页聚合:跨服务器拉取结果归位,全部完成后组装并通知;
    // 同时服务"添加服务器未填名称"场景:登录成功回填 ServerName 到账号名。
    connect(m_client, &EmbyClient::serverPublicInfoReceived, this,
            [this](const QString &serverUrl, const QString &name) {
                if (name.isEmpty())
                    return;
                if (m_serverNames.value(serverUrl) != name) {
                    m_serverNames.insert(serverUrl, name);
                    persistServerNames();
                }
                // 添加服务器时名称留空:用服务器端 ServerName 回填账号名。
                const int idx = accountIndexByServer(serverUrl);
                if (idx >= 0 && m_accounts[idx].name.isEmpty()) {
                    m_accounts[idx].name = name;
                    save();
                    emit accountsChanged();
                }
            });
    connect(m_client, &EmbyClient::serverViewsReceived, this,
            [this](const QString &serverUrl, const QVariantList &views) {
                const int idx = accountIndexByServer(serverUrl);
                if (idx < 0 || m_homeReqGen.value(idx) != m_homeGen)
                    return; // 无对应账号或属过期代次,丢弃
                if (m_homeViews.contains(idx))
                    return; // 本代已处理(旧代残留同数据回调),避免重复计数/发请求
                m_homeViews.insert(idx, views);
                --m_homePending;
                const AccountInfo &a = m_accounts.at(idx);
                for (const auto &v : views) {
                    ++m_homePending; // 每库一个条目请求
                    m_client->fetchServerItems(serverUrl, a.token, a.userId,
                                               v.toMap().value(QStringLiteral("id")).toString(),
                                               m_homeLimit);
                }
                maybeAssembleHomeRows();
            });
    connect(m_client, &EmbyClient::serverItemsReceived, this,
            [this](const QString &serverUrl, const QString &viewId, const QVariantList &items) {
                const int idx = accountIndexByServer(serverUrl);
                if (idx < 0 || m_homeReqGen.value(idx) != m_homeGen)
                    return; // 无对应账号或属过期代次,丢弃
                const QString key = QString::number(idx) + QLatin1Char('|') + viewId;
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

QVariantList AccountManager::accounts() const
{
    QVariantList out;
    for (const auto &a : m_accounts) {
        QVariantMap m;
        m.insert(QStringLiteral("id"), a.id);
        m.insert(QStringLiteral("name"), a.name);
        m.insert(QStringLiteral("serverUrl"), a.serverUrl);
        m.insert(QStringLiteral("userName"), a.userName);
        m.insert(QStringLiteral("rememberPassword"), a.rememberPassword);
        m.insert(QStringLiteral("icon"), a.icon);
        m.insert(QStringLiteral("serverIcon"), a.serverIcon);
        m.insert(QStringLiteral("lastUsed"), a.lastUsed);
        // 确认 token 失效且重登失败的服务器为 false(UI 标红);未知/正常为 true。
        m.insert(QStringLiteral("tokenValid"), !m_invalidServers.contains(a.serverUrl));
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
    for (const auto &a : m_accounts) {
        if (a.serverUrl == url && !a.token.isEmpty()) {
            QVariantMap m;
            m.insert(QStringLiteral("token"), a.token);
            m.insert(QStringLiteral("userId"), a.userId);
            return m;
        }
    }
    return QVariantMap();
}

// 启动校验:对所有有 token 的账号发轻量认证请求(/System/Info)。
// 401 经 serverRequestFailed 回到这里 → 记住密码的账号自动账密重登,
// 无密码的标失效(UI 红);网络错误/超时不算失效(不打扰用户)。
void AccountManager::validateTokens()
{
    for (const auto &a : m_accounts)
        if (!a.token.isEmpty())
            m_client->validateToken(a.serverUrl, a.token, a.userId);
    // 不在此处拉取服务器图标:图标只在添加服务器时解析(见
    // loginSucceeded 回调),后续用缓存/失败记忆,避免每次启动重复请求。
}

bool AccountManager::addAccount(const QString &name, const QString &serverUrl,
                                const QString &userName, const QString &password,
                                bool rememberPassword)
{
    if (serverUrl.trimmed().isEmpty() || userName.trimmed().isEmpty())
        return false;
    m_pending = QVariantMap{
        { QStringLiteral("id"), QUuid::createUuid().toString(QUuid::WithoutBraces) },
        { QStringLiteral("name"), name.trimmed() },
        { QStringLiteral("serverUrl"), serverUrl.trimmed() },
        { QStringLiteral("userName"), userName.trimmed() },
        { QStringLiteral("password"), password },
        { QStringLiteral("rememberPassword"), rememberPassword },
    };
    m_client->login(serverUrl.trimmed(), userName.trimmed(), password);
    return true;
}

// ---------- 首页聚合(所有账号的媒体库,顺序即账号列表顺序) ----------
//TODO:逐媒体库拉取并刷新
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
    // 重叠重拉(排序/增删快速操作)时旧代次的回调可能仍在途,其归位索引已
    // 失效,须按代次丢弃;否则会污染本次聚合的视图与计数。
    ++m_homeGen;
    const int gen = m_homeGen;
    m_homeViews.clear();
    m_homeRowByKey.clear();
    m_homeAccountOrder.clear();
    m_homePending = 0;
    // 先展示缓存(上次成功数据),网络刷新完成后再覆盖;无缓存则清空等待。
    // 缓存与当前展示相同则不 emit(避免无意义重建:重登/重复拉取常返回
    // 相同数据,Home 行整体重建会触发 Qt 引擎在 delegate 销毁期的内部
    // 警告 "QQmlVMEMetaObject: Internal error ... invalid context")。
    const QVariantList cached = loadHomeCache();
    if (!sameHomeRows(m_homeRows, cached)) {
        m_homeRows = cached;
        emit homeRowsReady();
    }

    for (int i = 0; i < m_accounts.size(); ++i) {
        const AccountInfo &a = m_accounts.at(i);
        if (a.token.isEmpty())
            continue; // 无凭据的账号跳过,不参与聚合
        QVariantMap order;
        order.insert(QStringLiteral("index"), i);
        order.insert(QStringLiteral("id"), a.id);
        order.insert(QStringLiteral("serverUrl"), a.serverUrl);
        order.insert(QStringLiteral("name"), a.name);
        m_homeAccountOrder.append(order);
        m_homeReqGen.insert(i, gen);
        ++m_homePending; // 该服视图请求
        m_client->fetchServerPublicInfo(a.serverUrl);
        m_client->fetchServerViews(a.serverUrl, a.token, a.userId);
    }
    if (m_homePending == 0)
        finishHomeFetch();
}

// 结束本轮聚合:释放串行标记;飞行中排队的触发(账号状态已变)重跑一次。
void AccountManager::finishHomeFetch()
{
    m_homeFetchActive = false;
    if (m_homeFetchQueued) {
        m_homeFetchQueued = false;
        fetchHomeRows(m_homeLimit);
    }
}

// 首页聚合行"语义等价"比较:忽略易变字段(posterId 的 tag/serverName
// 补全时序等),只比账号归属、视图与条目身份/名称——重登/重复拉取返回
// 的微差(如 serverName 拉取时序、items 字段细节)不应触发无意义重建。
bool AccountManager::sameHomeRows(const QVariantList &a, const QVariantList &b)
{
    if (a.size() != b.size())
        return false;
    for (int i = 0; i < a.size(); ++i) {
        const QVariantMap ma = a.at(i).toMap();
        const QVariantMap mb = b.at(i).toMap();
        if (ma.value(QStringLiteral("accountId")) != mb.value(QStringLiteral("accountId"))
            || ma.value(QStringLiteral("viewId")) != mb.value(QStringLiteral("viewId"))
            || ma.value(QStringLiteral("viewName")) != mb.value(QStringLiteral("viewName")))
            return false;
        // items 按 id 集合比较(忽略顺序与名称细节:Emby 返回顺序可能
        // 波动,名称变化不属结构变化,不触发重建)。
        const QVariantList ia = ma.value(QStringLiteral("items")).toList();
        const QVariantList ib = mb.value(QStringLiteral("items")).toList();
        if (ia.size() != ib.size())
            return false;
        QSet<QString> idsA, idsB;
        for (const auto &it : ia)
            idsA.insert(it.toMap().value(QStringLiteral("id")).toString());
        for (const auto &it : ib)
            idsB.insert(it.toMap().value(QStringLiteral("id")).toString());
        if (idsA != idsB)
            return false;
    }
    return true;
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
}

void AccountManager::maybeAssembleHomeRows()
{
    if (m_homePending > 0)
        return;
    QVariantList out;
    for (const auto &ord : m_homeAccountOrder) {
        const QVariantMap om = ord.toMap();
        const int idx = om.value(QStringLiteral("index")).toInt();
        const QString serverUrl = om.value(QStringLiteral("serverUrl")).toString();
        // 服务器显示名:用户填的账号名优先,未填(名称为空)才用拉取的
        // ServerName;两者皆空时留空,前端仅显示媒体库名。
        QString serverName = om.value(QStringLiteral("name")).toString();
        if (serverName.isEmpty())
            serverName = m_serverNames.value(serverUrl);
        const QVariantList views = m_homeViews.value(idx);
        if (views.isEmpty()) {
            // 该服本次无数据(401/token 失效/网络失败):沿用上次聚合该服的
            // 行,避免重登期间数据抖动导致首页反复重建(Qt 引擎噪音)。
            for (const auto &old : m_homeRows) {
                if (old.toMap().value(QStringLiteral("serverUrl")).toString() == serverUrl)
                    out.append(old);
            }
            continue;
        }
        for (const auto &v : views) {
            const QVariantMap vm = v.toMap();
            const QString key = QString::number(idx) + QLatin1Char('|')
                                + vm.value(QStringLiteral("id")).toString();
            QVariantMap row = m_homeRowByKey.value(key);
            if (row.isEmpty()) {
                // 该库条目拉取失败(401):沿用上次该库的行(同服同库)。
                for (const auto &old : m_homeRows) {
                    const QVariantMap om = old.toMap();
                    if (om.value(QStringLiteral("serverUrl")).toString() == serverUrl
                        && om.value(QStringLiteral("viewId")).toString()
                               == vm.value(QStringLiteral("id")).toString()) {
                        row = om;
                        break;
                    }
                }
                if (row.isEmpty())
                    continue;
            }
            row.insert(QStringLiteral("viewName"), vm.value(QStringLiteral("name")));
            row.insert(QStringLiteral("accountId"), om.value(QStringLiteral("id")));
            row.insert(QStringLiteral("serverUrl"), serverUrl);
            row.insert(QStringLiteral("serverName"), serverName);
            row.insert(QStringLiteral("posterId"),
                       serverPosterId(serverUrl,
                                      vm.value(QStringLiteral("posterId")).toString()));
            // 条目海报同样加服务器前缀,否则渲染时按活动会话请求到错误的服务器。
            QVariantList items = row.value(QStringLiteral("items")).toList();
            for (int i = 0; i < items.size(); ++i) {
                QVariantMap it = items.at(i).toMap();
                const QString pid = it.value(QStringLiteral("posterId")).toString();
                if (!pid.isEmpty())
                    it.insert(QStringLiteral("posterId"), serverPosterId(serverUrl, pid));
                items[i] = it;
            }
            row.insert(QStringLiteral("items"), items);
            out.append(row);
        }
    }
    // 与当前展示语义相同则不重建(重登/重复拉取数据常不变;重建触发 Home
    // 行 delegate 销毁/孵化,连续重建会让 Qt 引擎在失效 context 上求值,
    // 打印 "QQmlVMEMetaObject: Internal error" 警告)。
    if (sameHomeRows(m_homeRows, out)) {
        finishHomeFetch();
        return;
    }
    m_homeRows = out;
    saveHomeCache(); // 缓存本次成功数据,下次启动先展示
    emit homeRowsReady();
    finishHomeFetch();
}

QString AccountManager::tokenForServer(const QString &serverUrl) const
{
    for (const auto &a : m_accounts)
        if (a.serverUrl == serverUrl && !a.token.isEmpty())
            return a.token;
    return QString();
}

void AccountManager::moveAccountUp(const QString &id)
{
    for (int i = 1; i < m_accounts.size(); ++i) {
        if (m_accounts.at(i).id != id)
            continue;
        std::swap(m_accounts[i], m_accounts[i - 1]);
        reorderHomeRows(); // 本地重排,不重拉网络(见 moveAccount)
        save();
        emit accountsChanged();
        emit homeRowsReady();
        return;
    }
}

void AccountManager::moveAccountDown(const QString &id)
{
    for (int i = 0; i + 1 < m_accounts.size(); ++i) {
        if (m_accounts.at(i).id != id)
            continue;
        std::swap(m_accounts[i], m_accounts[i + 1]);
        reorderHomeRows(); // 本地重排,不重拉网络(见 moveAccount)
        save();
        emit accountsChanged();
        emit homeRowsReady();
        return;
    }
}

// 拖动排序:从当前位置移除后插入到 toIndex(稳定移动,其余账号顺移)。
// 与 moveAccountUp/Down 的相邻交换不同,拖动可跨任意距离。
void AccountManager::moveAccount(const QString &id, int toIndex)
{
    const int n = m_accounts.size();
    if (n < 2)
        return;
    toIndex = qBound(0, toIndex, n - 1);
    for (int i = 0; i < n; ++i) {
        if (m_accounts.at(i).id != id)
            continue;
        if (i == toIndex)
            return;
        const AccountInfo a = m_accounts.takeAt(i);
        m_accounts.insert(toIndex, a);
        // 首页聚合行按新账号顺序本地重排:拖拽只改顺序,数据未变,不
        // 重拉网络——否则会撞上启动重登中的 token 失效,401 触发连锁
        // 重登,并导致首页反复重建。
        reorderHomeRows();
        save();
        emit accountsChanged();
        emit homeRowsReady();
        return;
    }
}

// 设置图标即持久化(conf 落盘 + UI 通知),用户无需额外保存。
void AccountManager::setAccountIcon(const QString &id, const QString &icon)
{
    for (auto &a : m_accounts) {
        if (a.id != id)
            continue;
        if (a.icon == icon)
            return;
        a.icon = icon.trimmed();
        save();
        emit accountsChanged();
        return;
    }
}

int AccountManager::accountIndexByServer(const QString &serverUrl) const
{
    for (int i = 0; i < m_accounts.size(); ++i)
        if (m_accounts.at(i).serverUrl == serverUrl)
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
    if (!f.open(QIODevice::WriteOnly))
        return;
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

QString AccountManager::decodeServerKey(const QString &key)
{
    return QString::fromUtf8(QByteArray::fromBase64(key.toLatin1(),
                                                    QByteArray::Base64UrlEncoding));
}

void AccountManager::loadServerNames()
{
    const QJsonObject o = QJsonDocument::fromJson(
        m_settings.value(kServerNamesKey).toString().toUtf8()).object();
    for (auto it = o.begin(); it != o.end(); ++it)
        m_serverNames.insert(it.key(), it.value().toString());
}

void AccountManager::persistServerNames()
{
    QJsonObject o;
    for (auto it = m_serverNames.constBegin(); it != m_serverNames.constEnd(); ++it)
        o.insert(it.key(), it.value());
    m_settings.setValue(kServerNamesKey,
                        QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact)));
    m_settings.sync();
}

void AccountManager::removeAccount(const QString &id)
{
    // 先向服务器发送登出信号(/Sessions/Logout,官方 API),结果忽略
    // (部分 Emby 服务器未实现该端点);随后删除本地数据。登出请求
    // 已携带 token 发出,删除不影响其完成。
    for (const auto &a : m_accounts) {
        if (a.id == id && !a.token.isEmpty()) {
            m_client->logout(a.serverUrl, a.token, a.userId);
            break;
        }
    }
    auto it = std::remove_if(m_accounts.begin(), m_accounts.end(),
                             [id](const AccountInfo &a) { return a.id == id; });
    if (it == m_accounts.end())
        return;
    const QString serverUrl = it->serverUrl;
    m_accounts.erase(it, m_accounts.end());
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

QString AccountManager::passwordFor(const QString &id) const
{
    for (const auto &a : m_accounts)
        if (a.id == id && a.rememberPassword && !a.password.isEmpty())
            return deobfuscate(a.password);
    return QString();
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
        a.rememberPassword = o.value(QLatin1String("rememberPassword")).toBool();
        a.password = o.value(QLatin1String("password")).toString();
        a.icon = o.value(QLatin1String("icon")).toString();
        a.serverIcon = o.value(QLatin1String("serverIcon")).toString();
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
        o.insert(QLatin1String("rememberPassword"), a.rememberPassword);
        o.insert(QLatin1String("password"), a.password);
        o.insert(QLatin1String("icon"), a.icon);
        o.insert(QLatin1String("serverIcon"), a.serverIcon);
        o.insert(QLatin1String("lastUsed"), a.lastUsed);
        arr.append(o);
    }
    m_settings.setValue(kAccountsKey, QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact)));
    m_settings.sync();
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
