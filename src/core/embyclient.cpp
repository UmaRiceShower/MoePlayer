#include "embyclient.h"

#include "core/accountmanager.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QNetworkProxy>
#include <QUrl>
#include <QUrlQuery>
#include <QUuid>
#include <QDebug>
#include <QCoreApplication>
#include <QDateTime>
#include <QRegularExpression>

namespace {

// 构造 X-Emby-Authorization 请求头,格式为官方认证规范:Emby UserId=..., Client=... 等。
QString deviceId()
{
    static const QString id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    return id;
}

QStringList requiredHeaders(const QJsonObject &source)
{
    QStringList out;
    const QJsonArray arr = source.value(QLatin1String("RequiredHttpHeaders")).toArray();
    for (const auto &v : arr) {
        const QJsonObject h = v.toObject();
        const QString n = h.value(QLatin1String("Name")).toString();
        const QString val = h.value(QLatin1String("Value")).toString();
        if (!n.isEmpty())
            out << (n + QLatin1String(": ") + val);
    }
    return out;
}

// 解析首页条目(库行 / 服务器建议共用):字段与 QML HeroCard、行卡片消费
// 一致(id/name/type/posterId/backdropId/positionTicks/played/year/runtimeTicks/
// rating/favorite/unplayedCount);posterId 不带服务器前缀(调用方补),
// backdropId 直接带前缀(请求时即知服务器)。
QVariantMap parseHomeItem(const QJsonObject &o, const QString &serverUrl)
{
    const QString tag = o.value(QLatin1String("ImageTags"))
                            .toObject().value(QLatin1String("Primary")).toString();
    const QJsonObject ud = o.value(QLatin1String("UserData")).toObject();
    QVariantMap m;
    m.insert(QStringLiteral("id"), o.value(QLatin1String("Id")).toString());
    m.insert(QStringLiteral("name"), o.value(QLatin1String("Name")).toString());
    m.insert(QStringLiteral("type"), o.value(QLatin1String("Type")).toString());
    m.insert(QStringLiteral("posterId"),
             tag.isEmpty() ? QString()
                           : o.value(QLatin1String("Id")).toString()
                                 + QLatin1Char('~') + tag);
    // Hero 背景:剧集/电影条目直接用条目 id 请求 Backdrop 端点(tag 留空,
    // 服务器返回默认背景)。部分服务器列表路由不回 BackdropImageTags,
    // 但 /Items/{id}/Images/Backdrop 端点仍可取到;Series/Season 取自身,
    // Episode 取父级剧集(ParentBackdropItemId)。提供器格式
    // <encodeServerKey(serverUrl)>~<itemId>~<tag>~Backdrop,tag 空则用默认背景。
    const QString prefix = AccountManager::encodeServerKey(serverUrl);
    const QString iid = o.value(QLatin1String("Id")).toString();
    const QJsonArray btags = o.value(QLatin1String("BackdropImageTags")).toArray();
    const QString btag = btags.isEmpty() ? QString() : btags.first().toString();
    const QString type = o.value(QLatin1String("Type")).toString();
    const QJsonArray pbtags = o.value(QLatin1String("ParentBackdropImageTags")).toArray();
    const QString pbid = o.value(QLatin1String("ParentBackdropItemId")).toString();
    if (type == QLatin1String("Series") || type == QLatin1String("Movie")
        || type == QLatin1String("Season") || type == QLatin1String("MusicVideo")
        || !btags.isEmpty()) {
        // 自身/系列级条目:直接用自身 id + Backdrop 端点。
        m.insert(QStringLiteral("backdropId"), prefix + QLatin1Char('~') + iid
                 + QLatin1Char('~') + btag + QStringLiteral("~Backdrop"));
    } else if (!pbid.isEmpty()) {
        // 分集:用父级剧集 id + Backdrop 端点。
        const QString ptag = pbtags.isEmpty() ? QString() : pbtags.first().toString();
        m.insert(QStringLiteral("backdropId"), prefix + QLatin1Char('~') + pbid
                 + QLatin1Char('~') + ptag + QStringLiteral("~Backdrop"));
    }
    m.insert(QStringLiteral("positionTicks"), ud.value(QLatin1String("PlaybackPositionTicks")).toDouble(0));
    m.insert(QStringLiteral("played"), ud.value(QLatin1String("Played")).toBool(false));
    m.insert(QStringLiteral("unplayedCount"), ud.value(QLatin1String("UnplayedItemCount")).toInt(0));
    m.insert(QStringLiteral("rating"), o.value(QLatin1String("CommunityRating")).toDouble(0));
    m.insert(QStringLiteral("year"), o.value(QLatin1String("ProductionYear")).toInt(0));
    m.insert(QStringLiteral("runtimeTicks"), o.value(QLatin1String("RunTimeTicks")).toDouble(0));
    m.insert(QStringLiteral("favorite"), ud.value(QLatin1String("IsFavorite")).toBool(false));
    return m;
}

// Emby 时间戳(ISO 8601)换算毫秒 epoch;空值/解析失败返回 0(未知)。
// 服务端实测小数秒为 7 位,Qt 6.11 的 ISODateWithMs 可直接解析并截断到毫秒
// (实测 7 位/3 位/无小数均有效),无需预处理。
qint64 parseEmbyDateMs(const QString &iso)
{
    if (iso.isEmpty())
        return 0;
    const QDateTime dt = QDateTime::fromString(iso, Qt::ISODateWithMs);
    return dt.isValid() ? dt.toMSecsSinceEpoch() : 0;
}

// 解析播放历史条目:在首页条目字段(海报/背景键、进度、已看等,卡片可直接
// 消费)之上补剧集定位、进度百分比与服务器给出的顺序 seq。播放次数与上次
// 播放时间不在列表端点返回,由 fetchItemUserData 补全。
QVariantMap parseHistoryItem(const QJsonObject &o, const QString &serverUrl, int seq)
{
    QVariantMap m = parseHomeItem(o, serverUrl);
    const QJsonObject ud = o.value(QLatin1String("UserData")).toObject();
    m.insert(QStringLiteral("seriesId"), o.value(QLatin1String("SeriesId")).toString());
    m.insert(QStringLiteral("seriesName"), o.value(QLatin1String("SeriesName")).toString());
    m.insert(QStringLiteral("seasonNo"), o.value(QLatin1String("ParentIndexNumber")).toInt(0));
    m.insert(QStringLiteral("episodeNo"), o.value(QLatin1String("IndexNumber")).toInt(0));
    // 剧集海报键(网格视图的分集用 2:3 剧海报,分集自身图是 16:9 剧照):
    // 与 posterId 一样不带服务器前缀,由调用方补(见 historyItemsWithPosterIds)。
    const QString seriesId = m.value(QStringLiteral("seriesId")).toString();
    const QString seriesTag = o.value(QLatin1String("SeriesPrimaryImageTag")).toString();
    m.insert(QStringLiteral("seriesPosterId"),
             (seriesId.isEmpty() || seriesTag.isEmpty())
                 ? QString()
                 : seriesId + QLatin1Char('~') + seriesTag);
    m.insert(QStringLiteral("playedPercentage"),
             ud.value(QLatin1String("PlayedPercentage")).toDouble(0));
    m.insert(QStringLiteral("seq"), seq);
    return m;
}

} // namespace

EmbyClient::EmbyClient(QObject *parent)
    : QObject(parent)
{
    // 默认直连(配置未接线时);main.cpp 按 ConfigManager.proxy 覆盖。
    // Qt 在 Linux 上不识别 no_proxy,且网络管理器会在构造时读取环境代理,
    // 故始终显式指定,避免意外走系统代理(Emby 多为局域网服务)。
    m_nam.setProxy(QNetworkProxy::NoProxy);
    m_nam.setTransferTimeout(MoePlayer::kNetworkTimeoutMs);
    // 后台连接池同样显式直连(见 m_bgNam 注释),超时与前台一致。
    m_bgNam.setProxy(QNetworkProxy::NoProxy);
    m_bgNam.setTransferTimeout(MoePlayer::kNetworkTimeoutMs);
}

void EmbyClient::setProxy(const QNetworkProxy &proxy)
{
    m_nam.setProxy(proxy); // 对后续新请求生效
    m_bgNam.setProxy(proxy); // 后台连接池同步
}

QString EmbyClient::authHeaderFor(const QString &userId, const QString &token) const
{
    QString h = QStringLiteral("Emby UserId=\"%1\", Client=\"%4\", Device=\"Desktop\", "
                               "DeviceId=\"%2\", Version=\"%3\"")
                    .arg(userId, deviceId(), QCoreApplication::applicationVersion(),
                         MoePlayer::kAppName);
    if (!token.isEmpty())
        h += QStringLiteral(", Token=\"%1\"").arg(token);
    return h;
}

namespace {
// 播放地址补全 server 前缀(相对路径 → 绝对;已是 http 原样)。
// 播放历史列表查询(首页批次与"加载更多"分页共用):startIndex<=0 不传该参数
// (与首页批次请求逐字一致)。服务器按 LastPlayedDate 倒序;列表端点不返回该字段,
// 但顺序有效(时间与次数由 fetchItemUserData 逐条补全)。
QUrlQuery historyListQuery(int startIndex, int limit, bool playedOnly)
{
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("Recursive"), QStringLiteral("true"));
    // 播放记录以影片与分集为单位(剧集/季自身的最近播放时间来自其分集,
    // 一并返回会重复)。
    q.addQueryItem(QStringLiteral("IncludeItemTypes"), QStringLiteral("Movie,Episode"));
    q.addQueryItem(QStringLiteral("SortBy"), QStringLiteral("DatePlayed"));
    q.addQueryItem(QStringLiteral("SortOrder"), QStringLiteral("Descending"));
    q.addQueryItem(QStringLiteral("Fields"),
                   QStringLiteral("PrimaryImageAspectRatio,ProductionYear,RunTimeTicks,"
                                  "SeriesId,SeriesName,IndexNumber,ParentIndexNumber"));
    // 分页("加载更多")加服务器端过滤:实测服务器把"播过的"排在前面、从未播放的排在
    // 其后,不过滤时第 60 条之后整页都是未播条目,翻页毫无意义。刻意只用 IsPlayed
    // (不用 IsResumable 组合:实测逗号组合是"同时满足"语义,会把结果缩到几条)。
    if (playedOnly)
        q.addQueryItem(QStringLiteral("Filters"), QStringLiteral("IsPlayed"));
    if (startIndex > 0)
        q.addQueryItem(QStringLiteral("StartIndex"), QString::number(startIndex));
    q.addQueryItem(QStringLiteral("Limit"),
                   QString::number(qBound(1, limit, MoePlayer::kMaxPageSize)));
    return q;
}

QString absolutePlaybackUrl(const QString &serverKey, QString p)
{
    if (p.startsWith(QLatin1String("http")))
        return p;
    return serverKey + (p.startsWith(QLatin1Char('/')) ? p : QLatin1Char('/') + p);
}
// 播放 URL 附带 api_key(mpv 拉流免自定义请求头;已有则不再追加)。
QString withApiKeyParam(const QString &token, QString u)
{
    if (!token.isEmpty() && !u.contains(MoePlayer::kApiKeyParam + QLatin1Char('=')))
        u += (u.contains(QLatin1Char('?')) ? QLatin1Char('&') : QLatin1Char('?'))
             + MoePlayer::kApiKeyParam + QLatin1Char('=') + token;
    return u;
}
} // namespace

