#include "embyclient.h"

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
    m_nam.setTransferTimeout(10000);

    // WebSocket 长连接:断线自动重连(3s 起指数退避至 30s)。
    // 保活由 QWebSocket 协议层处理(Emby 4.9 不发 Ping,收到时回 Pong 即可)。
    m_ws.setProxy(QNetworkProxy::NoProxy);
    connect(&m_ws, &QWebSocket::connected, this, [this] {
        m_wsReconnectDelay = 3000;
        qInfo() << "Emby: websocket connected";
        emit wsConnectedChanged();
    });
    connect(&m_ws, &QWebSocket::disconnected, this, [this] {
        qInfo() << "Emby: websocket disconnected";
        emit wsConnectedChanged();
        if (connected() && !m_wsReconnect.isActive())
            m_wsReconnect.start();
    });
    connect(&m_ws, &QWebSocket::textMessageReceived, this,
            [this](const QString &message) { handleWsMessage(QJsonDocument::fromJson(message.toUtf8()).object()); });
    m_wsReconnect.setSingleShot(true);
    connect(&m_wsReconnect, &QTimer::timeout, this, [this] {
        connectWebSocket();
        m_wsReconnectDelay = qMin(m_wsReconnectDelay * 2, 30000);
    });
}

void EmbyClient::setServerUrl(const QString &v)
{
    QString clean = v.trimmed();
    while (clean.endsWith(QLatin1Char('/')))
        clean.chop(1);
    if (clean == serverUrl())
        return;
    m_settings.setValue(QStringLiteral("network/serverUrl"), clean);
    emit serverUrlChanged();
}

QString EmbyClient::authHeader(bool withToken) const
{
    QString h = QStringLiteral("Emby UserId=\"%1\", Client=\"MoePlayer\", Device=\"Desktop\", "
                               "DeviceId=\"%2\", Version=\"0.1.0\"")
                    .arg(m_userId, deviceId());
    if (withToken && !m_accessToken.isEmpty())
        h += QStringLiteral(", Token=\"%1\"").arg(m_accessToken);
    return h;
}

QNetworkRequest EmbyClient::makeRequest(const QString &path, bool auth, bool json) const
{
    QNetworkRequest req(QUrl(serverUrl() + path));
    // 统一 UA(软件名/版本号),不用 Qt 默认 UA。
    req.setRawHeader("User-Agent",
                     (QStringLiteral("MoePlayer/") + QCoreApplication::applicationVersion()).toUtf8());
    req.setRawHeader("X-Emby-Authorization", authHeader(auth).toUtf8());
    // 官方文档(dev.emby.media User-Authentication)规定登录后的 AccessToken
    // 用 X-Emby-Token 头发送,同时保留 X-Emby-Authorization 以兼容按该头认证的服务器。
    if (auth && !m_accessToken.isEmpty())
        req.setRawHeader("X-Emby-Token", m_accessToken.toUtf8());
    if (json)
        req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    req.setTransferTimeout(10000);
    return req;
}

void EmbyClient::get(const QString &path, bool auth,
                     std::function<void(const QJsonDocument &)> onOk, const QString &what)
{
    QNetworkReply *reply = m_nam.get(makeRequest(path, auth));
    connect(reply, &QNetworkReply::finished, this, [this, reply, onOk, what]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            if (status == 401)
                emit authFailed();
            emit errorOccurred(what + QStringLiteral(" 失败: ") + reply->errorString()
                               + QStringLiteral(" (HTTP ") + QString::number(status) + QLatin1Char(')'));
            return;
        }
        onOk(QJsonDocument::fromJson(reply->readAll()));
    });
}

void EmbyClient::postJson(const QString &path, const QJsonObject &body, bool auth,
                          std::function<void(const QJsonDocument &)> onOk, const QString &what)
{
    QNetworkReply *reply = m_nam.post(makeRequest(path, auth, true),
                                      QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, onOk, what]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            if (status == 401)
                emit authFailed();
            emit errorOccurred(what + QStringLiteral(" 失败: ") + reply->errorString()
                               + QStringLiteral(" (HTTP ") + QString::number(status) + QLatin1Char(')'));
            return;
        }
        onOk(QJsonDocument::fromJson(reply->readAll()));
    });
}

