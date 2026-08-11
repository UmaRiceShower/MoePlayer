#include "posterprovider.h"

#include <QCache>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMutex>
#include <QNetworkProxy>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QQuickTextureFactory>
#include <QSemaphore>
#include <QStandardPaths>
#include <QUrlQuery>

#include "core/accountmanager.h"
#include "core/embyclient.h"

PosterProvider::PosterProvider(EmbyClient *client, AccountManager *accounts)
    : m_client(client)
    , m_accounts(accounts)
{
}

namespace {
// 共享缓存设施(线程安全;PosterProvider 请求来自 QML 图片加载线程):
// - 内存层:解码后的 QImage,按缓存键 LRU 淘汰,上限 64MB;
// - 磁盘层:CacheLocation/emby-images/<键哈希>.img,30 天 TTL;
// - 回源闸:最多 6 张图同时回源。封面与 API 请求共用服务器连接,
//   无闸时一屏几十张图同时拉取会挤占 JSON 请求带宽;缓存命中不占名额。
QMutex g_memMutex;
QCache<QString, QImage> g_memCache(64 * 1024 * 1024); // cost = 图片字节数
QSemaphore g_fetchGate(6);
constexpr qint64 kCacheTtlMs = 30LL * 24 * 3600 * 1000;

QString cacheFilePath(const QString &key)
{
    const QByteArray h = QCryptographicHash::hash(key.toUtf8(), QCryptographicHash::Sha256).toHex();
    return QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
           + QStringLiteral("/emby-images/") + QString::fromLatin1(h) + QStringLiteral(".img");
}
} // namespace

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

    // 固定尺寸(卡片显示宽度足够)且 URL 不含 api_key:缓存键稳定,
    // 重登换 token 不会导致整盘缓存失效;认证经 X-Emby-Token 请求头。
    Q_UNUSED(requestedSize)
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("maxWidth"), QStringLiteral("320"));
    if (!tag.isEmpty())
        q.addQueryItem(QStringLiteral("tag"), tag);

    const QUrl url(serverUrl + QStringLiteral("/Items/%1/Images/Primary?%2")
                                       .arg(itemId, q.toString()));
    return new PosterResponse(url, token);
}

PosterResponse::PosterResponse(const QUrl &url, const QString &token)
{
    const QString key = url.toString();
    // 1) 内存层命中:直接完成,不碰磁盘与网络。
    {
        QMutexLocker locker(&g_memMutex);
        if (g_memCache.contains(key)) {
            m_image = *g_memCache.take(key);
            emit finished();
            return;
        }
    }
    // 2) 磁盘层命中(TTL 内):读文件解码并回填内存层。
    const QString path = cacheFilePath(key);
    if (QFileInfo(path).lastModified().msecsTo(QDateTime::currentDateTime()) < kCacheTtlMs) {
        QFile f(path);
        if (f.open(QIODevice::ReadOnly)) {
            QImage img;
            if (img.loadFromData(f.readAll())) {
                g_memCache.insert(key, new QImage(img), img.sizeInBytes());
                m_image = img;
                emit finished();
                return;
            }
        }
    }
    // 3) 回源:占闸(命中不占名额),独立 QNAM 保持线程亲和。
    g_fetchGate.acquire();
    QNetworkAccessManager *nam = new QNetworkAccessManager;
    nam->setProxy(QNetworkProxy::NoProxy); // Emby 为局域网服务,不走系统代理
    nam->setTransferTimeout(10000);
    QNetworkRequest req(url);
    // 统一 UA(软件名/版本号),不用 Qt 默认 UA。
    req.setRawHeader("User-Agent",
                     (QStringLiteral("MoePlayer/") + QCoreApplication::applicationVersion()).toUtf8());
    if (!token.isEmpty())
        req.setRawHeader("X-Emby-Token", token.toUtf8());
    m_reply = nam->get(req);
    connect(m_reply, &QNetworkReply::finished, this, [this, nam, key, path]() {
        nam->deleteLater();
        g_fetchGate.release();
        if (m_reply->error() == QNetworkReply::NoError) {
            const QByteArray data = m_reply->readAll();
            if (m_image.loadFromData(data)) {
                // 回填磁盘与内存(写失败不算错:缓存只是优化)。
                QDir().mkpath(QFileInfo(path).absolutePath());
                QFile f(path);
                if (f.open(QIODevice::WriteOnly))
                    f.write(data);
                g_memCache.insert(key, new QImage(m_image), m_image.sizeInBytes());
            } else {
                m_error = QStringLiteral("图片解码失败");
            }
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