void EmbyClient::fillItems(MediaItemModel *model, const QJsonDocument &doc,
                             bool append, bool withPosters)
{
    const QJsonArray items = doc.object().value(QLatin1String("Items")).toArray();
    if (append)
        model->appendItems(items, withPosters);
    else
        model->setItems(items, withPosters);
}

QString EmbyClient::userPath(const QString &userId, const QString &rest)
{
    return QStringLiteral("/Users/%1%2").arg(userId, rest);
}

QNetworkRequest EmbyClient::makeRequest(const QString &serverUrl, const QString &token,
                                        const QString &userId, const QString &path,
                                        bool json) const
{
    QNetworkRequest req(QUrl(serverUrl.trimmed() + path));
    // 统一 UA(软件名/版本号),不用 Qt 默认 UA。
    req.setRawHeader(MoePlayer::kHeaderUserAgent, MoePlayer::userAgent().toUtf8());
    req.setRawHeader(MoePlayer::kHeaderAuth, authHeaderFor(userId, token).toUtf8());
    // 官方文档(dev.emby.media User-Authentication)规定登录后的 AccessToken
    // 用 X-Emby-Token 头发送,同时保留 X-Emby-Authorization 以兼容按该头认证的服务器。
    if (!token.isEmpty())
        req.setRawHeader(MoePlayer::kHeaderToken, token.toUtf8());
    if (json)
        req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    req.setTransferTimeout(MoePlayer::kNetworkTimeoutMs);
    // h1:保守选择——h2 多路复用会把请求命运绑到共享连接上;h1 每请求
    // 独立连接,故障域天然隔离(低风险防御,复用收益本场景很小)
    req.setAttribute(QNetworkRequest::Http2AllowedAttribute, false);
    return req;
}

void EmbyClient::get(const QString &serverUrl, const QString &token, const QString &userId,
                     const QString &path, std::function<void(const QJsonDocument &)> onOk,
                     std::function<void()> onFail, const QString &what, bool background)
{
    QNetworkAccessManager &nam = background ? m_bgNam : m_nam;
    QNetworkReply *reply = nam.get(makeRequest(serverUrl, token, userId, path, false));
    connect(reply, &QNetworkReply::finished, this, [this, reply, serverUrl, onOk, onFail, what]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            const QString msg = what + QStringLiteral(" 失败: ") + reply->errorString()
                                + QStringLiteral(" (HTTP ") + QString::number(status) + QLatin1Char(')');
            qWarning().noquote() << "Emby:" << msg
                                 << QStringLiteral("body=")
                                 + (reply->isOpen()
                                        ? QString::fromUtf8(reply->readAll().left(200))
                                        : QStringLiteral("<closed>"));
            emit serverRequestFailed(serverUrl, msg);
            emit errorOccurred(serverUrl, msg);
            if (onFail)
                onFail();
            return;
        }
        onOk(QJsonDocument::fromJson(reply->readAll()));
    });
}

void EmbyClient::postFrom(const QString &serverUrl, const QString &path, const QJsonObject &body,
                          std::function<void(const QJsonDocument &)> onOk,
                          std::function<void()> onFail, const QString &what)
{
    QNetworkRequest req(QUrl(serverUrl.trimmed() + path));
    // 统一 UA(软件名/版本号),不用 Qt 默认 UA。
    req.setRawHeader(MoePlayer::kHeaderUserAgent, MoePlayer::userAgent().toUtf8());
    // 认证头无 token 版本:Emby 4.9 的 AuthenticateByName 要求携带
    // X-Emby-Authorization(缺 appName 字段返回 400)。
    req.setRawHeader(MoePlayer::kHeaderAuth, authHeaderFor(QString(), QString()).toUtf8());
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    req.setTransferTimeout(MoePlayer::kNetworkTimeoutMs);
    req.setAttribute(QNetworkRequest::Http2AllowedAttribute, false);
    QNetworkReply *reply = m_nam.post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, serverUrl, onOk, onFail, what]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            const QString msg = what + QStringLiteral(" 失败: ") + reply->errorString()
                                + QStringLiteral(" (HTTP ") + QString::number(status) + QLatin1Char(')');
            qWarning().noquote() << "Emby:" << msg
                                 << QStringLiteral("body=")
                                 + (reply->isOpen()
                                        ? QString::fromUtf8(reply->readAll().left(200))
                                        : QStringLiteral("<closed>"));
            emit serverRequestFailed(serverUrl, msg);
            emit errorOccurred(serverUrl, msg);
            if (onFail)
                onFail();
            return;
        }
        onOk(QJsonDocument::fromJson(reply->readAll()));
    });
}

void EmbyClient::postJson(const QString &serverUrl, const QString &token, const QString &userId,
                          const QString &path, const QJsonObject &body,
                          std::function<void(const QJsonDocument &)> onOk, const QString &what,
                          std::function<void()> onFail)
{
    QNetworkReply *reply = m_nam.post(makeRequest(serverUrl, token, userId, path, true),
                                      QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, serverUrl, onOk, onFail, what]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            const QString msg = what + QStringLiteral(" 失败: ") + reply->errorString()
                                + QStringLiteral(" (HTTP ") + QString::number(status) + QLatin1Char(')');
            qWarning().noquote() << "Emby:" << msg
                                 << QStringLiteral("body=")
                                 + (reply->isOpen()
                                        ? QString::fromUtf8(reply->readAll().left(200))
                                        : QStringLiteral("<closed>"));
            emit serverRequestFailed(serverUrl, msg);
            emit errorOccurred(serverUrl, msg);
            if (onFail)
                onFail();
            return;
        }
        onOk(QJsonDocument::fromJson(reply->readAll()));
    });
}

void EmbyClient::del(const QString &serverUrl, const QString &token, const QString &userId,
                     const QString &path, std::function<void(const QJsonDocument &)> onOk,
                     const QString &what)
{
    QNetworkReply *reply = m_nam.deleteResource(makeRequest(serverUrl, token, userId, path, false));
    connect(reply, &QNetworkReply::finished, this, [this, reply, serverUrl, onOk, what]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            const QString msg = what + QStringLiteral(" 失败: ") + reply->errorString()
                                + QStringLiteral(" (HTTP ") + QString::number(status) + QLatin1Char(')');
            qWarning().noquote() << "Emby:" << msg
                                 << QStringLiteral("body=")
                                 + (reply->isOpen()
                                        ? QString::fromUtf8(reply->readAll().left(200))
                                        : QStringLiteral("<closed>"));
            emit serverRequestFailed(serverUrl, msg);
            emit errorOccurred(serverUrl, msg);
            return;
        }
        onOk(QJsonDocument::fromJson(reply->readAll()));
    });
}

// ---------- 模型按服务器字典化 ----------

MediaItemModel *EmbyClient::viewsModelFor(const QString &serverUrl)
{
    const QString key = serverUrl.trimmed();
    if (!m_viewsModels.contains(key))
        { auto *m = new MediaItemModel(this); m->setServerPrefix(AccountManager::encodeServerKey(key)); m_viewsModels.insert(key, m); }
    return m_viewsModels.value(key);
}

MediaItemModel *EmbyClient::itemsModelFor(const QString &serverUrl)
{
    const QString key = serverUrl.trimmed();
    if (!m_itemsModels.contains(key))
        { auto *m = new MediaItemModel(this); m->setServerPrefix(AccountManager::encodeServerKey(key)); m_itemsModels.insert(key, m); }
    return m_itemsModels.value(key);
}

MediaItemModel *EmbyClient::seasonsModelFor(const QString &serverUrl)
{
    const QString key = serverUrl.trimmed();
    if (!m_seasonsModels.contains(key))
        { auto *m = new MediaItemModel(this); m->setServerPrefix(AccountManager::encodeServerKey(key)); m_seasonsModels.insert(key, m); }
    return m_seasonsModels.value(key);
}

MediaItemModel *EmbyClient::episodesModelFor(const QString &serverUrl)
{
    const QString key = serverUrl.trimmed();
    if (!m_episodesModels.contains(key))
        { auto *m = new MediaItemModel(this); m->setServerPrefix(AccountManager::encodeServerKey(key)); m_episodesModels.insert(key, m); }
    return m_episodesModels.value(key);
}

QString EmbyClient::searchKeyFor(const QString &serverUrl, const QString &accountId)
{
    const QString url = serverUrl.trimmed();
    return accountId.isEmpty() ? url : url + QLatin1Char('\n') + accountId;
}

QString EmbyClient::searchKeyServerUrl(const QString &key)
{
    const int i = key.indexOf(QLatin1Char('\n'));
    return i < 0 ? key : key.left(i);
}

MediaItemModel *EmbyClient::searchModelFor(const QString &serverUrl, const QString &accountId)
{
    return searchModelForKey(searchKeyFor(serverUrl, accountId));
}

MediaItemModel *EmbyClient::searchModelForKey(const QString &key)
{
    if (!m_searchModels.contains(key)) {
        auto *m = new MediaItemModel(this);
        m->setServerPrefix(AccountManager::encodeServerKey(searchKeyServerUrl(key)));
        m_searchModels.insert(key, m);
    }
    return m_searchModels.value(key);
}

MediaItemModel *EmbyClient::similarModelFor(const QString &serverUrl)
{
    const QString key = serverUrl.trimmed();
    if (!m_similarModels.contains(key))
        { auto *m = new MediaItemModel(this); m->setServerPrefix(AccountManager::encodeServerKey(key)); m_similarModels.insert(key, m); }
    return m_similarModels.value(key);
}

MediaItemModel *EmbyClient::allEpisodesModelFor(const QString &serverUrl)
{
    const QString key = serverUrl.trimmed();
    if (!m_allEpisodesModels.contains(key))
        { auto *m = new MediaItemModel(this); m->setServerPrefix(AccountManager::encodeServerKey(key)); m_allEpisodesModels.insert(key, m); }
    return m_allEpisodesModels.value(key);
}

MediaItemModel *EmbyClient::genresModelFor(const QString &serverUrl)
{
    const QString key = serverUrl.trimmed();
    if (!m_genresModels.contains(key))
        { auto *m = new MediaItemModel(this); m->setServerPrefix(AccountManager::encodeServerKey(key)); m_genresModels.insert(key, m); }
    return m_genresModels.value(key);
}

MediaItemModel *EmbyClient::foldersModelFor(const QString &serverUrl)
{
    const QString key = serverUrl.trimmed();
    if (!m_foldersModels.contains(key))
        { auto *m = new MediaItemModel(this); m->setServerPrefix(AccountManager::encodeServerKey(key)); m_foldersModels.insert(key, m); }
    return m_foldersModels.value(key);
}

void EmbyClient::dropServerModels(const QString &serverUrl)
{
    const QString key = serverUrl.trimmed();
    delete m_viewsModels.take(key);
    delete m_itemsModels.take(key);
    delete m_seasonsModels.take(key);
    delete m_episodesModels.take(key);
    delete m_searchModels.take(key);
    delete m_similarModels.take(key);
    delete m_allEpisodesModels.take(key);
    delete m_genresModels.take(key);
    delete m_foldersModels.take(key);
    m_itemsSeq.remove(key);
    m_searchSeq.remove(key);
}

// ---------- 登录与公开信息 ----------

