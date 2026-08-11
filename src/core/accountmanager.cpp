#include "accountmanager.h"

#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QUuid>

#include <algorithm>

#include "embyclient.h"

namespace {
// QSettings 键。
const QString kAccountsKey = QStringLiteral("accounts/list");
const QString kActiveKey = QStringLiteral("accounts/active");
// 混淆用固定 key(仅做简单保护,不构成加密)。
const QByteArray kObfuscationKey = QByteArrayLiteral("MoePlayer-account-v1");
} // namespace

AccountManager::AccountManager(EmbyClient *client, QObject *parent)
    : QObject(parent)
    , m_client(client)
{
    load();

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

    // 登录/会话失败:带 pending 的 addAccount 或会话请求 401 → 通知失败。
    connect(m_client, &EmbyClient::errorOccurred, this, [this](const QString &message) {
        if (!m_pending.isEmpty()) {
            m_pending.clear();
            emit accountLoginFinished(false, message);
        }
        if (m_autoLoginInFlight && message.contains(QLatin1String("401"))) {
            m_autoLoginInFlight = false;
            emit autoLoginFinished(false);
        }
    });
    connect(m_client, &EmbyClient::authFailed, this, [this] {
        if (m_autoLoginInFlight) {
            m_autoLoginInFlight = false;
            emit autoLoginFinished(false);
        }
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