void EmbyClient::fetchPublicInfo()
{
    get(QStringLiteral("/System/Info/Public"), false, [this](const QJsonDocument &doc) {
        const QJsonObject o = doc.object();
        m_serverName = o.value(QLatin1String("ServerName")).toString();
        m_serverVersion = o.value(QLatin1String("Version")).toString();
        qInfo() << "Emby: server" << m_serverName << "v" << m_serverVersion;
        emit serverInfoChanged();
        emit publicInfoReceived();
    }, QStringLiteral("获取服务器信息"));
}

void EmbyClient::login(const QString &username, const QString &password)
{
    QJsonObject body;
    body.insert(QStringLiteral("Username"), username);
    // Emby 4.9 的 AuthenticateByName 实际接收 Pw 字段(官方 OpenAPI 文档写的是 Password,
    // 但 4.9 只认 Pw);双字段发送兼容新旧服务器。
    body.insert(QStringLiteral("Pw"), password);
    body.insert(QStringLiteral("Password"), password);
    postJson(QStringLiteral("/Users/AuthenticateByName"), body, false,
             [this](const QJsonDocument &doc) {
                 const QJsonObject o = doc.object();
                 m_accessToken = o.value(QLatin1String("AccessToken")).toString();
                 m_userId = o.value(QLatin1String("User")).toObject().value(QLatin1String("Id")).toString();
                 m_userName = o.value(QLatin1String("User")).toObject().value(QLatin1String("Name")).toString();
                 qInfo() << "Emby: logged in as" << m_userName << "token" << (m_accessToken.isEmpty() ? "EMPTY" : "set");
                 emit loginChanged();
                 if (!m_accessToken.isEmpty())
                     connectWebSocket();
                 emit loginSucceeded();
             }, QStringLiteral("登录"));
}

void EmbyClient::fetchViews()
{
    get(QStringLiteral("/Users/%1/Views").arg(m_userId), true, [this](const QJsonDocument &doc) {
        const QJsonArray items = doc.object().value(QLatin1String("Items")).toArray();
        // 解析库海报(首页媒体库行首图用)。
        m_viewsModel.setItems(items, true);
        qInfo() << "Emby: views =" << m_viewsModel.count();
        emit viewsReceived();
    }, QStringLiteral("获取媒体库视图"));
}

// ---------- 会话配置(多账号切换/启动自动登录) ----------

void EmbyClient::configureSession(const QString &serverUrl, const QString &token,
                                  const QString &userId, const QString &userName)
{
    setServerUrl(serverUrl);
    m_accessToken = token;
    m_userId = userId;
    m_userName = userName;
    m_itemsModel.clear();
    m_viewsModel.clear();
    if (!token.isEmpty())
        connectWebSocket();
    emit loginChanged();
    // 直接拉视图:请求 401 时 get 失败发 authFailed,即 token 失效。
    qInfo() << "Emby: session configured as" << m_userName;
    fetchViews();
}

void EmbyClient::fetchItems(const QString &viewId, int startIndex, int limit)
{
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("ParentId"), viewId);
    // 不限制类型、不递归:返回库的顶层条目(Movies→Movie,TV Shows→Series,
    // Home Videos/Music Videos→Movie),分页与 TotalRecordCount 仍适用。
    q.addQueryItem(QStringLiteral("Fields"), QStringLiteral("PrimaryImageAspectRatio"));
    q.addQueryItem(QStringLiteral("StartIndex"), QString::number(qMax(0, startIndex)));
    q.addQueryItem(QStringLiteral("Limit"), QString::number(qBound(1, limit, 200))); // Emby 单页上限 200
    const int seq = ++m_itemsSeq;
    get(QStringLiteral("/Users/%1/Items?%2").arg(m_userId, q.toString()), true,
        [this, startIndex, seq](const QJsonDocument &doc) {
            // 视图快速切换时可能已有更新的请求,过期响应直接丢弃。
            if (seq != m_itemsSeq)
                return;
            const QJsonObject o = doc.object();
            const QJsonArray items = o.value(QLatin1String("Items")).toArray();
            const int total = o.value(QLatin1String("TotalRecordCount")).toInt(0);
            if (startIndex == 0)
                m_itemsModel.setItems(items, true);
            else
                m_itemsModel.appendItems(items, true);
            m_itemsModel.setTotal(total);
            qInfo() << "Emby: items =" << m_itemsModel.count() << "/" << total;
            emit itemsReceived();
        }, QStringLiteral("获取媒体库条目"));
}