void EmbyClient::login(const QString &serverUrl, const QString &username, const QString &password,
                       const QString &accountId)
{
    QJsonObject body;
    body.insert(QStringLiteral("Username"), username);
    // Emby 4.9 的 AuthenticateByName 实际接收 Pw 字段(官方 OpenAPI 文档写的是 Password,
    // 但 4.9 只认 Pw);双字段发送兼容新旧服务器。
    body.insert(QStringLiteral("Pw"), password);
    body.insert(QStringLiteral("Password"), password);
    postFrom(serverUrl, QStringLiteral("/Users/AuthenticateByName"), body,
             [this, serverUrl, accountId](const QJsonDocument &doc) {
                 const QJsonObject o = doc.object();
                 const QJsonObject u = o.value(QLatin1String("User")).toObject();
                 emit loginSucceeded(serverUrl,
                                     o.value(QLatin1String("AccessToken")).toString(),
                                     u.value(QLatin1String("Id")).toString(),
                                     u.value(QLatin1String("Name")).toString(),
                                     accountId);
             },
             nullptr, QStringLiteral("登录"));
}

// 通知服务器会话结束:结果完全忽略(部分服务器未实现该端点,登出失败
// 不影响本地删除);独立实现避免经 postJson 触发账号状态信号。
void EmbyClient::logout(const QString &serverUrl, const QString &token, const QString &userId)
{
    QNetworkRequest req = makeRequest(serverUrl, token, userId,
                                      QStringLiteral("/Sessions/Logout"), true);
    QNetworkReply *reply = m_nam.post(req, QByteArray());
    connect(reply, &QNetworkReply::finished, this,
            [reply]() { reply->deleteLater(); });
}

void EmbyClient::fetchServerPublicInfo(const QString &serverUrl)
{
    get(serverUrl, QString(), QString(), QStringLiteral("/System/Info/Public"),
        [this, serverUrl](const QJsonDocument &doc) {
            const QString serverName = doc.object().value(QLatin1String("ServerName")).toString();
            const QString version = doc.object().value(QLatin1String("Version")).toString();
            qInfo() << "Emby: server info" << serverName << version << "on" << serverUrl;
            emit serverPublicInfoReceived(serverUrl, serverName, version);
        }, nullptr, QStringLiteral("获取服务器信息"));
}

// 浏览器式获取站点图标(HTML Living Standard):请求 web 首页,解析
// <link rel="icon"> 标签,href 相对路径按 RFC 3986 相对文档 URL 解析,
// 随后下载图标图片字节经 serverIconReceived 返回(空 = 失败)。HTML 拉取
// 失败或无图标标签时静默失败:不 fallback、不重试,调用方不存数据,
// 卡片回退名称首字。仅添加服务器时调用(图片由调用方落盘本地缓存)。
void EmbyClient::fetchServerIcon(const QString &serverUrl)
{
    const QString htmlUrl = serverUrl.trimmed() + QStringLiteral("/web/index.html");
    QNetworkRequest req{QUrl(htmlUrl)};
    req.setRawHeader(MoePlayer::kHeaderUserAgent, MoePlayer::userAgent().toUtf8());
    req.setTransferTimeout(MoePlayer::kNetworkTimeoutMs);
    req.setAttribute(QNetworkRequest::Http2AllowedAttribute, false);
    QNetworkReply *reply = m_nam.get(req);
    connect(reply, &QNetworkReply::finished, this,
            [this, reply, serverUrl, htmlUrl]() {
                reply->deleteLater();
                if (reply->error() != QNetworkReply::NoError) {
                    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
                    qWarning() << "Emby: 服务器图标页拉取失败" << htmlUrl << reply->errorString() << "HTTP" << status;
                    emit serverIconReceived(serverUrl, QString(), QByteArray());
                    return;
                }
                const QString iconUrl =
                    parseFaviconLink(QString::fromUtf8(reply->readAll()), htmlUrl);
                if (iconUrl.isEmpty()) {
                    qDebug() << "Emby: 服务器首页无图标 link 标签" << htmlUrl;
                    emit serverIconReceived(serverUrl, QString(), QByteArray());
                    return;
                }
                downloadServerIconImage(serverUrl, iconUrl);
            });
}

// 下载已解析的图标 URL 图片字节(不含认证,Emby /web/ 静态资源):
// 成功发字节、失败发空。fetchServerIcon 解析出图标 URL 后调用。
void EmbyClient::downloadServerIconImage(const QString &serverUrl, const QString &iconUrl)
{
    QNetworkRequest req{QUrl(iconUrl)};
    req.setRawHeader(MoePlayer::kHeaderUserAgent, MoePlayer::userAgent().toUtf8());
    req.setTransferTimeout(MoePlayer::kNetworkTimeoutMs);
    req.setAttribute(QNetworkRequest::Http2AllowedAttribute, false);
    QNetworkReply *reply = m_nam.get(req);
    connect(reply, &QNetworkReply::finished, this,
            [this, reply, serverUrl, iconUrl]() {
                reply->deleteLater();
                if (reply->error() != QNetworkReply::NoError) {
                    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
                    qWarning() << "Emby: 服务器图标下载失败" << iconUrl << reply->errorString() << "HTTP" << status;
                    emit serverIconReceived(serverUrl, iconUrl, QByteArray());
                    return;
                }
                emit serverIconReceived(serverUrl, iconUrl, reply->readAll());
            });
}

// 下载任意图片 URL 字节(无认证):成功传字节,失败/超时传空。用于用户
// 自定义图标(可能非 Emby 域),不触发 serverRequestFailed。
void EmbyClient::downloadImage(const QString &url, std::function<void(const QByteArray &)> onDone)
{
    QNetworkRequest req{QUrl(url)};
    req.setRawHeader(MoePlayer::kHeaderUserAgent, MoePlayer::userAgent().toUtf8());
    req.setTransferTimeout(MoePlayer::kNetworkTimeoutMs);
    req.setAttribute(QNetworkRequest::Http2AllowedAttribute, false);
    QNetworkReply *reply = m_nam.get(req);
    connect(reply, &QNetworkReply::finished, this,
            [reply, onDone = std::move(onDone)]() {
                reply->deleteLater();
                onDone(reply->error() == QNetworkReply::NoError ? reply->readAll()
                                                                : QByteArray());
            });
}

// 解析 HTML 图标 link:apple-touch-icon 优先(选 192x192,Emby 的 PWA
// 图标尺寸),其次常规 icon/shortcut icon;href 相对路径按文档 URL 解析。
QString EmbyClient::parseFaviconLink(const QString &html, const QString &baseHtmlUrl)
{
    static const QRegularExpression tagRe(
        QStringLiteral("<link\\s[^>]*>"), QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression relRe(
        QStringLiteral("rel\\s*=\\s*[\"']([^\"']*)[\"']"),
        QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression hrefRe(
        QStringLiteral("href\\s*=\\s*[\"']([^\"']+)[\"']"),
        QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression sizesRe(
        QStringLiteral("sizes\\s*=\\s*[\"']([^\"']*)[\"']"),
        QRegularExpression::CaseInsensitiveOption);

    QString best;   // apple-touch-icon(192x192 优先)
    QString favicon; // icon / shortcut icon
    auto it = tagRe.globalMatch(html);
    while (it.hasNext()) {
        const QString tag = it.next().captured(0);
        const QString rel = relRe.match(tag).captured(1).toLower();
        if (!rel.contains(QLatin1String("icon")))
            continue;
        const QString href = hrefRe.match(tag).captured(1);
        if (href.isEmpty())
            continue;
        if (rel.contains(QLatin1String("apple-touch-icon"))) {
            const QString sizes = sizesRe.match(tag).captured(1);
            if (sizes.startsWith(QLatin1String("192")) || best.isEmpty())
                best = href;
        } else if (favicon.isEmpty()) {
            favicon = href;
        }
    }
    const QString chosen = best.isEmpty() ? favicon : best;
    if (chosen.isEmpty())
        return QString();
    // 相对路径按文档 URL 解析(RFC 3986);绝对 URL 原样返回。
    const QUrl base(baseHtmlUrl);
    const QUrl resolved = base.resolved(QUrl(chosen));
    if (resolved.isValid() && !resolved.scheme().isEmpty())
        return resolved.toString();
    return chosen;
}

void EmbyClient::validateToken(const QString &serverUrl, const QString &token,
                               const QString &userId, std::function<void(int)> onDone)
{
    // GET /System/Info(带 token):0=有效;401=凭证失效;其余=网络/服务器错误。
    // 走原始 reply 取 HTTP 状态,不触发全局 serverRequestFailed(需求区分)。
    QNetworkReply *reply = m_nam.get(makeRequest(serverUrl, token, userId,
                                                 QStringLiteral("/System/Info"), false));
    connect(reply, &QNetworkReply::finished, this,
            [this, reply, serverUrl, onDone = std::move(onDone)]() {
                reply->deleteLater();
                if (reply->error() == QNetworkReply::NoError) {
                    qDebug() << "Emby: token 有效" << serverUrl;
                    onDone(0);
                    return;
                }
                const int status = reply->attribute(
                    QNetworkRequest::HttpStatusCodeAttribute).toInt();
                qDebug() << "Emby: token 校验 401/网络错误" << status << serverUrl;
                onDone(status == 401 ? 1 : 2);
            });
}

// ---------- 浏览(按服务器路由) ----------

void EmbyClient::fetchViews(const QString &serverUrl, const QString &token, const QString &userId)
{
    const QString key = serverUrl.trimmed();
    get(key, token, userId, userPath(userId, QStringLiteral("/Views")),
        [this, key](const QJsonDocument &doc) {
            fillItems(viewsModelFor(key), doc, false);
            qInfo() << "Emby: views =" << viewsModelFor(key)->count() << "on" << key;
            emit viewsReceived(key);
        }, nullptr, QStringLiteral("获取媒体库视图"));
}

void EmbyClient::fetchItems(const QString &serverUrl, const QString &token, const QString &userId,
                            const QString &viewId, int startIndex, int limit,
                            const QString &sortBy, const QString &sortOrder,
                            const QString &genres, const QString &years,
                            const QString &minRating, const QString &filters,
                            const QString &searchTerm)
{
    const QString key = serverUrl.trimmed();
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("ParentId"), viewId);
    // 媒体库默认请求:递归平铺 + 仅电影/剧集。Recursive=true 把库/子文件夹
    // 子树内全部 Movie/Series 纳入(与 Emby web 默认一致,实测动漫库 653→1034
    // 条);IncludeItemTypes 排除 Folder 等非播放条目。下钻文件夹时同规则平铺
    // 该子树,层级浏览仍由 fetchFolders 负责。
    q.addQueryItem(QStringLiteral("Recursive"), QStringLiteral("true"));
    q.addQueryItem(QStringLiteral("IncludeItemTypes"), QStringLiteral("Movie,Series"));
    // UserData 携带已看/进度/未看集数/收藏,评分/年份供卡片角标,零额外请求。
    q.addQueryItem(QStringLiteral("Fields"), MoePlayer::kListFields);
    q.addQueryItem(QStringLiteral("SortBy"), sortBy);
    q.addQueryItem(QStringLiteral("SortOrder"), sortOrder);
    // 库内筛选(空串不传):Genres 单值、Years 单值、MinCommunityRating 下限、
    // Filters 状态;与 ParentId(视图或子文件夹)组合为多维筛选。
    if (!genres.isEmpty())
        q.addQueryItem(QStringLiteral("Genres"), genres);
    if (!years.isEmpty())
        q.addQueryItem(QStringLiteral("Years"), years);
    if (!minRating.isEmpty())
        q.addQueryItem(QStringLiteral("MinCommunityRating"), minRating);
    if (!filters.isEmpty())
        q.addQueryItem(QStringLiteral("Filters"), filters);
    // 库内搜索:SearchTerm 与 ParentId/筛选正交(实测 4.9.5.0 带词时
    // 忽略 SortBy/SortOrder,固定相关度排序)。
    if (!searchTerm.isEmpty())
        q.addQueryItem(QStringLiteral("SearchTerm"), searchTerm);
    q.addQueryItem(QStringLiteral("StartIndex"), QString::number(qMax(0, startIndex)));
    q.addQueryItem(QStringLiteral("Limit"), QString::number(qBound(1, limit, MoePlayer::kMaxPageSize))); // Emby 单页上限 200
    const int seq = ++m_itemsSeq[key]; // 序号按服务器隔离,并行浏览不互相丢弃
    get(key, token, userId, userPath(userId, QStringLiteral("/Items?%1").arg(q.toString())),
        [this, key, startIndex, seq](const QJsonDocument &doc) {
            // 视图快速切换时可能已有更新的请求,过期响应直接丢弃。
            if (seq != m_itemsSeq.value(key))
                return;
            const QJsonObject o = doc.object();
            const int total = o.value(QLatin1String("TotalRecordCount")).toInt(0);
            MediaItemModel *model = itemsModelFor(key);
            fillItems(model, doc, startIndex != 0);
            model->setTotal(total);
            qInfo() << "Emby: items =" << model->count() << "/" << total << "on" << key;
            emit itemsReceived(key);
        }, nullptr, QStringLiteral("获取媒体库条目"));
}

void EmbyClient::fetchGenres(const QString &serverUrl, const QString &token,
                             const QString &userId, const QString &viewId)
{
    const QString key = serverUrl.trimmed();
    // /Genres 为全局分类端点,ParentId 限定库/文件夹;Genre 是 BaseItemDto
    // (带 Id/ImageTags,实测 ImageTags.Primary 有值),直接复用条目模型。
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("ParentId"), viewId);
    q.addQueryItem(QStringLiteral("Limit"), QString::number(MoePlayer::kMaxPageSize));
    get(key, token, userId, QStringLiteral("/Genres?%1").arg(q.toString()),
        [this, key](const QJsonDocument &doc) {
            fillItems(genresModelFor(key), doc, false);
            qInfo() << "Emby: genres =" << genresModelFor(key)->count() << "on" << key;
            emit genresReceived(key);
        }, nullptr, QStringLiteral("获取类型分类"));
}

void EmbyClient::fetchYears(const QString &serverUrl, const QString &token,
                            const QString &userId, const QString &viewId)
{
    const QString key = serverUrl.trimmed();
    // /Years 返回轻量 TagItem(实测兼容实现仅 Name,无 Id),经信号返回
    // 名称列表,QML 端过滤脏值(如 "1")并倒序展示。
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("ParentId"), viewId);
    q.addQueryItem(QStringLiteral("Limit"), QString::number(MoePlayer::kMaxPageSize));
    get(key, token, userId, QStringLiteral("/Years?%1").arg(q.toString()),
        [this, key](const QJsonDocument &doc) {
            QStringList names;
            for (const auto &v : doc.object().value(QLatin1String("Items")).toArray())
                names.append(v.toObject().value(QLatin1String("Name")).toString());
            emit yearsReceived(key, names);
        }, nullptr, QStringLiteral("获取年份分类"));
}

