#include "posterprovider.h"

#include <QCache>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QMutex>
#include <QNetworkProxy>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QQuickTextureFactory>
#include <QSemaphore>
#include <QStandardPaths>
#include <QThreadPool>
#include <QUrlQuery>

#include "core/accountmanager.h"
#include "core/embyclient.h"

PosterProvider::PosterProvider(EmbyClient *client, AccountManager *accounts)
    : m_client(client)
    , m_accounts(accounts)
{
}

namespace {
// 共享缓存设施(线程安全;缓存读写可能来自 GUI 或线程池线程):
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

// 后台加载任务:磁盘读取/回源(含并发闸与网络)在线程池线程执行,
// 绝不阻塞 GUI 线程。结果经 setResult 排队回填到响应对象;
// 响应对象已销毁时 QPointer 置空,回填被跳过,无悬垂访问。
class LoadTask : public QRunnable
{
public:
    LoadTask(QPointer<PosterResponse> self, const QUrl &url, const QString &token)
        : m_self(self)
        , m_url(url)
        , m_token(token)
    {
    }

    void run() override
    {
        const QString key = m_url.toString();
        // 1) 磁盘层命中(TTL 内):读文件解码,回填内存层。
        const QString path = cacheFilePath(key);
        if (QFileInfo(path).lastModified().msecsTo(QDateTime::currentDateTime()) < kCacheTtlMs) {
            QFile f(path);
            if (f.open(QIODevice::ReadOnly)) {
                QImage img;
                if (img.loadFromData(f.readAll())) {
                    {
                        QMutexLocker locker(&g_memMutex);
                        g_memCache.insert(key, new QImage(img), img.sizeInBytes());
                    }
                    if (m_self)
                        QMetaObject::invokeMethod(m_self, "setResult", Qt::QueuedConnection,
                                                  Q_ARG(QImage, img), Q_ARG(QString, QString()));
                    return;
                }
            }
        }
        // 2) 回源:占闸(后台阻塞无碍);QNAM 在本线程创建使用(线程亲和)。
        g_fetchGate.acquire();
        QNetworkAccessManager nam;
        nam.setProxy(QNetworkProxy::NoProxy); // Emby 为局域网服务,不走系统代理
        nam.setTransferTimeout(10000);
        QNetworkRequest req(m_url);
        // 统一 UA(软件名/版本号),不用 Qt 默认 UA。
        req.setRawHeader("User-Agent",
                         (QStringLiteral("MoePlayer/") + QCoreApplication::applicationVersion()).toUtf8());
        if (!m_token.isEmpty())
            req.setRawHeader("X-Emby-Token", m_token.toUtf8());
        QNetworkReply *reply = nam.get(req);
        QEventLoop loop;
        QObject::connect(reply, &QNetworkReply::finished, &loop, &QEventLoop::quit);
        loop.exec(); // 本线程等待(后台线程,不阻塞 GUI)
        const bool ok = reply->error() == QNetworkReply::NoError;
        const QByteArray data = reply->readAll();
        const QString err = reply->errorString();
        reply->deleteLater();
        g_fetchGate.release();
        if (!ok) {
            if (m_self)
                QMetaObject::invokeMethod(m_self, "setResult", Qt::QueuedConnection,
                                          Q_ARG(QImage, QImage()), Q_ARG(QString, err));
            return;
        }
        QImage img;
        if (!img.loadFromData(data)) {
            if (m_self)
                QMetaObject::invokeMethod(m_self, "setResult", Qt::QueuedConnection,
                                          Q_ARG(QImage, QImage()),
                                          Q_ARG(QString, QStringLiteral("图片解码失败")));
            return;
        }
        // 回填磁盘与内存(写失败不算错:缓存只是优化)。
        QDir().mkpath(QFileInfo(path).absolutePath());
        QFile f(path);
        if (f.open(QIODevice::WriteOnly))
            f.write(data);
        {
            QMutexLocker locker(&g_memMutex);
            g_memCache.insert(key, new QImage(img), img.sizeInBytes());
        }
        if (m_self)
            QMetaObject::invokeMethod(m_self, "setResult", Qt::QueuedConnection,
                                      Q_ARG(QImage, img), Q_ARG(QString, QString()));
    }

private:
    QPointer<PosterResponse> m_self;
    QUrl m_url;
    QString m_token;
};
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
    // 内存命中:轻量查询(GUI 线程,互斥保护),命中即完成,不启动后台任务。
    {
        QMutexLocker locker(&g_memMutex);
        if (g_memCache.contains(url.toString()))
            return new PosterResponse(url, *g_memCache.object(url.toString()));
    }
    return new PosterResponse(url, token);
}

PosterResponse::PosterResponse(const QUrl &url, const QString &token)
{
    // 加载(磁盘/网络)全部在线程池线程执行,不阻塞调用线程(GUI)。
    QThreadPool::globalInstance()->start(new LoadTask(QPointer<PosterResponse>(this), url, token));
}

PosterResponse::PosterResponse(const QUrl &url, const QImage &img)
{
    Q_UNUSED(url)
    m_image = img;
    emit finished();
}

PosterResponse::~PosterResponse()
{
    // 后台任务自管其 QNetworkReply(线程亲和),此处无需中止;
    // 若任务仍在运行,结果回填会被 QPointer 检查跳过。
}

void PosterResponse::setResult(const QImage &img, const QString &error)
{
    m_image = img;
    m_error = error;
    emit finished();
}

QQuickTextureFactory *PosterResponse::textureFactory() const
{
    return QQuickTextureFactory::textureFactoryForImage(m_image);
}

QString PosterResponse::errorString() const
{
    return m_error;
}