void EmbyClient::fetchPlaybackInfo(const QString &itemId)
{
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
    body.insert(QStringLiteral("UserId"), m_userId);
    body.insert(QStringLiteral("DeviceProfile"), dp);
    body.insert(QStringLiteral("EnableDirectPlay"), true);
    body.insert(QStringLiteral("EnableDirectStream"), true);
    body.insert(QStringLiteral("EnableTranscoding"), true);

    postJson(QStringLiteral("/Items/%1/PlaybackInfo").arg(itemId), body, true,
             [this, itemId](const QJsonDocument &doc) {
                 const QJsonObject o = doc.object();
                 const QJsonArray sources = o.value(QLatin1String("MediaSources")).toArray();
                 if (sources.isEmpty()) {
                     emit errorOccurred(QStringLiteral("PlaybackInfo 未返回可用媒体源"));
                     return;
                 }
                 const QJsonObject src = sources.first().toObject();
                 const QString mediaSourceId = src.value(QLatin1String("Id")).toString();
                 // 服务器生成的会话 id,播放回传三件套共用(缺省则本地兜底)。
                 QString playSessionId = o.value(QLatin1String("PlaySessionId")).toString();
                 if (playSessionId.isEmpty())
                     playSessionId = QStringLiteral("%1-%2").arg(m_userId, itemId);
                 const QStringList headers = requiredHeaders(src);

                 // 补全 server 前缀,并在 URL 中附带 api_key,使 mpv 拉流无需自定义请求头。
                 const auto absUrl = [this](QString p) -> QString {
                     if (p.startsWith(QLatin1String("http")))
                         return p;
                     return serverUrl() + (p.startsWith(QLatin1Char('/')) ? p : QLatin1Char('/') + p);
                 };
                 const auto withApiKey = [this](QString u) -> QString {
                     if (!m_accessToken.isEmpty() && !u.contains(QLatin1String("api_key=")))
                         u += (u.contains(QLatin1Char('?')) ? QLatin1Char('&') : QLatin1Char('?'))
                              + QStringLiteral("api_key=") + m_accessToken;
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
                     url = serverUrl() + QStringLiteral("/Videos/%1/stream?static=true&MediaSourceId=%2")
                                            .arg(itemId, mediaSourceId);
                     probeRange = true;
                 } else {
                     emit errorOccurred(QStringLiteral("该条目无可用直连/转码方案"));
                     return;
                 }
                 url = withApiKey(url);

                 QVariantMap meta;
                 meta.insert(QStringLiteral("itemId"), itemId);
                 meta.insert(QStringLiteral("mediaSourceId"), mediaSourceId);
                 meta.insert(QStringLiteral("playSessionId"), playSessionId);
                 meta.insert(QStringLiteral("playMethod"), playMethod);

                 const auto emitReady = [this, headers, meta](const QString &finalUrl) {
                     qInfo() << "Emby: playback url =" << finalUrl << "method =" << meta.value("playMethod").toString();
                     emit playbackReady(finalUrl, QVariantList(headers.begin(), headers.end()), meta);
                 };
                 if (probeRange) {
                     // 反代服务器可能只在 /emby/ 前缀正确处理 Range —— 探测一次并缓存。
                     // 探测失败绝不挡起播(回原 URL)。
                     probeSeekableUrl(url, emitReady);
                 } else {
                     emitReady(url);
                 }
             }, QStringLiteral("播放协商"));
}