void EmbyClient::fetchFolders(const QString &serverUrl, const QString &token,
                              const QString &userId, const QString &viewId)
{
    const QString key = serverUrl.trimmed();
    // 当前层顶层子文件夹(分组入口):不 Recursive 只取本层,拿到 Id 后
    // 以新 ParentId 下钻;条目带 Fields 供后续复用。
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("ParentId"), viewId);
    q.addQueryItem(QStringLiteral("IncludeItemTypes"), QStringLiteral("Folder"));
    q.addQueryItem(QStringLiteral("Fields"), MoePlayer::kListFields);
    q.addQueryItem(QStringLiteral("SortBy"), QStringLiteral("SortName"));
    q.addQueryItem(QStringLiteral("SortOrder"), QStringLiteral("Ascending"));
    q.addQueryItem(QStringLiteral("Limit"), QString::number(MoePlayer::kMaxPageSize));
    get(key, token, userId, userPath(userId, QStringLiteral("/Items?%1").arg(q.toString())),
        [this, key](const QJsonDocument &doc) {
            fillItems(foldersModelFor(key), doc, false, false);
            qInfo() << "Emby: folders =" << foldersModelFor(key)->count() << "on" << key;
            emit foldersReceived(key);
        }, nullptr, QStringLiteral("获取子文件夹"));
}

void EmbyClient::setFavorite(const QString &serverUrl, const QString &token, const QString &userId,
                             const QString &itemId, bool fav)
{
    const QString path = userPath(userId, QStringLiteral("/FavoriteItems/%1").arg(itemId));
    // POST 加收藏 / DELETE 取消;服务器返回空体,成功与否只记错误日志。
    if (fav)
        postJson(serverUrl, token, userId, path, QJsonObject(), [](const QJsonDocument &) {},
                 QStringLiteral("加入收藏"));
    else
        del(serverUrl, token, userId, path, [](const QJsonDocument &) {}, QStringLiteral("取消收藏"));
}

void EmbyClient::search(const QString &serverUrl, const QString &token, const QString &userId,
                        const QString &term, const QString &itemTypes, const QString &years,
                        const QString &filters, int startIndex, int limit,
                        const QString &accountId)
{
    // 复合键:同服务器多账号各一部模型/序号;空 accountId = 单服旧行为。
    const QString key = searchKeyFor(serverUrl, accountId);
    const QString url = searchKeyServerUrl(key);
    if (term.trimmed().isEmpty()) {
        ++m_searchSeq[key]; // 使在途响应过期
        auto *m = searchModelForKey(key);
        m->clear();
        m->setHasMore(false);
        emit searchResultsReady(url, accountId);
        return;
    }
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("SearchTerm"), term);
    // 跨库递归搜索;UserData 携带已看/进度/收藏,结果卡片零额外请求。
    q.addQueryItem(QStringLiteral("Recursive"), QStringLiteral("true"));
    if (!itemTypes.isEmpty())
        q.addQueryItem(QStringLiteral("IncludeItemTypes"), itemTypes);
    q.addQueryItem(QStringLiteral("Fields"), MoePlayer::kListFields);
    if (!years.isEmpty())
        q.addQueryItem(QStringLiteral("Years"), years);
    if (!filters.isEmpty())
        q.addQueryItem(QStringLiteral("Filters"), filters);
    // 搜索排序:服务器固定按相关度返回,SortBy/SortOrder 无效(实测
    // 4.9.5.0 各组合结果顺序相同),不传。
    if (startIndex > 0)
        q.addQueryItem(QStringLiteral("StartIndex"), QString::number(startIndex));
    // Limit+1 探针:多出的 1 条说明还有更多,截断并标记 hasMore。
    q.addQueryItem(QStringLiteral("Limit"), QString::number(limit + 1));
    const int seq = ++m_searchSeq[key];
    qDebug() << "Emby: 搜索" << term << "startIndex" << startIndex << "on" << url;
    get(url, token, userId, userPath(userId, QStringLiteral("/Items?%1").arg(q.toString())),
        [this, key, seq, startIndex, limit, url, accountId](const QJsonDocument &doc) {
            // 输入防抖窗口内的旧请求结果直接丢弃。
            if (seq != m_searchSeq.value(key)) {
                qDebug() << "Emby: 搜索响应过期丢弃" << url;
                return;
            }
            QJsonArray arr = doc.object().value(QLatin1String("Items")).toArray();
            const bool hasMore = arr.size() > limit;
            if (hasMore) {
                QJsonArray trimmed;
                for (int i = 0; i < limit; ++i)
                    trimmed.append(arr.at(i));
                arr = trimmed;
            }
            auto *m = searchModelForKey(key);
            if (startIndex == 0)
                m->setItems(arr, true);
            else
                m->appendItems(arr, true);
            m->setHasMore(hasMore);
            qInfo() << "Emby: search =" << m->count() << "hasMore" << hasMore << "on" << url;
            emit searchResultsReady(url, accountId);
        }, [this, key, seq, url, accountId] {
            // 失败也发空结果:聚合按账号计数,缺此回调会永久"搜索中"。
            if (seq != m_searchSeq.value(key)) {
                qDebug() << "Emby: 搜索响应过期丢弃" << url;
                return;
            }
            auto *m = searchModelForKey(key);
            m->clear();
            m->setHasMore(false);
            emit searchResultsReady(url, accountId);
        }, QStringLiteral("搜索"));
}

void EmbyClient::fetchSeasons(const QString &serverUrl, const QString &token, const QString &userId,
                              const QString &seriesId)
{
    const QString key = serverUrl.trimmed();
    get(key, token, userId,
        QStringLiteral("/Shows/%1/Seasons?Fields=PrimaryImageAspectRatio").arg(seriesId),
        [this, key](const QJsonDocument &doc) {
            fillItems(seasonsModelFor(key), doc, false);
            qInfo() << "Emby: seasons =" << seasonsModelFor(key)->count() << "on" << key;
            emit seasonsReceived(key);
        }, nullptr, QStringLiteral("获取剧集分季"));
}

void EmbyClient::fetchEpisodes(const QString &serverUrl, const QString &token, const QString &userId,
                               const QString &seriesId, const QString &seasonId)
{
    const QString key = serverUrl.trimmed();
    get(key, token, userId,
        // UserId 必带:分集端点的 UserData 只在该参数存在时返回(实测缺参数时
        // 响应条目里整个 UserData 键都不存在),已看徽标/进度条/续播位置依赖它。
        QStringLiteral("/Shows/%1/Episodes?SeasonId=%2&UserId=%3&Fields=UserData,PrimaryImageAspectRatio")
            .arg(seriesId, seasonId, userId),
        [this, key](const QJsonDocument &doc) {
            fillItems(episodesModelFor(key), doc, false);
            qInfo() << "Emby: episodes =" << episodesModelFor(key)->count() << "on" << key;
            emit episodesReceived(key);
        }, nullptr, QStringLiteral("获取分集"));
}

// ---------- 跨服务器只读拉取(首页聚合用,结果经信号返回) ----------

void EmbyClient::fetchServerViews(const QString &serverUrl, const QString &accountId,
                                  const QString &token, const QString &userId)
{
    get(serverUrl, token, userId, userPath(userId, QStringLiteral("/Views")),
        [this, serverUrl, accountId](const QJsonDocument &doc) {
            QVariantList out;
            for (const auto &v : doc.object().value(QLatin1String("Items")).toArray()) {
                const QJsonObject o = v.toObject();
                const QString tag = o.value(QLatin1String("ImageTags"))
                                        .toObject().value(QLatin1String("Primary")).toString();
                QVariantMap m;
                m.insert(QStringLiteral("id"), o.value(QLatin1String("Id")).toString());
                m.insert(QStringLiteral("name"), o.value(QLatin1String("Name")).toString());
                m.insert(QStringLiteral("posterId"),
                         tag.isEmpty() ? QString()
                                       : o.value(QLatin1String("Id")).toString()
                                             + QLatin1Char('~') + tag);
                out.append(m);
            }
            qInfo() << "Emby: serverViews =" << out.size() << "on" << serverUrl;
            emit serverViewsReceived(serverUrl, accountId, out);
        },
        // 失败:发空视图推进聚合计数,原因经 serverRequestFailed 通知。
        [this, serverUrl, accountId] { emit serverViewsReceived(serverUrl, accountId, QVariantList()); },
        QStringLiteral("获取媒体库视图"));
}

