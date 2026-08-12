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
    // Emby 为局域网服务,不走系统代理(http_proxy);Qt 在 Linux 上不识别 no_proxy,
    // 且网络管理器会在构造时读取环境代理,故此处显式指定 NoProxy。
    m_nam.setProxy(QNetworkProxy::NoProxy);
    m_nam.setTransferTimeout(MoePlayer::kNetworkTimeoutMs);
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

void EmbyClient::dropServerModels(const QString &serverUrl)
{
    const QString key = serverUrl.trimmed();
    delete m_viewsModels.take(key);
    delete m_itemsModels.take(key);
    delete m_seasonsModels.take(key);
    delete m_episodesModels.take(key);
    delete m_searchModels.take(key);
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

void EmbyClient::fetchServerPublicInfo(const QString &serverUrl)
{
    get(serverUrl, QString(), QString(), QStringLiteral("/System/Info/Public"),
        [this, serverUrl](const QJsonDocument &doc) {
            emit serverPublicInfoReceived(
                serverUrl, doc.object().value(QLatin1String("ServerName")).toString());
        }, nullptr, QStringLiteral("获取服务器信息"));
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
                            const QString &sortBy, const QString &sortOrder)
{
    const QString key = serverUrl.trimmed();
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("ParentId"), viewId);
    // 不限制类型、不递归:返回库的顶层条目(Movies→Movie,TV Shows→Series,
    // Home Videos/Music Videos→Movie),分页与 TotalRecordCount 仍适用。
    // UserData 携带已看/进度/未看集数/收藏,评分/年份供卡片角标,零额外请求。
    q.addQueryItem(QStringLiteral("Fields"), MoePlayer::kListFields);
    q.addQueryItem(QStringLiteral("SortBy"), sortBy);
    q.addQueryItem(QStringLiteral("SortOrder"), sortOrder);
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
                        const QString &term)
{
    const QString key = serverUrl.trimmed();
    if (term.trimmed().isEmpty()) {
        ++m_searchSeq[key]; // 使在途响应过期
        searchModelFor(key)->clear();
        emit searchResultsReady(key);
        return;
    }
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("SearchTerm"), term);
    // 跨库递归搜索影片/剧集/单集;UserData 携带已看/进度/收藏,结果卡片零额外请求。
    q.addQueryItem(QStringLiteral("Recursive"), QStringLiteral("true"));
    q.addQueryItem(QStringLiteral("IncludeItemTypes"), QStringLiteral("Movie,Series,Episode"));
    q.addQueryItem(QStringLiteral("Fields"), MoePlayer::kListFields);
    q.addQueryItem(QStringLiteral("Limit"), QString::number(MoePlayer::kSearchLimit));
    q.addQueryItem(QStringLiteral("SortBy"), QStringLiteral("SortName"));
    const int seq = ++m_searchSeq[key];
    get(key, token, userId, QStringLiteral("/Users/%1/Items?%2").arg(userId, q.toString()),
        [this, key, seq](const QJsonDocument &doc) {
            // 输入防抖窗口内的旧请求结果直接丢弃。
            if (seq != m_searchSeq.value(key))
                return;
            const QJsonObject o = doc.object();
            searchModelFor(key)->setItems(o.value(QLatin1String("Items")).toArray(), true);
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
        QStringLiteral("/Shows/%1/Episodes?SeasonId=%2&Fields=PrimaryImageAspectRatio")
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
    // UserData 携带已看状态与播放位置(继续观看数据源)。
    q.addQueryItem(QStringLiteral("Fields"),
                   QStringLiteral("Overview,Genres,ProductionYear,CommunityRating,MediaSources,UserData"));
    get(key, token, userId, QStringLiteral("/Users/%1/Items/%2?%3").arg(userId, itemId, q.toString()),
        [this, key, itemId](const QJsonDocument &doc) {
            const QJsonObject o = doc.object();
            const QJsonObject ud = o.value(QLatin1String("UserData")).toObject();
            QVariantMap m;
            m.insert(QStringLiteral("id"), o.value(QLatin1String("Id")).toString());
            m.insert(QStringLiteral("name"), o.value(QLatin1String("Name")).toString());
            m.insert(QStringLiteral("type"), o.value(QLatin1String("Type")).toString());
            m.insert(QStringLiteral("year"), o.value(QLatin1String("ProductionYear")).toInt(0));
            m.insert(QStringLiteral("rating"), o.value(QLatin1String("CommunityRating")).toDouble(0));
            m.insert(QStringLiteral("runtimeSecs"), o.value(QLatin1String("RunTimeTicks")).toDouble(0) / MoePlayer::kTicksPerSecond);
            m.insert(QStringLiteral("overview"), o.value(QLatin1String("Overview")).toString());
            // 继续观看:上次停止位置(100ns ticks),未看或已播完为 0。
            m.insert(QStringLiteral("positionTicks"), ud.value(QLatin1String("PlaybackPositionTicks")).toDouble(0));
            m.insert(QStringLiteral("played"), ud.value(QLatin1String("Played")).toBool(false));
            QVariantList genres;
            for (const auto &g : o.value(QLatin1String("Genres")).toArray())
                genres.append(g.toString());
            m.insert(QStringLiteral("genres"), genres);
            emit itemDetailReady(key, m);
        }, nullptr, QStringLiteral("获取条目详情"));
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