void EmbyClient::fetchItemDetail(const QString &itemId)
{
    QUrlQuery q;
    // UserData 携带已看状态与播放位置(继续观看数据源)。
    q.addQueryItem(QStringLiteral("Fields"),
                   QStringLiteral("Overview,Genres,ProductionYear,CommunityRating,MediaSources,UserData"));
    get(QStringLiteral("/Users/%1/Items/%2?%3").arg(m_userId, itemId, q.toString()), true,
        [this](const QJsonDocument &doc) {
            const QJsonObject o = doc.object();
            const QJsonObject ud = o.value(QLatin1String("UserData")).toObject();
            QVariantMap m;
            m.insert(QStringLiteral("id"), o.value(QLatin1String("Id")).toString());
            m.insert(QStringLiteral("name"), o.value(QLatin1String("Name")).toString());
            m.insert(QStringLiteral("type"), o.value(QLatin1String("Type")).toString());
            m.insert(QStringLiteral("year"), o.value(QLatin1String("ProductionYear")).toInt(0));
            m.insert(QStringLiteral("rating"), o.value(QLatin1String("CommunityRating")).toDouble(0));
            m.insert(QStringLiteral("runtimeSecs"), o.value(QLatin1String("RunTimeTicks")).toDouble(0) / 1e7);
            m.insert(QStringLiteral("overview"), o.value(QLatin1String("Overview")).toString());
            // 继续观看:上次停止位置(100ns ticks),未看或已播完为 0。
            m.insert(QStringLiteral("positionTicks"), ud.value(QLatin1String("PlaybackPositionTicks")).toDouble(0));
            m.insert(QStringLiteral("played"), ud.value(QLatin1String("Played")).toBool(false));
            QVariantList genres;
            for (const auto &g : o.value(QLatin1String("Genres")).toArray())
                genres.append(g.toString());
            m.insert(QStringLiteral("genres"), genres);
            emit itemDetailReady(m);
        }, QStringLiteral("获取条目详情"));
}

void EmbyClient::setWatched(const QString &itemId, bool played, double positionTicks,
                            double playedPercentage)
{
    QJsonObject body;
    body.insert(QStringLiteral("Played"), played);
    body.insert(QStringLiteral("PlaybackPositionTicks"), qint64(positionTicks));
    body.insert(QStringLiteral("PlayedPercentage"),
                playedPercentage >= 0 ? playedPercentage : (played ? 100.0 : 0.0));
    postJson(QStringLiteral("/Users/%1/Items/%2/UserData").arg(m_userId, itemId), body, true,
             [](const QJsonDocument &) {}, QStringLiteral("标记已看"));
}

// ---------- 首页聚合(每库按加入时间取前 N 条) ----------

void EmbyClient::fetchHomeRows(int perLibraryLimit)
{
    m_homeRows.clear();
    const int n = m_viewsModel.count();
    if (n == 0) {
        emit homeRowsReceived();
        return;
    }
    m_homeRowsPending = n;
    const int limit = qBound(1, perLibraryLimit, 20);
    for (int i = 0; i < n; ++i) {
        const QString viewId = m_viewsModel.idAt(i);
        const QString viewName = m_viewsModel.nameAt(i);
        const QString viewPoster = m_viewsModel.posterIdAt(i);
        QUrlQuery q;
        q.addQueryItem(QStringLiteral("ParentId"), viewId);
        q.addQueryItem(QStringLiteral("SortBy"), QStringLiteral("DateCreated"));
        q.addQueryItem(QStringLiteral("SortOrder"), QStringLiteral("Descending"));
        q.addQueryItem(QStringLiteral("Fields"), QStringLiteral("PrimaryImageAspectRatio"));
        q.addQueryItem(QStringLiteral("Limit"), QString::number(limit));
        get(QStringLiteral("/Users/%1/Items?%2").arg(m_userId, q.toString()), true,
            [this, viewId, viewName, viewPoster](const QJsonDocument &doc) {
                QVariantMap row;
                row.insert(QStringLiteral("viewId"), viewId);
                row.insert(QStringLiteral("viewName"), viewName);
                row.insert(QStringLiteral("posterId"), viewPoster);
                QVariantList items;
                for (const auto &v : doc.object().value(QLatin1String("Items")).toArray()) {
                    const QJsonObject o = v.toObject();
                    const QString tag = o.value(QLatin1String("ImageTags")).toObject()
                                            .value(QLatin1String("Primary")).toString();
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
                row.insert(QStringLiteral("items"), items);
                m_homeRows.append(row);
                if (--m_homeRowsPending <= 0)
                    emit homeRowsReceived();
            }, QStringLiteral("获取首页行"));
    }
}

// ---------- 剧集导航(/Shows/{id}/Seasons + Episodes) ----------

void EmbyClient::fetchSeasons(const QString &seriesId)
{
    get(QStringLiteral("/Shows/%1/Seasons?Fields=PrimaryImageAspectRatio").arg(seriesId), true,
        [this](const QJsonDocument &doc) {
            m_seasonsModel.setItems(doc.object().value(QLatin1String("Items")).toArray(), true);
            qInfo() << "Emby: seasons =" << m_seasonsModel.count();
            emit seasonsReceived();
        }, QStringLiteral("获取剧集分季"));
}

void EmbyClient::fetchEpisodes(const QString &seriesId, const QString &seasonId)
{
    get(QStringLiteral("/Shows/%1/Episodes?SeasonId=%2&Fields=PrimaryImageAspectRatio")
            .arg(seriesId, seasonId),
        true, [this](const QJsonDocument &doc) {
            m_episodesModel.setItems(doc.object().value(QLatin1String("Items")).toArray(), true);
            qInfo() << "Emby: episodes =" << m_episodesModel.count();
            emit episodesReceived();
        }, QStringLiteral("获取分集"));
}

// ---------- WebSocket 实时通道(/embywebsocket) ----------
QString EmbyClient::webSocketUrl() const
{
    QUrl u(serverUrl());
    u.setScheme(u.scheme() == QLatin1String("https") ? QStringLiteral("wss") : QStringLiteral("ws"));
    u.setPath(QStringLiteral("/embywebsocket"));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("api_key"), m_accessToken);
    u.setQuery(q);
    return u.toString();
}

