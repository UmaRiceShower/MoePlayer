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
            emit errorOccurred(what + QStringLiteral(" 失败: ") + reply->errorString()
                               + QStringLiteral(" (HTTP ") + QString::number(reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt()) + QLatin1Char(')'));
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
            emit errorOccurred(what + QStringLiteral(" 失败: ") + reply->errorString()
                               + QStringLiteral(" (HTTP ") + QString::number(reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt()) + QLatin1Char(')'));
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
    body.insert(QStringLiteral("Password"), password);
    postJson(QStringLiteral("/Users/AuthenticateByName"), body, false,
             [this](const QJsonDocument &doc) {
                 const QJsonObject o = doc.object();
                 m_accessToken = o.value(QLatin1String("AccessToken")).toString();
                 m_userId = o.value(QLatin1String("User")).toObject().value(QLatin1String("Id")).toString();
                 m_userName = o.value(QLatin1String("User")).toObject().value(QLatin1String("Name")).toString();
                 qInfo() << "Emby: logged in as" << m_userName << "token" << (m_accessToken.isEmpty() ? "EMPTY" : "set");
                 emit loginChanged();
                 emit loginSucceeded();
             }, QStringLiteral("登录"));
}

void EmbyClient::fetchViews()
{
    get(QStringLiteral("/Users/%1/Views").arg(m_userId), true, [this](const QJsonDocument &doc) {
        const QJsonArray items = doc.object().value(QLatin1String("Items")).toArray();
        m_viewsModel.setItems(items, false);
        qInfo() << "Emby: views =" << m_viewsModel.count();
        emit viewsReceived();
    }, QStringLiteral("获取媒体库视图"));
}

void EmbyClient::fetchItems(const QString &viewId)
{
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("ParentId"), viewId);
    q.addQueryItem(QStringLiteral("IncludeItemTypes"), QStringLiteral("Movie"));
    q.addQueryItem(QStringLiteral("Recursive"), QStringLiteral("true"));
    q.addQueryItem(QStringLiteral("Fields"), QStringLiteral("PrimaryImageAspectRatio"));
    get(QStringLiteral("/Users/%1/Items?%2").arg(m_userId, q.toString()), true,
        [this](const QJsonDocument &doc) {
            const QJsonArray items = doc.object().value(QLatin1String("Items")).toArray();
            m_itemsModel.setItems(items, true);
            qInfo() << "Emby: items =" << m_itemsModel.count();
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
                 bool probeRange = false;
                 if (!direct.isEmpty()) {
                     url = absUrl(direct);
                     probeRange = true;
                 } else if (!transcode.isEmpty()) {
                     url = absUrl(transcode);
                 } else if (directPlay) {
                     url = serverUrl() + QStringLiteral("/Videos/%1/stream?static=true&MediaSourceId=%2")
                                            .arg(itemId, mediaSourceId);
                     probeRange = true;
                 } else {
                     emit errorOccurred(QStringLiteral("该条目无可用直连/转码方案"));
                     return;
                 }
                 url = withApiKey(url);

                 if (probeRange) {
                     // 反代服务器可能只在 /emby/ 前缀正确处理 Range —— 探测一次并缓存。
                     // 探测失败绝不挡起播(回原 URL)。
                     probeSeekableUrl(url, [this, headers](const QString &finalUrl) {
                         qInfo() << "Emby: playback url =" << finalUrl << "headers =" << headers.size();
                         emit playbackReady(finalUrl, QVariantList(headers.begin(), headers.end()));
                     });
                 } else {
                     qInfo() << "Emby: playback url =" << url << "headers =" << headers.size();
                     emit playbackReady(url, QVariantList(headers.begin(), headers.end()));
                 }
             }, QStringLiteral("播放协商"));
}

void EmbyClient::probeRange(const QString &url, std::function<void(bool ok)> onDone)
{
    QNetworkRequest req(url);
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
    emit loginChanged();
}
