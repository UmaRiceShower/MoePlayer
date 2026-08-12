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
const QString kActiveKey = QStringLiteral("accounts/active");
const QString kServerNamesKey = kServerNamesKey;
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

    // 登录成功:若来自 addAccount(有 pending),保存账号并激活;手动登录不保存。
    connect(m_client, &EmbyClient::loginSucceeded, this, [this] {
        if (m_pending.isEmpty())
            return;
        AccountInfo acc;
        acc.id = m_pending.value(QStringLiteral("id")).toString();
        acc.name = m_pending.value(QStringLiteral("name")).toString();
        acc.serverUrl = m_pending.value(QStringLiteral("serverUrl")).toString();
        acc.userName = m_pending.value(QStringLiteral("userName")).toString();
        acc.rememberPassword = m_pending.value(QStringLiteral("rememberPassword")).toBool();
        acc.password = acc.rememberPassword
                           ? obfuscate(m_pending.value(QStringLiteral("password")).toString())
                           : QString();
        acc.token = m_client->accessToken();
        acc.userId = m_client->userId();
        acc.lastUsed = QDateTime::currentMSecsSinceEpoch();
        m_pending.clear();

        // 同服务器+用户已存在则更新,否则新增。
        auto it = std::find_if(m_accounts.begin(), m_accounts.end(),
                               [&acc](const AccountInfo &a) {
                                   return a.serverUrl == acc.serverUrl && a.userName == acc.userName;
                               });
        if (it != m_accounts.end())
            *it = acc;
        else
            m_accounts.append(acc);
        setActive(acc.id);
        save();
        emit accountsChanged();
        emit accountLoginFinished(true, QString());
    });

    // 登录/会话失败:带 pending 的 addAccount 或自动登录在途 → 通知失败。
    // autoLogin 的会话请求无论 401(token 失效)还是网络错误都视为失败,
    // 由 UI 回登录流程;authFailed 已单独处理 401,这里兜底其余错误。
    connect(m_client, &EmbyClient::errorOccurred, this, [this](const QString &message) {
        if (!m_pending.isEmpty()) {
            m_pending.clear();
            emit accountLoginFinished(false, message);
        }
        if (m_autoLoginInFlight) {
            m_autoLoginInFlight = false;
            emit autoLoginFinished(false);
        }
    });
    // 会话 401(autoLogin 的 configureSession 拉视图失败):token 失效。
    // 记住密码的账号尝试账密重登并写回新 token,成功则重建会话;
    // 无密码或重登失败才报 autoLoginFinished(false)。
    connect(m_client, &EmbyClient::authFailed, this, [this] {
        if (!m_autoLoginInFlight)
            return;
        m_autoLoginInFlight = false;
        const AccountInfo *a = accountById(m_activeId);
        if (a && a->rememberPassword && !deobfuscate(a->password).isEmpty()) {
            m_autoRetry = true;
            m_loggingInServers.insert(a->serverUrl);
            qInfo() << "Emby: token invalid, relogin on" << a->serverUrl;
            m_client->loginFor(a->serverUrl, a->userName, deobfuscate(a->password));
            return;
        }
        if (a) {
            m_invalidServers.insert(a->serverUrl);
            emit accountsChanged();
        }
        emit autoLoginFinished(false);
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
    // 自动登录场景重建会话,聚合场景重拉数据(缓存先展示)。
    connect(m_client, &EmbyClient::serverLoginFinished, this,
            [this](const QString &serverUrl, bool ok, const QString &token,
                   const QString &userId, const QString &userName) {
                m_loggingInServers.remove(serverUrl);
                const int idx = accountIndexByServer(serverUrl);
                if (idx < 0)
                    return;
                AccountInfo &a = m_accounts[idx];
                if (!ok) {
                    m_invalidServers.insert(serverUrl);
                    emit accountsChanged();
                    if (m_autoRetry) {
                        m_autoRetry = false;
                        emit autoLoginFinished(false);
                    }
                    return;
                }
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
                if (m_autoRetry) {
                    m_autoRetry = false;
                    applySession(a); // 新 token 重建活动会话
                    emit autoLoginFinished(true);
                }
                // token 已换:重拉各库数据(先展示缓存),恢复该服首页行。
                // 并行 fetchHomeRows 已因旧 token 401 把该服按空处理,必须刷新。
                fetchHomeRows(m_homeLimit);
            });

    // 首页聚合:跨服务器拉取结果归位,全部完成后组装并通知。
    connect(m_client, &EmbyClient::serverPublicInfoReceived, this,
            [this](const QString &serverUrl, const QString &name) {
                if (name.isEmpty() || m_serverNames.value(serverUrl) == name)
                    return;
                m_serverNames.insert(serverUrl, name);
                persistServerNames();
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
        m.insert(QStringLiteral("lastUsed"), a.lastUsed);
        // 确认 token 失效且重登失败的服务器为 false(UI 标红);未知/正常为 true。
        m.insert(QStringLiteral("tokenValid"), !m_invalidServers.contains(a.serverUrl));
        out.append(m);
    }
    return out;
}

QString AccountManager::activeAccountName() const
{
    for (const auto &a : m_accounts)
        if (a.id == m_activeId)
            return a.name;
    return QString();
}

bool AccountManager::hasAccounts() const
{
    return !m_accounts.isEmpty();
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
    m_client->setServerUrl(serverUrl.trimmed());
    m_client->login(userName.trimmed(), password);
    return true;
}

bool AccountManager::switchAccount(const QString &id)
{
    for (const auto &a : m_accounts) {
        if (a.id == id) {
            if (a.token.isEmpty()) {
                emit accountLoginFinished(false, QStringLiteral("账号未保存登录凭据"));
                return false;
            }
            applySession(a);
            emit accountLoginFinished(true, QString());
            return true;
        }
    }
    emit accountLoginFinished(false, QStringLiteral("账号不存在"));
    return false;
}

// ---------- 首页聚合(所有账号的媒体库,顺序即账号列表顺序) ----------

void AccountManager::fetchHomeRows(int perLibraryLimit)
{
    // 重叠重拉(排序/增删快速操作)时旧代次的回调可能仍在途,其归位索引已
    // 失效,须按代次丢弃;否则会污染本次聚合的视图与计数。
    ++m_homeGen;
    const int gen = m_homeGen;
    m_homeViews.clear();
    m_homeRowByKey.clear();
    m_homeAccountOrder.clear();
    m_homeLimit = qBound(1, perLibraryLimit, MoePlayer::kHomePerLibraryLimit);
    m_homePending = 0;
    // 先展示缓存(上次成功数据),网络刷新完成后再覆盖;无缓存则清空等待。
    m_homeRows.clear();
    loadHomeCache();
    emit homeRowsReady();

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
        emit homeRowsReady();
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
        for (const auto &v : views) {
            const QVariantMap vm = v.toMap();
            const QString key = QString::number(idx) + QLatin1Char('|')
                                + vm.value(QStringLiteral("id")).toString();
            QVariantMap row = m_homeRowByKey.value(key);
            if (row.isEmpty())
                continue;
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
    m_homeRows = out;
    saveHomeCache(); // 缓存本次成功数据,下次启动先展示
    emit homeRowsReady();
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
        save();
        emit accountsChanged();
        return;
    }
}

void AccountManager::moveAccountDown(const QString &id)
{
    for (int i = 0; i + 1 < m_accounts.size(); ++i) {
        if (m_accounts.at(i).id != id)
            continue;
        std::swap(m_accounts[i], m_accounts[i + 1]);
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
void AccountManager::loadHomeCache()
{
    const QString path = QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
                         + kHomeCacheFileName;
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return;
    m_homeRows = QJsonDocument::fromJson(f.readAll()).array().toVariantList();
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
    auto it = std::remove_if(m_accounts.begin(), m_accounts.end(),
                             [id](const AccountInfo &a) { return a.id == id; });
    if (it == m_accounts.end())
        return;
    m_accounts.erase(it, m_accounts.end());
    if (m_activeId == id) {
        m_activeId.clear();
        m_client->disconnectServer();
    }
    save();
    emit accountsChanged();
    emit activeAccountChanged();
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
        emit activeAccountChanged();
        return;
    }
}

bool AccountManager::autoLogin()
{
    if (m_accounts.isEmpty())
        return false;
    // 取最后使用的账号。
    auto best = std::max_element(m_accounts.begin(), m_accounts.end(),
                                 [](const AccountInfo &a, const AccountInfo &b) {
                                     return a.lastUsed < b.lastUsed;
                                 });
    if (best->token.isEmpty())
        return false;
    m_activeId = best->id;
    m_autoLoginInFlight = true;
    applySession(*best);
    save();
    return true;
}

QString AccountManager::passwordFor(const QString &id) const
{
    for (const auto &a : m_accounts)
        if (a.id == id && a.rememberPassword && !a.password.isEmpty())
            return deobfuscate(a.password);
    return QString();
}

void AccountManager::applySession(const AccountInfo &acc)
{
    m_client->configureSession(acc.serverUrl, acc.token, acc.userId, acc.userName);
}

void AccountManager::setActive(const QString &id)
{
    if (m_activeId == id)
        return;
    m_activeId = id;
    emit activeAccountChanged();
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
        a.lastUsed = o.value(QLatin1String("lastUsed")).toVariant().toLongLong();
        if (!a.id.isEmpty())
            m_accounts.append(a);
    }
    m_activeId = m_settings.value(kActiveKey).toString();
    // 激活账号被删除等情况下回退到空。
    if (!m_activeId.isEmpty()) {
        const bool exists = std::any_of(m_accounts.begin(), m_accounts.end(),
                                        [this](const AccountInfo &a) { return a.id == m_activeId; });
        if (!exists)
            m_activeId.clear();
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
        o.insert(QLatin1String("lastUsed"), a.lastUsed);
        arr.append(o);
    }
    m_settings.setValue(kAccountsKey, QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact)));
    m_settings.setValue(kActiveKey, m_activeId);
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