void EmbyClient::connectWebSocket()
{
    if (m_ws.state() == QAbstractSocket::ConnectedState
        || m_ws.state() == QAbstractSocket::ConnectingState)
        return;
    m_ws.open(QUrl(webSocketUrl()));
}

void EmbyClient::handleWsMessage(const QJsonObject &msg)
{
    const QString type = msg.value(QLatin1String("MessageType")).toString();
    const QJsonObject data = msg.value(QLatin1String("Data")).toObject();
    if (type.isEmpty())
        return;
    // 服务器保活探测 → 回 Pong(Emby 4.9 不发 Ping,保留兼容旧版)。
    if (type == QLatin1String("Ping")) {
        m_ws.sendTextMessage(QStringLiteral("{\"MessageType\":\"Pong\"}"));
        return;
    }
    // 已看状态变化(其他客户端标记/本客户端播完自动标记)与库变化:广播给全部 WS 连接。
    qInfo() << "Emby: ws event" << type;
    if (type == QLatin1String("UserDataChanged") || type == QLatin1String("LibraryChanged")
        || type == QLatin1String("RefreshProgress"))
        emit serverEventReceived(type, data.toVariantMap());
}

// ---------- 播放状态回传(/Sessions/Playing 三件套 + Ping) ----------

void EmbyClient::postReport(const QString &endpoint, const QJsonObject &body)
{
    // 回传失败不阻断播放,仅记录日志。
    postJson(endpoint, body, true, [](const QJsonDocument &) {}, QStringLiteral("播放状态上报"));
}

void EmbyClient::reportPlaybackStart(const QString &itemId, const QString &mediaSourceId,
                                     const QString &playSessionId, const QString &playMethod,
                                     double positionSecs)
{
    QJsonObject b;
    b.insert(QStringLiteral("ItemId"), itemId);
    b.insert(QStringLiteral("MediaSourceId"), mediaSourceId);
    b.insert(QStringLiteral("PlaySessionId"), playSessionId);
    b.insert(QStringLiteral("PositionTicks"), qint64(positionSecs * 1e7));
    b.insert(QStringLiteral("PlayMethod"), playMethod);
    b.insert(QStringLiteral("CanSeek"), true);
    b.insert(QStringLiteral("IsPaused"), false);
    b.insert(QStringLiteral("RepeatMode"), QStringLiteral("RepeatNone"));
    postReport(QStringLiteral("/Sessions/Playing"), b);
}

void EmbyClient::reportPlaybackProgress(const QString &itemId, const QString &mediaSourceId,
                                        const QString &playSessionId, const QString &playMethod,
                                        double positionSecs, bool paused)
{
    QJsonObject b;
    b.insert(QStringLiteral("ItemId"), itemId);
    b.insert(QStringLiteral("MediaSourceId"), mediaSourceId);
    b.insert(QStringLiteral("PlaySessionId"), playSessionId);
    b.insert(QStringLiteral("PositionTicks"), qint64(positionSecs * 1e7));
    b.insert(QStringLiteral("PlayMethod"), playMethod);
    b.insert(QStringLiteral("CanSeek"), true);
    b.insert(QStringLiteral("IsPaused"), paused);
    b.insert(QStringLiteral("RepeatMode"), QStringLiteral("RepeatNone"));
    b.insert(QStringLiteral("EventName"), QStringLiteral("timeupdate"));
    postReport(QStringLiteral("/Sessions/Playing/Progress"), b);
}

