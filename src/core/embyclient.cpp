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

} // namespace

EmbyClient::EmbyClient(QObject *parent)
    : QObject(parent)
{
    // 默认直连(配置未接线时);main.cpp 按 ConfigManager.proxy 覆盖。
    // Qt 在 Linux 上不识别 no_proxy,且网络管理器会在构造时读取环境代理,
    // 故始终显式指定,避免意外走系统代理(Emby 多为局域网服务)。
    m_nam.setProxy(QNetworkProxy::NoProxy);
    m_nam.setTransferTimeout(MoePlayer::kNetworkTimeoutMs);
}

void EmbyClient::setProxy(const QNetworkProxy &proxy)
{
    m_nam.setProxy(proxy); // 对后续新请求生效
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
    return req;
}

void EmbyClient::get(const QString &serverUrl, const QString &token, const QString &userId,
                     const QString &path, std::function<void(const QJsonDocument &)> onOk,
                     std::function<void()> onFail, const QString &what)
{
    QNetworkReply *reply = m_nam.get(makeRequest(serverUrl, token, userId, path, false));
    connect(reply, &QNetworkReply::finished, this, [this, reply, serverUrl, onOk, onFail, what]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            const QString msg = what + QStringLiteral(" 失败: ") + reply->errorString()
                                + QStringLiteral(" (HTTP ") + QString::number(status) + QLatin1Char(')');
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
    QNetworkReply *reply = m_nam.post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, serverUrl, onOk, onFail, what]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            const QString msg = what + QStringLiteral(" 失败: ") + reply->errorString()
                                + QStringLiteral(" (HTTP ") + QString::number(status) + QLatin1Char(')');
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
                          std::function<void(const QJsonDocument &)> onOk, const QString &what)
{
    QNetworkReply *reply = m_nam.post(makeRequest(serverUrl, token, userId, path, true),
                                      QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, serverUrl, onOk, what]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            const QString msg = what + QStringLiteral(" 失败: ") + reply->errorString()
                                + QStringLiteral(" (HTTP ") + QString::number(status) + QLatin1Char(')');
            emit serverRequestFailed(serverUrl, msg);
            emit errorOccurred(serverUrl, msg);
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

MediaItemModel *EmbyClient::searchModelFor(const QString &serverUrl)
{
    const QString key = serverUrl.trimmed();
    if (!m_searchModels.contains(key))
        { auto *m = new MediaItemModel(this); m->setServerPrefix(AccountManager::encodeServerKey(key)); m_searchModels.insert(key, m); }
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

void EmbyClient::login(const QString &serverUrl, const QString &username, const QString &password)
{
    QJsonObject body;
    body.insert(QStringLiteral("Username"), username);
    // Emby 4.9 的 AuthenticateByName 实际接收 Pw 字段(官方 OpenAPI 文档写的是 Password,
    // 但 4.9 只认 Pw);双字段发送兼容新旧服务器。
    body.insert(QStringLiteral("Pw"), password);
    body.insert(QStringLiteral("Password"), password);
    postFrom(serverUrl, QStringLiteral("/Users/AuthenticateByName"), body,
             [this, serverUrl](const QJsonDocument &doc) {
                 const QJsonObject o = doc.object();
                 const QJsonObject u = o.value(QLatin1String("User")).toObject();
                 emit loginSucceeded(serverUrl,
                                     o.value(QLatin1String("AccessToken")).toString(),
                                     u.value(QLatin1String("Id")).toString(),
                                     u.value(QLatin1String("Name")).toString());
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
            emit serverPublicInfoReceived(
                serverUrl, doc.object().value(QLatin1String("ServerName")).toString());
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
    QNetworkReply *reply = m_nam.get(req);
    connect(reply, &QNetworkReply::finished, this,
            [this, reply, serverUrl, htmlUrl]() {
                reply->deleteLater();
                if (reply->error() != QNetworkReply::NoError) {
                    emit serverIconReceived(serverUrl, QString(), QByteArray());
                    return;
                }
                const QString iconUrl =
                    parseFaviconLink(QString::fromUtf8(reply->readAll()), htmlUrl);
                if (iconUrl.isEmpty()) {
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
    QNetworkReply *reply = m_nam.get(req);
    connect(reply, &QNetworkReply::finished, this,
            [this, reply, serverUrl, iconUrl]() {
                reply->deleteLater();
                const QByteArray data = reply->error() == QNetworkReply::NoError
                                            ? reply->readAll()
                                            : QByteArray();
                emit serverIconReceived(serverUrl, iconUrl, data);
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
                               const QString &userId)
{
    // GET /System/Info(带 token),仅 401 视为
    // token 失效(经 serverRequestFailed 通知);网络错误/超时静默不打扰。
    get(serverUrl, token, userId, QStringLiteral("/System/Info"),
        [](const QJsonDocument &) {}, nullptr, QStringLiteral("校验登录状态"));
}

// ---------- 浏览(按服务器路由) ----------

void EmbyClient::fetchViews(const QString &serverUrl, const QString &token, const QString &userId)
{
    const QString key = serverUrl.trimmed();
    get(key, token, userId, QStringLiteral("/Users/%1/Views").arg(userId),
        [this, key](const QJsonDocument &doc) {
            // 解析库海报(首页媒体库行首图用)。
            viewsModelFor(key)->setItems(doc.object().value(QLatin1String("Items")).toArray(), true);
            qInfo() << "Emby: views =" << viewsModelFor(key)->count() << "on" << key;
            emit viewsReceived(key);
        }, nullptr, QStringLiteral("获取媒体库视图"));
}

void EmbyClient::fetchItems(const QString &serverUrl, const QString &token, const QString &userId,
                            const QString &viewId, int startIndex, int limit,
                            const QString &sortBy, const QString &sortOrder,
                            const QString &genres, const QString &years,
                            const QString &minRating, const QString &filters)
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
    q.addQueryItem(QStringLiteral("StartIndex"), QString::number(qMax(0, startIndex)));
    q.addQueryItem(QStringLiteral("Limit"), QString::number(qBound(1, limit, MoePlayer::kMaxPageSize))); // Emby 单页上限 200
    const int seq = ++m_itemsSeq[key]; // 序号按服务器隔离,并行浏览不互相丢弃
    get(key, token, userId, QStringLiteral("/Users/%1/Items?%2").arg(userId, q.toString()),
        [this, key, startIndex, seq](const QJsonDocument &doc) {
            // 视图快速切换时可能已有更新的请求,过期响应直接丢弃。
            if (seq != m_itemsSeq.value(key))
                return;
            const QJsonObject o = doc.object();
            const QJsonArray items = o.value(QLatin1String("Items")).toArray();
            const int total = o.value(QLatin1String("TotalRecordCount")).toInt(0);
            MediaItemModel *model = itemsModelFor(key);
            if (startIndex == 0)
                model->setItems(items, true);
            else
                model->appendItems(items, true);
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
            genresModelFor(key)->setItems(doc.object().value(QLatin1String("Items")).toArray(), true);
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
    get(key, token, userId, QStringLiteral("/Users/%1/Items?%2").arg(userId, q.toString()),
        [this, key](const QJsonDocument &doc) {
            foldersModelFor(key)->setItems(doc.object().value(QLatin1String("Items")).toArray(), false);
            qInfo() << "Emby: folders =" << foldersModelFor(key)->count() << "on" << key;
            emit foldersReceived(key);
        }, nullptr, QStringLiteral("获取子文件夹"));
}

void EmbyClient::setFavorite(const QString &serverUrl, const QString &token, const QString &userId,
                             const QString &itemId, bool fav)
{
    const QString path = QStringLiteral("/Users/%1/FavoriteItems/%2").arg(userId, itemId);
    // POST 加收藏 / DELETE 取消;服务器返回空体,成功与否只记错误日志。
    if (fav)
        postJson(serverUrl, token, userId, path, QJsonObject(), [](const QJsonDocument &) {},
                 QStringLiteral("加入收藏"));
    else
        del(serverUrl, token, userId, path, [](const QJsonDocument &) {}, QStringLiteral("取消收藏"));
}

void EmbyClient::search(const QString &serverUrl, const QString &token, const QString &userId,
                        const QString &term, const QString &itemTypes, const QString &years,
                        const QString &filters, int startIndex, int limit)
{
    const QString key = serverUrl.trimmed();
    if (term.trimmed().isEmpty()) {
        ++m_searchSeq[key]; // 使在途响应过期
        auto *m = searchModelFor(key);
        m->clear();
        m->setHasMore(false);
        emit searchResultsReady(key);
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
    get(key, token, userId, QStringLiteral("/Users/%1/Items?%2").arg(userId, q.toString()),
        [this, key, seq, startIndex, limit](const QJsonDocument &doc) {
            // 输入防抖窗口内的旧请求结果直接丢弃。
            if (seq != m_searchSeq.value(key))
                return;
            QJsonArray arr = doc.object().value(QLatin1String("Items")).toArray();
            const bool hasMore = arr.size() > limit;
            if (hasMore) {
                QJsonArray trimmed;
                for (int i = 0; i < limit; ++i)
                    trimmed.append(arr.at(i));
                arr = trimmed;
            }
            auto *m = searchModelFor(key);
            if (startIndex == 0)
                m->setItems(arr, true);
            else
                m->appendItems(arr, true);
            m->setHasMore(hasMore);
            emit searchResultsReady(key);
        }, nullptr, QStringLiteral("搜索"));
}

void EmbyClient::fetchSeasons(const QString &serverUrl, const QString &token, const QString &userId,
                              const QString &seriesId)
{
    const QString key = serverUrl.trimmed();
    get(key, token, userId,
        QStringLiteral("/Shows/%1/Seasons?Fields=PrimaryImageAspectRatio").arg(seriesId),
        [this, key](const QJsonDocument &doc) {
            seasonsModelFor(key)->setItems(doc.object().value(QLatin1String("Items")).toArray(), true);
            qInfo() << "Emby: seasons =" << seasonsModelFor(key)->count() << "on" << key;
            emit seasonsReceived(key);
        }, nullptr, QStringLiteral("获取剧集分季"));
}

void EmbyClient::fetchEpisodes(const QString &serverUrl, const QString &token, const QString &userId,
                               const QString &seriesId, const QString &seasonId)
{
    const QString key = serverUrl.trimmed();
    get(key, token, userId,
        QStringLiteral("/Shows/%1/Episodes?SeasonId=%2&Fields=UserData,PrimaryImageAspectRatio")
            .arg(seriesId, seasonId),
        [this, key](const QJsonDocument &doc) {
            episodesModelFor(key)->setItems(doc.object().value(QLatin1String("Items")).toArray(), true);
            qInfo() << "Emby: episodes =" << episodesModelFor(key)->count() << "on" << key;
            emit episodesReceived(key);
        }, nullptr, QStringLiteral("获取分集"));
}

// ---------- 跨服务器只读拉取(首页聚合用,结果经信号返回) ----------

void EmbyClient::fetchServerViews(const QString &serverUrl, const QString &token,
                                  const QString &userId)
{
    get(serverUrl, token, userId, QStringLiteral("/Users/%1/Views").arg(userId),
        [this, serverUrl](const QJsonDocument &doc) {
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
            emit serverViewsReceived(serverUrl, out);
        },
        // 失败:发空视图推进聚合计数,原因经 serverRequestFailed 通知。
        [this, serverUrl] { emit serverViewsReceived(serverUrl, QVariantList()); },
        QStringLiteral("获取媒体库视图"));
}

void EmbyClient::fetchServerItems(const QString &serverUrl, const QString &token,
                                  const QString &userId, const QString &viewId, int limit)
{
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("ParentId"), viewId);
    // 按更新时间(文件修改时间)倒序,新更新/入库的内容靠前;
    // DateLastMediaAdded 在部分服务器条目级排序会异常,改用 DateModified。
    q.addQueryItem(QStringLiteral("SortBy"), QStringLiteral("DateModified"));
    q.addQueryItem(QStringLiteral("SortOrder"), QStringLiteral("Descending"));
    q.addQueryItem(QStringLiteral("Fields"), QStringLiteral("PrimaryImageAspectRatio"));
    q.addQueryItem(QStringLiteral("Limit"),
                   QString::number(qBound(1, limit, MoePlayer::kHomePerLibraryLimit)));
    get(serverUrl, token, userId,
        QStringLiteral("/Users/%1/Items?%2").arg(userId, q.toString()),
        [this, serverUrl, viewId](const QJsonDocument &doc) {
            QVariantList items;
            for (const auto &v : doc.object().value(QLatin1String("Items")).toArray()) {
                const QJsonObject o = v.toObject();
                const QString tag = o.value(QLatin1String("ImageTags"))
                                        .toObject().value(QLatin1String("Primary")).toString();
                QVariantMap m;
                m.insert(QStringLiteral("id"), o.value(QLatin1String("Id")).toString());
                m.insert(QStringLiteral("name"), o.value(QLatin1String("Name")).toString());
                m.insert(QStringLiteral("type"), o.value(QLatin1String("Type")).toString());
                m.insert(QStringLiteral("posterId"),
                         tag.isEmpty() ? QString()
                                       : o.value(QLatin1String("Id")).toString()
                                             + QLatin1Char('~') + tag);
                items.append(m);
            }
            emit serverItemsReceived(serverUrl, viewId, items);
        },
        // 失败:发空条目推进聚合计数,原因经 serverRequestFailed 通知。
        [this, serverUrl, viewId] { emit serverItemsReceived(serverUrl, viewId, QVariantList()); },
        QStringLiteral("获取首页行"));
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
                   QStringLiteral("Overview,Genres,ProductionYear,CommunityRating,MediaSources,UserData,People,ParentBackdropImageTags,BackdropImageTags,SeriesId,SeriesName,IndexNumber,ParentIndexNumber,SeasonId"));
    get(key, token, userId, QStringLiteral("/Users/%1/Items/%2?%3").arg(userId, itemId, q.toString()),
        [this, key](const QJsonDocument &doc) {
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
                    streams.append(sm);
                }
                vm.insert(QStringLiteral("streams"), streams);
                versions.append(vm);
            }
            m.insert(QStringLiteral("mediaSources"), versions);
            emit itemDetailReady(key, m);
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
            similarModelFor(key)->setItems(doc.object().value(QLatin1String("Items")).toArray(), true);
            qInfo() << "Emby: similar =" << similarModelFor(key)->count() << "on" << key;
            emit similarReady(key);
        }, nullptr, QStringLiteral("获取相似推荐"));
}

void EmbyClient::fetchAllEpisodes(const QString &serverUrl, const QString &token,
                                  const QString &userId, const QString &seriesId)
{
    const QString key = serverUrl.trimmed();
    // 不带 SeasonId:返回整剧全部分集(跨季),供"继续观看"按进度定位目标集。
    get(key, token, userId,
        QStringLiteral("/Shows/%1/Episodes?Fields=UserData,PrimaryImageAspectRatio").arg(seriesId),
        [this, key](const QJsonDocument &doc) {
            allEpisodesModelFor(key)->setItems(doc.object().value(QLatin1String("Items")).toArray(), true);
            qInfo() << "Emby: allEpisodes =" << allEpisodesModelFor(key)->count() << "on" << key;
            emit allEpisodesReady(key);
        }, nullptr, QStringLiteral("获取剧集全部分集"));
}


void EmbyClient::fetchPlaybackInfo(const QString &serverUrl, const QString &token,
                                   const QString &userId, const QString &itemId)
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

    postJson(key, token, userId, QStringLiteral("/Items/%1/PlaybackInfo").arg(itemId), body,
             [this, key, token, userId, itemId](const QJsonDocument &doc) {
                 const QJsonObject o = doc.object();
                 const QJsonArray sources = o.value(QLatin1String("MediaSources")).toArray();
                 if (sources.isEmpty()) {
                     emit errorOccurred(key, QStringLiteral("PlaybackInfo 未返回可用媒体源"));
                     return;
                 }
                 const QJsonObject src = sources.first().toObject();
                 const QString mediaSourceId = src.value(QLatin1String("Id")).toString();
                 // 服务器生成的会话 id,播放回传三件套共用(缺省则本地兜底)。
                 QString playSessionId = o.value(QLatin1String("PlaySessionId")).toString();
                 if (playSessionId.isEmpty())
                     playSessionId = QStringLiteral("%1-%2").arg(userId, itemId);
                 const QStringList headers = requiredHeaders(src);

                 // 补全 server 前缀,并在 URL 中附带 api_key,使 mpv 拉流无需自定义请求头。
                 const auto absUrl = [key](QString p) -> QString {
                     if (p.startsWith(QLatin1String("http")))
                         return p;
                     return key + (p.startsWith(QLatin1Char('/')) ? p : QLatin1Char('/') + p);
                 };
                 const auto withApiKey = [token](QString u) -> QString {
                     if (!token.isEmpty() && !u.contains(MoePlayer::kApiKeyParam + QLatin1Char('=')))
                         u += (u.contains(QLatin1Char('?')) ? QLatin1Char('&') : QLatin1Char('?'))
                              + MoePlayer::kApiKeyParam + QLatin1Char('=') + token;
                     return u;
                 };

                 // 流地址一律取自 PlaybackInfo 响应,优先顺序:
                 // DirectStreamUrl → TranscodingUrl → static 直连兜底。
                 const QString direct = src.value(QLatin1String("DirectStreamUrl")).toString();
                 const QString transcode = src.value(QLatin1String("TranscodingUrl")).toString();
                 const bool directPlay = src.value(QLatin1String("SupportsDirectPlay")).toBool();

                 QString url;
                 QString playMethod = QStringLiteral("DirectStream");
                 bool probeRange = false;
                 if (!direct.isEmpty()) {
                     url = absUrl(direct);
                     probeRange = true;
                 } else if (!transcode.isEmpty()) {
                     url = absUrl(transcode);
                     playMethod = QStringLiteral("Transcode");
                 } else if (directPlay) {
                     url = key + QStringLiteral("/Videos/%1/stream?static=true&MediaSourceId=%2")
                                      .arg(itemId, mediaSourceId);
                     probeRange = true;
                 } else {
                     emit errorOccurred(key, QStringLiteral("该条目无可用直连/转码方案"));
                     return;
                 }
                 url = withApiKey(url);

                 QVariantMap meta;
                 meta.insert(QStringLiteral("itemId"), itemId);
                 meta.insert(QStringLiteral("mediaSourceId"), mediaSourceId);
                 meta.insert(QStringLiteral("playSessionId"), playSessionId);
                 meta.insert(QStringLiteral("playMethod"), playMethod);
                 // 回传按源路由:凭据随 meta 携带,播放窗口直接使用。
                 meta.insert(QStringLiteral("serverUrl"), key);
                 meta.insert(QStringLiteral("token"), token);
                 meta.insert(QStringLiteral("userId"), userId);

                 const auto emitReady = [this, key, headers, meta](const QString &finalUrl) {
                     qInfo() << "Emby: playback url =" << finalUrl << "method =" << meta.value("playMethod").toString();
                     emit playbackReady(key, finalUrl, QVariantList(headers.begin(), headers.end()), meta);
                 };
                 if (probeRange) {
                     // 反代服务器可能只在 /emby/ 前缀正确处理 Range —— 探测一次并缓存。
                     // 探测失败绝不挡起播(回原 URL)。
                     probeSeekableUrl(key, token, userId, url, emitReady);
                 } else {
                     emitReady(url);
                 }
             }, QStringLiteral("播放协商"));
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
             QStringLiteral("/Users/%1/Items/%2/UserData").arg(userId, itemId), body,
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

// ---------- Range 探测(播放地址反代前缀兼容) ----------

void EmbyClient::probeRange(const QString &serverUrl, const QString &token, const QString &userId,
                            const QString &url, std::function<void(bool ok)> onDone)
{
    QNetworkRequest req(url);
    req.setRawHeader(MoePlayer::kHeaderUserAgent, MoePlayer::userAgent().toUtf8());
    req.setRawHeader("Range", "bytes=0-0"); // 只取一个字节,探测代价可忽略
    req.setRawHeader(MoePlayer::kHeaderAuth, authHeaderFor(userId, token).toUtf8());
    if (!token.isEmpty())
        req.setRawHeader(MoePlayer::kHeaderToken, token.toUtf8());
    req.setTransferTimeout(MoePlayer::kProbeTimeoutMs);
    QNetworkReply *reply = m_nam.get(req);
    connect(reply, &QNetworkReply::finished, this, [reply, onDone]() {
        const bool ok = reply->error() == QNetworkReply::NoError
                        && reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() == 206;
        reply->deleteLater();
        onDone(ok);
    });
}

void EmbyClient::probeSeekableUrl(const QString &serverUrl, const QString &token,
                                  const QString &userId, const QString &url,
                                  std::function<void(const QString &)> onDone)
{
    const QString key = serverUrl.trimmed();
    const QUrl u(url);
    const QString path = u.path();
    // 绝对地址、已带 /emby 前缀、或路径为空 → 无第二个候选
    const bool hasAlt = url.startsWith(QLatin1String("http"))
                        && !path.startsWith(QLatin1String("/emby"))
                        && path.startsWith(QLatin1Char('/'));

    if (m_rangePrefix.contains(key)) {
        const QString pre = m_rangePrefix.value(key);
        if (pre.isEmpty())
            onDone(url);
        else
            onDone(QStringLiteral("/emby") + url); // pre 为 "/emby" 时插在根路径前
        return;
    }
    // 原地址就没问题 → 别白探第二次
    probeRange(key, token, userId, url, [this, key, token, userId, url, hasAlt, onDone](bool plainOk) {
        if (plainOk) {
            m_rangePrefix.insert(key, QString());
            onDone(url);
            return;
        }
        if (!hasAlt) {
            m_rangePrefix.insert(key, QString());
            onDone(url);
            return;
        }
        const QUrl u(url);
        const QString alt = url.left(url.indexOf(u.path()))
                            + QStringLiteral("/emby") + u.path()
                            + (u.query().isEmpty() ? QString() : QStringLiteral("?") + u.query());
        probeRange(key, token, userId, alt, [this, key, url, alt, onDone](bool embyOk) {
            // 两条都不认 → 保持原样(换前缀只是换一种坏法)
            m_rangePrefix.insert(key, embyOk ? QStringLiteral("/emby") : QString());
            onDone(embyOk ? alt : url);
        });
    });
}
