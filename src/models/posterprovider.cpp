#include "posterprovider.h"

#include <QNetworkReply>
#include <QNetworkRequest>
#include <QNetworkProxy>
#include <QQuickTextureFactory>
#include <QStandardPaths>
#include <QUrlQuery>
#include <QDebug>

#include "core/embyclient.h"

PosterProvider::PosterProvider(EmbyClient *client)
    : m_client(client)
{
}

QQuickImageResponse *PosterProvider::requestImageResponse(const QString &id,
                                                          const QSize &requestedSize)
{
    // id = "<itemId>~<tag>",分隔符用 ~ 而非 |(| 在 image:// URL 中会被转义为
    // %7C,导致按错误 id 查询);再做一次百分号解码以防万一。
    const int sep = id.indexOf(QLatin1Char('~'));
    const QString rawItem = sep > 0 ? id.left(sep) : id;
    const QString itemId = QUrl::fromPercentEncoding(rawItem.toUtf8());
    const QString tag = sep > 0 ? id.mid(sep + 1) : QString();

    QUrlQuery q;
    q.addQueryItem(QStringLiteral("maxWidth"), QString::number(qMax(requestedSize.width(), 320)));
    if (!tag.isEmpty())
        q.addQueryItem(QStringLiteral("tag"), tag);
    if (!m_client->accessToken().isEmpty())
        q.addQueryItem(QStringLiteral("api_key"), m_client->accessToken());

    const QUrl url(m_client->serverUrl() + QStringLiteral("/Items/%1/Images/Primary?%2")
                                           .arg(itemId, q.toString()));
    return new PosterResponse(url);
}

PosterResponse::PosterResponse(const QUrl &url)
{
    // 本对象在 QML 图片加载线程创建,网络管理器与磁盘缓存也在该线程
    // 创建并使用,避免跨线程操作(共享主线程 QNAM 属未定义行为)。
    m_cache.setCacheDirectory(QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
                              + QStringLiteral("/emby-images"));
    m_nam.setCache(&m_cache);
    m_nam.setProxy(QNetworkProxy::NoProxy); // Emby 为局域网服务,不走系统代理(同 EmbyClient)
    m_nam.setTransferTimeout(10000);

    QNetworkRequest req(url);
    req.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::PreferCache);
    m_reply = m_nam.get(req);
    connect(m_reply, &QNetworkReply::finished, this, [this]() {
        if (m_reply->error() == QNetworkReply::NoError) {
            if (!m_image.loadFromData(m_reply->readAll()))
                m_error = QStringLiteral("图片解码失败");
        } else {
            m_error = m_reply->errorString();
        }
        m_reply->deleteLater();
        m_reply = nullptr;
        emit finished();
    });
}

PosterResponse::~PosterResponse()
{
    if (m_reply) {
        m_reply->abort();
        m_reply->deleteLater();
    }
}

QQuickTextureFactory *PosterResponse::textureFactory() const
{
    return QQuickTextureFactory::textureFactoryForImage(m_image);
}

QString PosterResponse::errorString() const
{
    return m_error;
}