void EmbyClient::reportPlaybackStopped(const QString &itemId, const QString &mediaSourceId,
                                       const QString &playSessionId, double positionSecs)
{
    QJsonObject b;
    b.insert(QStringLiteral("ItemId"), itemId);
    b.insert(QStringLiteral("MediaSourceId"), mediaSourceId);
    b.insert(QStringLiteral("PlaySessionId"), playSessionId);
    b.insert(QStringLiteral("PositionTicks"), qint64(positionSecs * 1e7));
    postReport(QStringLiteral("/Sessions/Playing/Stopped"), b);
}

void EmbyClient::reportPlaybackPing(const QString &playSessionId)
{
    QJsonObject b;
    b.insert(QStringLiteral("PlaySessionId"), playSessionId);
    postReport(QStringLiteral("/Sessions/Playing/Ping"), b);
}

void EmbyClient::probeRange(const QString &url, std::function<void(bool ok)> onDone)
{
    QNetworkRequest req(url);
    req.setRawHeader("User-Agent",
                     (QStringLiteral("MoePlayer/") + QCoreApplication::applicationVersion()).toUtf8());
    req.setRawHeader("Range", "bytes=0-0"); // 只取一个字节,探测代价可忽略
    req.setRawHeader("X-Emby-Authorization", authHeader(true).toUtf8());
    if (!m_accessToken.isEmpty())
        req.setRawHeader("X-Emby-Token", m_accessToken.toUtf8());
    req.setTransferTimeout(5000);
    QNetworkReply *reply = m_nam.get(req);
    connect(reply, &QNetworkReply::finished, this, [reply, onDone]() {
        const bool ok = reply->error() == QNetworkReply::NoError
                        && reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() == 206;
        reply->deleteLater();
        onDone(ok);
    });
}

void EmbyClient::probeSeekableUrl(const QString &url, std::function<void(const QString &)> onDone)
{
    const QUrl u(url);
    const QString path = u.path();
    // 绝对地址、已带 /emby 前缀、或路径为空 → 无第二个候选
    const bool hasAlt = url.startsWith(QLatin1String("http"))
                        && !path.startsWith(QLatin1String("/emby"))
                        && path.startsWith(QLatin1Char('/'));
    const auto cacheKey = serverUrl();

    if (m_rangePrefix.contains(cacheKey)) {
        const QString pre = m_rangePrefix.value(cacheKey);
        if (pre.isEmpty())
            onDone(url);
        else
            onDone(QStringLiteral("/emby") + url); // pre 为 "/emby" 时插在根路径前
        return;
    }
    // 原地址就没问题 → 别白探第二次
    probeRange(url, [this, url, hasAlt, cacheKey, onDone](bool plainOk) {
        if (plainOk) {
            m_rangePrefix.insert(cacheKey, QString());
            onDone(url);
            return;
        }
        if (!hasAlt) {
            m_rangePrefix.insert(cacheKey, QString());
            onDone(url);
            return;
        }
        const QUrl u(url);
        const QString alt = url.left(url.indexOf(u.path()))
                            + QStringLiteral("/emby") + u.path()
                            + (u.query().isEmpty() ? QString() : QStringLiteral("?") + u.query());
        probeRange(alt, [this, url, alt, cacheKey, onDone](bool embyOk) {
            // 两条都不认 → 保持原样(换前缀只是换一种坏法)
            m_rangePrefix.insert(cacheKey, embyOk ? QStringLiteral("/emby") : QString());
            onDone(embyOk ? alt : url);
        });
    });
}

void EmbyClient::disconnectServer()
{
    m_accessToken.clear();
    m_userId.clear();
    m_userName.clear();
    m_itemsModel.clear();
    m_viewsModel.clear();
    m_ws.close();
    m_wsReconnect.stop();
    emit loginChanged();
}