void EmbyClient::fetchServerItems(const QString &serverUrl, const QString &accountId,
                                  const QString &token, const QString &userId,
                                  const QString &viewId, const QString &viewName, int limit)
{
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("ParentId"), viewId);
    // 按更新时间(文件修改时间)倒序,新更新/入库的内容靠前;
    // DateLastMediaAdded 在部分服务器条目级排序会异常,改用 DateModified。
    q.addQueryItem(QStringLiteral("SortBy"), QStringLiteral("DateModified"));
    q.addQueryItem(QStringLiteral("SortOrder"), QStringLiteral("Descending"));
    q.addQueryItem(QStringLiteral("Fields"),
                   QStringLiteral("PrimaryImageAspectRatio,UserData,Overview,ProductionYear,RunTimeTicks,BackdropImageTags,ParentBackdropImageTags"));
    q.addQueryItem(QStringLiteral("Limit"),
                   QString::number(qBound(1, limit, MoePlayer::kHomePerLibraryLimit)));
    get(serverUrl, token, userId,
        QStringLiteral("/Users/%1/Items?%2").arg(userId, q.toString()),
        [this, serverUrl, viewId, viewName, accountId](const QJsonDocument &doc) {
            QVariantList items;
            for (const auto &v : doc.object().value(QLatin1String("Items")).toArray())
                items.append(parseHomeItem(v.toObject(), serverUrl));
            // 正常路径(有条目)记 debug(默认滤,避免聚合刷屏);空结果记
            // info——多账号/多库聚合时空行常指向库权限或空库,需定位到
            // 账号与库(同服多账号可见库不同)。
            if (items.isEmpty())
                qInfo() << "Emby: serverItems = 0 on" << serverUrl << "account" << accountId
                        << "view" << viewName << "id" << viewId;
            else
                qDebug() << "Emby: serverItems =" << items.size() << "on" << serverUrl
                         << "account" << accountId << "view" << viewName << "id" << viewId;
            emit serverItemsReceived(serverUrl, accountId, viewId, items);
        },
        // 失败:发空条目推进聚合计数,原因经 serverRequestFailed 通知。
        [this, serverUrl, accountId, viewId] { emit serverItemsReceived(serverUrl, accountId, viewId, QVariantList()); },
        QStringLiteral("获取首页行"));
}

void EmbyClient::fetchPlaybackHistory(const QString &serverUrl, const QString &accountId,
                                      const QString &token, const QString &userId,
                                      int startIndex, int limit, bool filtered)
{
    // 过滤段带 Filters=IsPlayed:实测服务器在已播条目之后混着从未播放的行,越深越多,
    // 不过滤翻页只会白拿未播条目。过滤会换一套下标空间,故由调用方显式给出 filtered,
    // 不能按 StartIndex 推断(过滤段本身也从 0 起)。
    const int from = qMax(0, startIndex);
    const QUrlQuery q = historyListQuery(from, limit, filtered);
    get(serverUrl, token, userId,
        QStringLiteral("/Users/%1/Items?%2").arg(userId, q.toString()),
        [this, serverUrl, accountId, from](const QJsonDocument &doc) {
            QVariantList out;
            int seq = 0;
            for (const auto &v : doc.object().value(QLatin1String("Items")).toArray())
                out.append(parseHistoryItem(v.toObject(), serverUrl, seq++));
            const int total = doc.object().value(QLatin1String("TotalRecordCount")).toInt();
            qInfo() << "Emby: playbackHistory =" << out.size() << "startIndex" << from
                    << "总数" << total << "on" << serverUrl;
            emit playbackHistoryReceived(serverUrl, accountId, from, out, total, true);
        },
        // 失败:发空列表 + ok=false(调用方保留既有存储,只结算本次请求)。
        [this, serverUrl, accountId, from] {
            emit playbackHistoryReceived(serverUrl, accountId, from, QVariantList(), 0, false);
        },
        QStringLiteral("拉取播放历史"), true /*后台连接池*/);
}


void EmbyClient::fetchItemUserData(const QString &serverUrl, const QString &accountId,
                                   const QString &token, const QString &userId,
                                   const QString &itemId)
{
    // 单条端点返回全量档(列表端点的 UserData 被裁剪,无 PlayCount/
    // LastPlayedDate)。
    get(serverUrl, token, userId,
        userPath(userId, QStringLiteral("/Items/%1").arg(itemId)),
        [this, serverUrl, accountId, itemId](const QJsonDocument &doc) {
            const QJsonObject ud = doc.object().value(QLatin1String("UserData")).toObject();
            emit itemUserDataReceived(serverUrl, accountId, itemId,
                                      ud.value(QLatin1String("PlayCount")).toInt(0),
                                      parseEmbyDateMs(ud.value(QLatin1String("LastPlayedDate")).toString()),
                                      ud.value(QLatin1String("PlaybackPositionTicks")).toDouble(0),
                                      ud.value(QLatin1String("Played")).toBool(false));
        },
        // 失败以 positionTicks < 0 上报(字段无意义),批次照常推进。
        [this, serverUrl, accountId, itemId] {
            emit itemUserDataReceived(serverUrl, accountId, itemId, 0, 0, -1.0, false);
        },
        QStringLiteral("拉取条目播放数据"), true /*后台连接池*/);
}

void EmbyClient::fetchResume(const QString &serverUrl, const QString &accountId,
                             const QString &token, const QString &userId, int limit)
{
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("MediaTypes"), QStringLiteral("Video"));
    q.addQueryItem(QStringLiteral("Fields"),
                   QStringLiteral("PrimaryImageAspectRatio,ProductionYear,RunTimeTicks,"
                                  "SeriesId,SeriesName,IndexNumber,ParentIndexNumber"));
    q.addQueryItem(QStringLiteral("Limit"), QString::number(qBound(1, limit, MoePlayer::kMaxPageSize)));
    get(serverUrl, token, userId,
        QStringLiteral("/Users/%1/Items/Resume?%2").arg(userId, q.toString()),
        [this, serverUrl, accountId](const QJsonDocument &doc) {
            QVariantList out;
            int seq = 0;
            for (const auto &v : doc.object().value(QLatin1String("Items")).toArray())
                out.append(parseHistoryItem(v.toObject(), serverUrl, seq++));
            qInfo() << "Emby: resume =" << out.size() << "on" << serverUrl;
            emit resumeReceived(serverUrl, accountId, out);
        },
        // 失败发空列表:调用方按"无目标"处理(不清既有存储,不阻塞其它回退)。
        [this, serverUrl, accountId] { emit resumeReceived(serverUrl, accountId, QVariantList()); },
        QStringLiteral("拉取继续观看"), true /*后台连接池*/);
}

void EmbyClient::fetchNextUp(const QString &serverUrl, const QString &token,
                             const QString &userId, const QString &seriesId, int limit)
{
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("UserId"), userId);
    q.addQueryItem(QStringLiteral("SeriesId"), seriesId);
    q.addQueryItem(QStringLiteral("Limit"), QString::number(qBound(1, limit, 20)));
    get(serverUrl, token, userId, QStringLiteral("/Shows/NextUp?%1").arg(q.toString()),
        [this, serverUrl, seriesId](const QJsonDocument &doc) {
            QVariantList out;
            for (const auto &v : doc.object().value(QLatin1String("Items")).toArray()) {
                const QJsonObject o = v.toObject();
                QVariantMap m;
                m.insert(QStringLiteral("id"), o.value(QLatin1String("Id")).toString());
                m.insert(QStringLiteral("name"), o.value(QLatin1String("Name")).toString());
                m.insert(QStringLiteral("seasonNo"),
                         o.value(QLatin1String("ParentIndexNumber")).toInt(0));
                m.insert(QStringLiteral("episodeNo"),
                         o.value(QLatin1String("IndexNumber")).toInt(0));
                out.append(m);
            }
            qInfo() << "Emby: nextUp =" << out.size() << "on" << serverUrl << "series" << seriesId;
            emit nextUpReceived(serverUrl, seriesId, out);
        },
        // 失败:发空列表,详情页回退第一季(原因经 serverRequestFailed 通知)。
        [this, serverUrl, seriesId] { emit nextUpReceived(serverUrl, seriesId, QVariantList()); },
        QStringLiteral("获取续播集"));
}

void EmbyClient::fetchServerSuggestions(const QString &serverUrl, const QString &accountId,
                                        const QString &token, const QString &userId, int limit)
{
    QUrlQuery q;
    // 字段与库行条目一致(hero 卡消费 backdropId/name/year/runtimeTicks 等),
    // EnableUserData 带回继续观看进度(hero 点击进详情后可用)。
    q.addQueryItem(QStringLiteral("Fields"),
                   QStringLiteral("PrimaryImageAspectRatio,UserData,Overview,ProductionYear,RunTimeTicks,BackdropImageTags,ParentBackdropImageTags"));
    q.addQueryItem(QStringLiteral("EnableUserData"), QStringLiteral("true"));
    // 只保留影片与剧集(4.9.5 生效;4.8 忽略该参数,由 QML 端白名单兜底
    // 过滤目录条目)。分集建议不进 hero(无独立背景,界面是剧集主题)。
    q.addQueryItem(QStringLiteral("IncludeItemTypes"),
                   QStringLiteral("Movie,Series"));
    // 只返回带背景图的条目(4.9.5 生效):hero 大卡必需背景,无背景条目
    // 由服务器直接从建议中滤掉;4.8 无视全部过滤参数,由版本门控跳过。
    q.addQueryItem(QStringLiteral("ImageTypes"), QStringLiteral("Backdrop"));
    q.addQueryItem(QStringLiteral("Limit"),
                   QString::number(qBound(1, limit, MoePlayer::kHomePerLibraryLimit)));
    get(serverUrl, token, userId,
        QStringLiteral("/Users/%1/Suggestions?%2").arg(userId, q.toString()),
        [this, serverUrl, accountId](const QJsonDocument &doc) {
            QVariantList items;
            for (const auto &v : doc.object().value(QLatin1String("Items")).toArray())
                items.append(parseHomeItem(v.toObject(), serverUrl));
            qInfo() << "Emby: serverSuggestions =" << items.size() << "on" << serverUrl;
            emit serverSuggestionsReceived(serverUrl, accountId, items);
        },
        // 失败:不发空列表——"空列表"与"服务器确实没有建议"是两回事,混同会让
        // 调用方把失败账号的推荐当成"清空"处理(缓存侧按"无回执 = 保留上次推荐"
        // 处理)。失败原因仍经 serverRequestFailed/errorOccurred 报出。
        nullptr,
        QStringLiteral("获取首页建议"));
}

void EmbyClient::loginFor(const QString &serverUrl, const QString &username,
                          const QString &password)
{
    QJsonObject body;
    body.insert(QStringLiteral("Username"), username);
    // 与 login 一致:Pw 为 4.9 实际接收字段,双字段兼容新旧服务器。
    body.insert(QStringLiteral("Pw"), password);
    body.insert(QStringLiteral("Password"), password);
    postFrom(serverUrl, QStringLiteral("/Users/AuthenticateByName"), body,
             [this, serverUrl](const QJsonDocument &doc) {
                 const QJsonObject o = doc.object();
                 const QString token = o.value(QLatin1String("AccessToken")).toString();
                 const QJsonObject u = o.value(QLatin1String("User")).toObject();
                 emit serverLoginFinished(serverUrl, !token.isEmpty(), token,
                                          u.value(QLatin1String("Id")).toString(),
                                          u.value(QLatin1String("Name")).toString());
             },
             [this, serverUrl] {
                 emit serverLoginFinished(serverUrl, false, QString(), QString(), QString());
             },
             QStringLiteral("登录"));
}

// ---------- 条目详情 / 播放协商 ----------

