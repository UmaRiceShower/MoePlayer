#include "posterprovider.h"

#include <QNetworkReply>
#include <QNetworkRequest>
#include <QNetworkProxy>
#include <QQuickTextureFactory>
#include <QStandardPaths>
#include <QUrlQuery>
#include <QDebug>
#include <QCoreApplication>

#include "core/embyclient.h"
#include "core/accountmanager.h"

PosterProvider::PosterProvider(EmbyClient *client, AccountManager *accounts)
    : m_client(client)
    , m_accounts(accounts)
{
}

QQuickImageResponse *PosterProvider::requestImageResponse(const QString &id,
                                                          const QSize &requestedSize)
{
    // id 两种格式(见头文件):含两个 ~ 为跨服务器格式,第一个 ~ 前是
    // Base64URL 编码的服务器地址;否则为会话内格式(itemId~tag)。
    // 分隔符用 ~ 而非 |(| 在 image:// URL 中会被转义为 %7C)。
    QString serverUrl = m_client->serverUrl();
    QString token = m_client->accessToken();
    QString itemId;
    QString tag;
    if (id.count(QLatin1Char('~')) >= 2) {
        const int s1 = id.indexOf(QLatin1Char('~'));
        const int s2 = id.indexOf(QLatin1Char('~'), s1 + 1);
        serverUrl = AccountManager::decodeServerKey(id.left(s1));
        token = m_accounts->tokenForServer(serverUrl);
        itemId = QUrl::fromPercentEncoding(id.mid(s1 + 1, s2 - s1 - 1).toUtf8());
        tag = id.mid(s2 + 1);
    } else {
        const int sep = id.indexOf(QLatin1Char('~'));
        itemId = QUrl::fromPercentEncoding((sep > 0 ? id.left(sep) : id).toUtf8());
        tag = sep > 0 ? id.mid(sep + 1) : QString();
    }

    QUrlQuery q;
    q.addQueryItem(QStringLiteral("maxWidth"), QString::number(qMax(requestedSize.width(), 320)));
    if (!tag.isEmpty())
        q.addQueryItem(QStringLiteral("tag"), tag);
    if (!token.isEmpty())
        q.addQueryItem(QStringLiteral("api_key"), token);

    const QUrl url(serverUrl + QStringLiteral("/Items/%1/Images/Primary?%2")
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
    m_nam.setProxy(QNetworkProxy::NoProxy); // Emby 为局域网服务,不走系统代理
    m_nam.setTransferTimeout(10000);

    QNetworkRequest req(url);
    // 统一 UA(软件名/版本号),不用 Qt 默认 UA。
    req.setRawHeader("User-Agent",
                     (QStringLiteral("MoePlayer/") + QCoreApplication::applicationVersion()).toUtf8());
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