void EmbyClient::fetchItemDetail(const QString &serverUrl, const QString &token,
                                 const QString &userId, const QString &itemId)
{
    const QString key = serverUrl.trimmed();
    QUrlQuery q;
    // UserData 携带已看状态/播放位置/收藏;People 供演职人员;Series 相关字段
    // 供剧集详情显示"剧名 + S/E"与选集条定位;Backdrop 标签供 Hero 背景。
    q.addQueryItem(QStringLiteral("Fields"),
                   QStringLiteral("Overview,Genres,ProductionYear,CommunityRating,MediaSources,UserData,People,ParentBackdropImageTags,BackdropImageTags,SeriesId,SeriesName,IndexNumber,ParentIndexNumber,SeasonId,DateCreated,DateModified,PrimaryImageAspectRatio"));
    qDebug() << "Emby: 拉取条目详情" << itemId << "on" << key;
    get(key, token, userId, userPath(userId, QStringLiteral("/Items/%1?%2").arg(itemId, q.toString())),
        [this, key, token, userId](const QJsonDocument &doc) {
            const QJsonObject o = doc.object();
            const QJsonObject ud = o.value(QLatin1String("UserData")).toObject();
            const QString prefix = AccountManager::encodeServerKey(key);
            const QString id = o.value(QLatin1String("Id")).toString();
            QVariantMap m;
            m.insert(QStringLiteral("id"), id);
            m.insert(QStringLiteral("name"), o.value(QLatin1String("Name")).toString());
            m.insert(QStringLiteral("type"), o.value(QLatin1String("Type")).toString());
            m.insert(QStringLiteral("year"), o.value(QLatin1String("ProductionYear")).toInt(0));
            m.insert(QStringLiteral("rating"), o.value(QLatin1String("CommunityRating")).toDouble(0));
            m.insert(QStringLiteral("runtimeSecs"), o.value(QLatin1String("RunTimeTicks")).toDouble(0) / MoePlayer::kTicksPerSecond);
            m.insert(QStringLiteral("overview"), o.value(QLatin1String("Overview")).toString());
            // 类型标签(metaLine 显示);Fields 已请求 Genres,此前漏解析导致永不显示。
            m.insert(QStringLiteral("genres"), o.value(QLatin1String("Genres")).toArray().toVariantList());
            // 条目级时间:加入库时间 / 数据最近变更时间(ISO8601,展示侧截取日期)。
            m.insert(QStringLiteral("dateCreated"), o.value(QLatin1String("DateCreated")).toString());
            m.insert(QStringLiteral("dateModified"), o.value(QLatin1String("DateModified")).toString());
            // 继续观看:上次停止位置(100ns ticks),未看或已播完为 0。
            m.insert(QStringLiteral("positionTicks"), ud.value(QLatin1String("PlaybackPositionTicks")).toDouble(0));
            m.insert(QStringLiteral("played"), ud.value(QLatin1String("Played")).toBool(false));
            m.insert(QStringLiteral("isFavorite"), ud.value(QLatin1String("IsFavorite")).toBool(false));
            // 剧集归属:分集条目的季号/集号/剧名/父剧/所在季。
            m.insert(QStringLiteral("seasonNo"), o.value(QLatin1String("ParentIndexNumber")).toInt(0));
            m.insert(QStringLiteral("episodeNo"), o.value(QLatin1String("IndexNumber")).toInt(0));
            m.insert(QStringLiteral("seriesName"), o.value(QLatin1String("SeriesName")).toString());
            m.insert(QStringLiteral("seriesId"), o.value(QLatin1String("SeriesId")).toString());
            m.insert(QStringLiteral("seasonId"), o.value(QLatin1String("SeasonId")).toString());
            // 海报/背景 id 统一带服务器前缀与图片类型(kind),供 PosterProvider 路由。
            const QString primaryTag = o.value(QLatin1String("ImageTags"))
                                           .toObject().value(QLatin1String("Primary")).toString();
            if (!primaryTag.isEmpty())
                m.insert(QStringLiteral("posterId"), prefix + QLatin1Char('~') + id + QLatin1Char('~') + primaryTag + QStringLiteral("~Primary"));
            const auto backdropTag = [&o](const char *field) {
                const QJsonArray arr = o.value(QLatin1String(field)).toArray();
                return arr.isEmpty() ? QString() : arr.first().toString();
            };
            const QString back = backdropTag("BackdropImageTags");
            if (!back.isEmpty())
                m.insert(QStringLiteral("backdropId"), prefix + QLatin1Char('~') + id + QLatin1Char('~') + back + QStringLiteral("~Backdrop"));
            const QString parentBack = backdropTag("ParentBackdropImageTags");
            const QString seriesId = o.value(QLatin1String("SeriesId")).toString();
            if (!parentBack.isEmpty() && !seriesId.isEmpty())
                m.insert(QStringLiteral("parentBackdropId"), prefix + QLatin1Char('~') + seriesId + QLatin1Char('~') + parentBack + QStringLiteral("~Backdrop"));
            // 演职人员:姓名/角色/类型,头像有 PrimaryImageTag 时带前缀。
            QVariantList people;
            for (const auto &p : o.value(QLatin1String("People")).toArray()) {
                const QJsonObject po = p.toObject();
                QVariantMap pm;
                pm.insert(QStringLiteral("id"), po.value(QLatin1String("Id")).toString());
                pm.insert(QStringLiteral("name"), po.value(QLatin1String("Name")).toString());
                pm.insert(QStringLiteral("role"), po.value(QLatin1String("Role")).toString());
                pm.insert(QStringLiteral("type"), po.value(QLatin1String("Type")).toString());
                const QString ptag = po.value(QLatin1String("PrimaryImageTag")).toString();
                if (!ptag.isEmpty())
                    pm.insert(QStringLiteral("posterId"), prefix + QLatin1Char('~') + po.value(QLatin1String("Id")).toString()
                                                          + QLatin1Char('~') + ptag + QStringLiteral("~Primary"));
                people.append(pm);
            }
            m.insert(QStringLiteral("people"), people);
            // 媒体信息:版本 + 流(视频/音轨/字幕),只读展示用。
            QVariantList versions;
            for (const auto &s : o.value(QLatin1String("MediaSources")).toArray()) {
                const QJsonObject so = s.toObject();
                QVariantMap vm;
                vm.insert(QStringLiteral("id"), so.value(QLatin1String("Id")).toString());
                vm.insert(QStringLiteral("name"), so.value(QLatin1String("Name")).toString());
                vm.insert(QStringLiteral("container"), so.value(QLatin1String("Container")).toString());
                vm.insert(QStringLiteral("sizeBytes"), so.value(QLatin1String("Size")).toInteger());
                vm.insert(QStringLiteral("bitrate"), so.value(QLatin1String("Bitrate")).toInteger());
                vm.insert(QStringLiteral("runTimeTicks"), so.value(QLatin1String("RunTimeTicks")).toInteger());
                vm.insert(QStringLiteral("defaultAudioStreamIndex"), so.value(QLatin1String("DefaultAudioStreamIndex")).toInt(-1));
                vm.insert(QStringLiteral("defaultSubtitleStreamIndex"), so.value(QLatin1String("DefaultSubtitleStreamIndex")).toInt(-1));
                QVariantList streams;
                for (const auto &st : so.value(QLatin1String("MediaStreams")).toArray()) {
                    const QJsonObject sto = st.toObject();
                    QVariantMap sm;
                    sm.insert(QStringLiteral("type"), sto.value(QLatin1String("Type")).toString());
                    sm.insert(QStringLiteral("codec"), sto.value(QLatin1String("Codec")).toString());
                    sm.insert(QStringLiteral("displayTitle"), sto.value(QLatin1String("DisplayTitle")).toString());
                    sm.insert(QStringLiteral("bitrate"), sto.value(QLatin1String("BitRate")).toInteger());
                    sm.insert(QStringLiteral("channels"), sto.value(QLatin1String("Channels")).toInt(0));
                    sm.insert(QStringLiteral("channelLayout"), sto.value(QLatin1String("ChannelLayout")).toString());
                    sm.insert(QStringLiteral("sampleRate"), sto.value(QLatin1String("SampleRate")).toInt(0));
                    sm.insert(QStringLiteral("bitDepth"), sto.value(QLatin1String("BitDepth")).toInt(0));
                    sm.insert(QStringLiteral("language"), sto.value(QLatin1String("Language")).toString());
                    sm.insert(QStringLiteral("displayLanguage"), sto.value(QLatin1String("DisplayLanguage")).toString());
                    sm.insert(QStringLiteral("width"), sto.value(QLatin1String("Width")).toInt(0));
                    sm.insert(QStringLiteral("height"), sto.value(QLatin1String("Height")).toInt(0));
                    sm.insert(QStringLiteral("profile"), sto.value(QLatin1String("Profile")).toString());
                    sm.insert(QStringLiteral("videoRange"), sto.value(QLatin1String("VideoRange")).toString());
                    sm.insert(QStringLiteral("frameRate"), sto.value(QLatin1String("RealFrameRate")).toDouble(0));
                    sm.insert(QStringLiteral("level"), sto.value(QLatin1String("Level")).toDouble(0));
                    sm.insert(QStringLiteral("aspectRatio"), sto.value(QLatin1String("AspectRatio")).toString());
                    sm.insert(QStringLiteral("pixelFormat"), sto.value(QLatin1String("PixelFormat")).toString());
                    sm.insert(QStringLiteral("isInterlaced"), sto.value(QLatin1String("IsInterlaced")).toBool(false));
                    sm.insert(QStringLiteral("isDefault"), sto.value(QLatin1String("IsDefault")).toBool(false));
                    sm.insert(QStringLiteral("isForced"), sto.value(QLatin1String("IsForced")).toBool(false));
                    sm.insert(QStringLiteral("isExternal"), sto.value(QLatin1String("IsExternal")).toBool(false));
                    sm.insert(QStringLiteral("index"), sto.value(QLatin1String("Index")).toInt(-1));
                    sm.insert(QStringLiteral("title"), sto.value(QLatin1String("Title")).toString());
                    sm.insert(QStringLiteral("videoRangeType"), sto.value(QLatin1String("VideoRangeType")).toString());
                    sm.insert(QStringLiteral("colorSpace"), sto.value(QLatin1String("ColorSpace")).toString());
                    sm.insert(QStringLiteral("colorTransfer"), sto.value(QLatin1String("ColorTransfer")).toString());
                    sm.insert(QStringLiteral("colorPrimaries"), sto.value(QLatin1String("ColorPrimaries")).toString());
                    sm.insert(QStringLiteral("locationType"), sto.value(QLatin1String("SubtitleLocationType")).toString());
                    sm.insert(QStringLiteral("attachmentSize"), sto.value(QLatin1String("AttachmentSize")).toInteger());
                    streams.append(sm);
                }
                vm.insert(QStringLiteral("streams"), streams);
                versions.append(vm);
            }
            m.insert(QStringLiteral("mediaSources"), versions);
            // 单集主图多为 16:9 剧照,入 2:3 海报槽违和:自身 Primary 非竖版
            // (aspect 缺失或 >0.75)时按 季→剧 借竖版海报(父级比例批量补查,
            // 仅横版条目付这一次请求);借不到回退自身 Primary。
            const double ownAspect = o.value(QLatin1String("PrimaryImageAspectRatio")).toDouble(0);
            const QString seasonId = o.value(QLatin1String("SeasonId")).toString();
            if ((ownAspect > 0 && ownAspect <= 0.75) || (seasonId.isEmpty() && seriesId.isEmpty())) {
                emit itemDetailReady(key, m);
                return;
            }
            QStringList parentIds;
            if (!seasonId.isEmpty())
                parentIds << seasonId;
            if (!seriesId.isEmpty())
                parentIds << seriesId;
            QUrlQuery pq;
            pq.addQueryItem(QStringLiteral("Ids"), parentIds.join(QLatin1Char(',')));
            pq.addQueryItem(QStringLiteral("Fields"), QStringLiteral("PrimaryImageAspectRatio,ImageTags"));
            get(key, token, userId, userPath(userId, QStringLiteral("/Items?%1").arg(pq.toString())),
                [this, key, m, parentIds](const QJsonDocument &pdoc) mutable {
                    const QJsonArray arr = pdoc.object().value(QLatin1String("Items")).toArray();
                    bool found = false;
                    for (const QString &want : parentIds) {
                        for (const auto &iv : arr) {
                            const QJsonObject io = iv.toObject();
                            if (io.value(QLatin1String("Id")).toString() != want)
                                continue;
                            const double a = io.value(QLatin1String("PrimaryImageAspectRatio")).toDouble(0);
                            const QString ptag = io.value(QLatin1String("ImageTags")).toObject()
                                                     .value(QLatin1String("Primary")).toString();
                            if (a > 0 && a <= 0.75 && !ptag.isEmpty()) {
                                m.insert(QStringLiteral("posterId"),
                                         AccountManager::encodeServerKey(key) + QLatin1Char('~')
                                             + want + QLatin1Char('~') + ptag + QStringLiteral("~Primary"));
                                found = true;
                            }
                            break;
                        }
                        if (found)
                            break;
                    }
                    emit itemDetailReady(key, m);
                },
                [this, key, m]() mutable { emit itemDetailReady(key, m); },
                QStringLiteral("获取父级海报"));
        }, nullptr, QStringLiteral("获取条目详情"));
}

void EmbyClient::fetchSimilar(const QString &serverUrl, const QString &token,
                              const QString &userId, const QString &itemId)
{
    const QString key = serverUrl.trimmed();
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("Fields"), MoePlayer::kListFields);
    q.addQueryItem(QStringLiteral("Limit"), QString::number(MoePlayer::kSearchLimit));
    get(key, token, userId, QStringLiteral("/Items/%1/Similar?%2").arg(itemId, q.toString()),
        [this, key](const QJsonDocument &doc) {
            fillItems(similarModelFor(key), doc, false);
            qInfo() << "Emby: similar =" << similarModelFor(key)->count() << "on" << key;
            emit similarReady(key);
        }, nullptr, QStringLiteral("获取相似推荐"));
}

void EmbyClient::fetchAllEpisodes(const QString &serverUrl, const QString &accountId,
                                  const QString &token, const QString &userId,
                                  const QString &seriesId)
{
    const QString key = serverUrl.trimmed();
    // 不带 SeasonId:返回整剧全部分集(跨季),供"继续观看"按进度定位目标集。
    get(key, token, userId,
        // UserId 必带:UserData 只在该参数存在时返回(见 fetchEpisodes)。
        QStringLiteral("/Shows/%1/Episodes?UserId=%2&Fields=UserData,PrimaryImageAspectRatio")
            .arg(seriesId, userId),
        [this, key, serverUrl, accountId, seriesId](const QJsonDocument &doc) {
            fillItems(allEpisodesModelFor(key), doc, false);
            // 同批解析为播放历史条目(含剧集归属),供调用方回写本地。
            QVariantList out;
            int seq = 0;
            for (const auto &v : doc.object().value(QLatin1String("Items")).toArray())
                out.append(parseHistoryItem(v.toObject(), serverUrl, seq++));
            qInfo() << "Emby: allEpisodes =" << allEpisodesModelFor(key)->count() << "on" << key;
            emit allEpisodesReady(key);
            emit allEpisodesParsed(serverUrl, accountId, seriesId, out);
        }, nullptr, QStringLiteral("获取剧集全部分集"));
}


void EmbyClient::fetchPlaybackInfo(const QString &serverUrl, const QString &token,
                                   const QString &userId, const QString &itemId,
                                   const QString &mediaSourceId, const QString &seriesId,
                                   int audioStreamIndex, int subtitleStreamIndex)
{
    const QString key = serverUrl.trimmed();
    QJsonObject dp;
    dp.insert(QStringLiteral("MaxStreamingBitrate"), 120000000);
    dp.insert(QStringLiteral("MaxStaticBitrate"), 100000000);
    dp.insert(QStringLiteral("DirectPlayProfiles"), QJsonArray{
        QJsonObject{{ QStringLiteral("Container"), QStringLiteral("mkv,mp4") },
                    { QStringLiteral("Type"), QStringLiteral("Video") },
                    { QStringLiteral("AudioCodec"), QStringLiteral("aac,ac3,mp3,flac,opus") },
                    { QStringLiteral("VideoCodec"), QStringLiteral("h264,hevc,av1,vp9") }}});
    dp.insert(QStringLiteral("TranscodingProfiles"), QJsonArray{
        QJsonObject{{ QStringLiteral("Container"), QStringLiteral("mkv") },
                    { QStringLiteral("Type"), QStringLiteral("Video") },
                    { QStringLiteral("AudioCodec"), QStringLiteral("aac,ac3,mp3") },
                    { QStringLiteral("VideoCodec"), QStringLiteral("h264,hevc") }}});
    dp.insert(QStringLiteral("ContainerProfiles"), QJsonArray{});
    dp.insert(QStringLiteral("CodecProfiles"), QJsonArray{});
    // SubtitleProfiles 不能留空:空表等于声明「不支持任何字幕」,
    // 服务器将不发字幕地址,外挂字幕无法加载。
    dp.insert(QStringLiteral("SubtitleProfiles"), QJsonArray{
        QJsonObject{{ QStringLiteral("Format"), QStringLiteral("srt") },     { QStringLiteral("Method"), QStringLiteral("External") }},
        QJsonObject{{ QStringLiteral("Format"), QStringLiteral("subrip") },  { QStringLiteral("Method"), QStringLiteral("External") }},
        QJsonObject{{ QStringLiteral("Format"), QStringLiteral("ass") },     { QStringLiteral("Method"), QStringLiteral("External") }},
        QJsonObject{{ QStringLiteral("Format"), QStringLiteral("ssa") },     { QStringLiteral("Method"), QStringLiteral("External") }},
        QJsonObject{{ QStringLiteral("Format"), QStringLiteral("vtt") },     { QStringLiteral("Method"), QStringLiteral("External") }},
        QJsonObject{{ QStringLiteral("Format"), QStringLiteral("webvtt") },  { QStringLiteral("Method"), QStringLiteral("External") }},
        QJsonObject{{ QStringLiteral("Format"), QStringLiteral("pgssub") },  { QStringLiteral("Method"), QStringLiteral("Embed") }},
        QJsonObject{{ QStringLiteral("Format"), QStringLiteral("dvdsub") },  { QStringLiteral("Method"), QStringLiteral("Embed") }}});

    QJsonObject body;
    body.insert(QStringLiteral("UserId"), userId);
    body.insert(QStringLiteral("DeviceProfile"), dp);
    body.insert(QStringLiteral("EnableDirectPlay"), true);
    body.insert(QStringLiteral("EnableDirectStream"), true);
    body.insert(QStringLiteral("EnableTranscoding"), true);
    // UI 选择的音轨/字幕轨:>=0 时写入请求体,服务器按所选轨协商
    // (转码路径下输出流即含所选轨);-1 表示用服务器默认轨。
    if (audioStreamIndex >= 0)
        body.insert(QStringLiteral("AudioStreamIndex"), audioStreamIndex);
    if (subtitleStreamIndex >= 0)
        body.insert(QStringLiteral("SubtitleStreamIndex"), subtitleStreamIndex);
    // 不请求 MediaSourceId,让服务器返回所有可用版本;客户端按目标 id 挑选。
    // 若带 MediaSourceId,响应 MediaSources 会被过滤,版本列表将只剩一项。

    // 协商耗时:起播延迟诊断(网络/服务器各占多少)。
    const qint64 reqStartMs = QDateTime::currentMSecsSinceEpoch();
    postJson(key, token, userId, QStringLiteral("/Items/%1/PlaybackInfo").arg(itemId), body,
             [this, key, token, userId, itemId, mediaSourceId, seriesId, audioStreamIndex, subtitleStreamIndex, reqStartMs](const QJsonDocument &doc) {
                 qInfo() << "Emby: PlaybackInfo 耗时"
                         << (QDateTime::currentMSecsSinceEpoch() - reqStartMs) << "ms on" << key;
                 const QJsonObject o = doc.object();
                 const QJsonArray sources = o.value(QLatin1String("MediaSources")).toArray();
                 if (sources.isEmpty()) {
                     const QString msg = QStringLiteral("PlaybackInfo 未返回可用媒体源");
                     qWarning() << "Emby: 播放协商无媒体源" << itemId << "on" << key;
                     emit errorOccurred(key, msg);
                     emit playbackFailed(key, itemId, msg);
                     return;
                 }
                 // 构建版本列表供 UI 选择。
                 QVariantList mediaSources;
                 for (const QJsonValue &v : sources) {
                     const QJsonObject s = v.toObject();
                     QVariantMap m;
                     m.insert(QStringLiteral("id"), s.value(QLatin1String("Id")).toString());
                     m.insert(QStringLiteral("name"), s.value(QLatin1String("Name")).toString());
                     mediaSources.append(m);
                 }
                 // 选择目标媒体源:显式指定 > 第一个。
                 QJsonObject src;
                 if (!mediaSourceId.isEmpty()) {
                     for (const QJsonValue &v : sources) {
                         const QJsonObject s = v.toObject();
                         if (s.value(QLatin1String("Id")).toString() == mediaSourceId) {
                             src = s;
                             break;
                         }
                     }
                 }
                 if (src.isEmpty())
                     src = sources.first().toObject();

                 const QString selectedMediaSourceId = src.value(QLatin1String("Id")).toString();
                 // 服务器生成的会话 id,播放回传三件套共用(缺省则本地兜底)。
                 QString playSessionId = o.value(QLatin1String("PlaySessionId")).toString();
                 if (playSessionId.isEmpty()) {
                     playSessionId = QStringLiteral("%1-%2").arg(userId, itemId);
                     qDebug() << "Emby: PlaySessionId 缺失,本地兜底" << itemId;
                 }
                 const QStringList headers = requiredHeaders(src);

                 // 解析音轨/字幕轨。
                 QVariantList audioStreams;
                 QVariantList subtitleStreams;
                 // 所选轨以「同类序号 ordinal」传给 mpv:track-list 内封轨顺序 ==
                 // 容器顺序 == Emby MediaStreams 同类顺序,ordinal 跨两端稳定对应。
                 // ★ 不依赖响应流级 IsDefault 翻转——实测(4.9.5)服务器只更新源级
                 //   DefaultXxxStreamIndex,流级 IsDefault 保持容器原始标记。故记
                 //   index→ordinal 映射,请求 index>=0 时按它取 ordinal,否则回退
                 //   IsDefault 捕获(未显式选时即服务器默认轨)。
                 int selAudioOrdinal = -1;
                 int selSubOrdinal = -1;
                 QString selSubUrl;
                 QHash<int, int> audioOrdinalByIndex;   // 容器 Index → 同类 ordinal
                 QHash<int, int> subOrdinalByIndex;
                 QHash<int, QString> subUrlByIndex;      // 外挂字幕 Index → deliveryUrl
                 const QJsonArray streams = src.value(QLatin1String("MediaStreams")).toArray();
                 for (const QJsonValue &v : streams) {
                     const QJsonObject s = v.toObject();
                     const QString type = s.value(QLatin1String("Type")).toString();
                     QVariantMap m;
                     m.insert(QStringLiteral("index"), s.value(QLatin1String("Index")).toInt());
                     m.insert(QStringLiteral("title"), s.value(QLatin1String("Title")).toString());
                     m.insert(QStringLiteral("displayTitle"), s.value(QLatin1String("DisplayTitle")).toString());
                     m.insert(QStringLiteral("language"), s.value(QLatin1String("Language")).toString());
                     m.insert(QStringLiteral("displayLanguage"), s.value(QLatin1String("DisplayLanguage")).toString());
                     m.insert(QStringLiteral("codec"), s.value(QLatin1String("Codec")).toString());
                     m.insert(QStringLiteral("isDefault"), s.value(QLatin1String("IsDefault")).toBool());
                     m.insert(QStringLiteral("isForced"), s.value(QLatin1String("IsForced")).toBool());
                     const int contIndex = m.value(QStringLiteral("index")).toInt();
                     if (type == QLatin1String("Audio")) {
                         m.insert(QStringLiteral("channels"), s.value(QLatin1String("Channels")).toInt());
                         m.insert(QStringLiteral("channelLayout"), s.value(QLatin1String("ChannelLayout")).toString());
                         audioOrdinalByIndex.insert(contIndex, audioStreams.size());
                         if (m.value(QStringLiteral("isDefault")).toBool())
                             selAudioOrdinal = audioStreams.size(); // 默认轨兜底
                         audioStreams.append(m);
                     } else if (type == QLatin1String("Subtitle")) {
                         m.insert(QStringLiteral("isExternal"), s.value(QLatin1String("IsExternal")).toBool());
                         m.insert(QStringLiteral("deliveryUrl"), s.value(QLatin1String("DeliveryUrl")).toString());
                         m.insert(QStringLiteral("isTextSubtitleStream"), s.value(QLatin1String("IsTextSubtitleStream")).toBool());
                         subOrdinalByIndex.insert(contIndex, subtitleStreams.size());
                         if (m.value(QStringLiteral("isExternal")).toBool())
                             subUrlByIndex.insert(contIndex, m.value(QStringLiteral("deliveryUrl")).toString());
                         if (m.value(QStringLiteral("isDefault")).toBool()) {
                             selSubOrdinal = subtitleStreams.size();
                             if (m.value(QStringLiteral("isExternal")).toBool())
                                 selSubUrl = m.value(QStringLiteral("deliveryUrl")).toString();
                         }
                         subtitleStreams.append(m);
                     }
                 }
                 // 显式选择优先:按请求 index 查映射定 ordinal(覆盖 IsDefault 兜底)。
                 if (audioStreamIndex >= 0 && audioOrdinalByIndex.contains(audioStreamIndex))
                     selAudioOrdinal = audioOrdinalByIndex.value(audioStreamIndex);
                 if (subtitleStreamIndex >= 0 && subOrdinalByIndex.contains(subtitleStreamIndex)) {
                     selSubOrdinal = subOrdinalByIndex.value(subtitleStreamIndex);
                     selSubUrl = subUrlByIndex.value(subtitleStreamIndex); // 非外挂则空
                 }

                 // 补全 server 前缀,并在 URL 中附带 api_key,使 mpv 拉流无需自定义请求头。
                 const auto absUrl = [key](QString p) { return absolutePlaybackUrl(key, p); };
                 const auto withApiKey = [token](QString u) { return withApiKeyParam(token, u); };

                 // 流地址一律取自 PlaybackInfo 响应,优先顺序:
                 // DirectStreamUrl → TranscodingUrl → static 直连兜底。
                 const QString direct = src.value(QLatin1String("DirectStreamUrl")).toString();
                 const QString transcode = src.value(QLatin1String("TranscodingUrl")).toString();
                 const bool directPlay = src.value(QLatin1String("SupportsDirectPlay")).toBool();

                 QString url;
                 QString playMethod = QStringLiteral("DirectStream");
                 if (!direct.isEmpty()) {
                     url = absUrl(direct);
                 } else if (!transcode.isEmpty()) {
                     url = absUrl(transcode);
                     playMethod = QStringLiteral("Transcode");
                 } else if (directPlay) {
                     url = key + QStringLiteral("/Videos/%1/stream?static=true&MediaSourceId=%2")
                                      .arg(itemId, selectedMediaSourceId);
                 } else {
                     const QString msg = QStringLiteral("该条目无可用直连/转码方案");
                     qWarning() << "Emby: 播放协商无直连/转码方案" << itemId << "on" << key;
                     emit errorOccurred(key, msg);
                     emit playbackFailed(key, itemId, msg);
                     return;
                 }
                 url = withApiKey(url);

                 QVariantMap meta;
                 meta.insert(QStringLiteral("itemId"), itemId);
                 meta.insert(QStringLiteral("mediaSourceId"), selectedMediaSourceId);
                 meta.insert(QStringLiteral("playSessionId"), playSessionId);
                 meta.insert(QStringLiteral("playMethod"), playMethod);
                 // 回传按源路由:凭据随 meta 携带,播放窗口直接使用。
                 meta.insert(QStringLiteral("serverUrl"), key);
                 // UI 选择的轨以「同类序号 ordinal」传入 meta:mpv track-list 内封轨
                 // 顺序 == Emby MediaStreams 同类顺序,ordinal 跨两端稳定对应
                 // (不依赖容器 Index/ff-index/src-id/title,转码重排/demuxer 差异
                 // 均不受影响)。mpv file-loaded 后按 ordinal 取同类第 N 条的数字 id
                 // 选轨。selectedSubtitleOrdinal:-2=显式关;-1=未选(服务器默认)。
                 // 外挂字幕以 selectedSubtitleUrl 经 loadfile sub-file 挂,排内封后。
                 // 音轨 -2=显式关(aid no);否则用解析所得 ordinal(默认/所选)。
                 meta.insert(QStringLiteral("selectedAudioOrdinal"),
                             audioStreamIndex == -2 ? -2 : selAudioOrdinal);
                 meta.insert(QStringLiteral("selectedSubtitleOrdinal"),
                             subtitleStreamIndex == -2 ? -2 : selSubOrdinal);
                 meta.insert(QStringLiteral("selectedSubtitleUrl"),
                             selSubUrl.isEmpty() ? selSubUrl : withApiKey(absUrl(selSubUrl)));
                 meta.insert(QStringLiteral("token"), token);
                 meta.insert(QStringLiteral("userId"), userId);
                 // 剧集信息,供播放窗口切集。
                 meta.insert(QStringLiteral("seriesId"), seriesId);
                 // 版本/音轨/字幕信息,供播放窗口切换。
                 meta.insert(QStringLiteral("mediaSources"), mediaSources);
                 meta.insert(QStringLiteral("audioStreams"), audioStreams);
                 meta.insert(QStringLiteral("subtitleStreams"), subtitleStreams);

                 const auto emitReady = [this, key, headers, meta](const QString &finalUrl) {
                     qInfo() << "Emby: playback url =" << finalUrl << "method =" << meta.value("playMethod").toString();
                     emit playbackReady(key, finalUrl, QVariantList(headers.begin(), headers.end()), meta);
                 };
                 emitReady(url);
             }, QStringLiteral("播放协商"),
             [this, key, itemId] {
                 emit playbackFailed(key, itemId, QStringLiteral("播放协商请求失败"));
             });
}

void EmbyClient::setWatched(const QString &serverUrl, const QString &token, const QString &userId,
                            const QString &itemId, bool played, double positionTicks,
                            double playedPercentage)
{
    QJsonObject body;
    body.insert(QStringLiteral("Played"), played);
    body.insert(QStringLiteral("PlaybackPositionTicks"), qint64(positionTicks));
    body.insert(QStringLiteral("PlayedPercentage"),
                playedPercentage >= 0 ? playedPercentage : (played ? 100.0 : 0.0));
    postJson(serverUrl, token, userId,
             userPath(userId, QStringLiteral("/Items/%1/UserData").arg(itemId)), body,
             [](const QJsonDocument &) {}, QStringLiteral("标记已看"));
}

// ---------- 播放状态回传(按源路由:凭据随调用携带) ----------

void EmbyClient::postReport(const QString &serverUrl, const QString &token, const QString &userId,
                            const QString &endpoint, const QJsonObject &body)
{
    // 回传失败不阻断播放,仅记录日志。
    postJson(serverUrl, token, userId, endpoint, body, [](const QJsonDocument &) {},
             QStringLiteral("播放状态上报"));
}

void EmbyClient::reportPlaybackStart(const QString &serverUrl, const QString &token,
                                     const QString &userId, const QString &itemId,
                                     const QString &mediaSourceId, const QString &playSessionId,
                                     const QString &playMethod, double positionSecs)
{
    QJsonObject b;
    b.insert(QStringLiteral("ItemId"), itemId);
    b.insert(QStringLiteral("MediaSourceId"), mediaSourceId);
    b.insert(QStringLiteral("PlaySessionId"), playSessionId);
    b.insert(QStringLiteral("PositionTicks"), qint64(positionSecs * MoePlayer::kTicksPerSecond));
    b.insert(QStringLiteral("PlayMethod"), playMethod);
    b.insert(QStringLiteral("CanSeek"), true);
    b.insert(QStringLiteral("IsPaused"), false);
    b.insert(QStringLiteral("RepeatMode"), QStringLiteral("RepeatNone"));
    postReport(serverUrl, token, userId, QStringLiteral("/Sessions/Playing"), b);
}

void EmbyClient::reportPlaybackProgress(const QString &serverUrl, const QString &token,
                                        const QString &userId, const QString &itemId,
                                        const QString &mediaSourceId, const QString &playSessionId,
                                        const QString &playMethod, double positionSecs, bool paused)
{
    QJsonObject b;
    b.insert(QStringLiteral("ItemId"), itemId);
    b.insert(QStringLiteral("MediaSourceId"), mediaSourceId);
    b.insert(QStringLiteral("PlaySessionId"), playSessionId);
    b.insert(QStringLiteral("PositionTicks"), qint64(positionSecs * MoePlayer::kTicksPerSecond));
    b.insert(QStringLiteral("PlayMethod"), playMethod);
    b.insert(QStringLiteral("CanSeek"), true);
    b.insert(QStringLiteral("IsPaused"), paused);
    b.insert(QStringLiteral("RepeatMode"), QStringLiteral("RepeatNone"));
    b.insert(QStringLiteral("EventName"), QStringLiteral("timeupdate"));
    postReport(serverUrl, token, userId, QStringLiteral("/Sessions/Playing/Progress"), b);
}

void EmbyClient::reportPlaybackStopped(const QString &serverUrl, const QString &token,
                                       const QString &userId, const QString &itemId,
                                       const QString &mediaSourceId, const QString &playSessionId,
                                       double positionSecs)
{
    QJsonObject b;
    b.insert(QStringLiteral("ItemId"), itemId);
    b.insert(QStringLiteral("MediaSourceId"), mediaSourceId);
    b.insert(QStringLiteral("PlaySessionId"), playSessionId);
    b.insert(QStringLiteral("PositionTicks"), qint64(positionSecs * MoePlayer::kTicksPerSecond));
    postReport(serverUrl, token, userId, QStringLiteral("/Sessions/Playing/Stopped"), b);
}

void EmbyClient::reportPlaybackPing(const QString &serverUrl, const QString &token,
                                    const QString &userId, const QString &playSessionId)
{
    QJsonObject b;
    b.insert(QStringLiteral("PlaySessionId"), playSessionId);
    postReport(serverUrl, token, userId, QStringLiteral("/Sessions/Playing/Ping"), b);
}

