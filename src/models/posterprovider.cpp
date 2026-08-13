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
#include "core/constants.h"
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
constexpr int kCacheMaxBytes = 64 * 1024 * 1024; // 内存缓存上限(cost = 图片字节数)
constexpr int kFetchConcurrency = 6;             // 同时回源上限
QCache<QString, QImage> g_memCache(kCacheMaxBytes);
QSemaphore g_fetchGate(kFetchConcurrency);
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
        // 加载(磁盘缓存/回源)抽至 PosterProvider::loadImageSync,取色等复用。
        QString err;
        const QImage img = PosterProvider::loadImageSync(m_url, m_token, &err);
        if (m_self)
            QMetaObject::invokeMethod(m_self, "setResult", Qt::QueuedConnection,
                                      Q_ARG(QImage, img), Q_ARG(QString, err));
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
    Q_UNUSED(requestedSize)
    QString serverUrl, token, itemId, tag, kind;
    if (!resolveImageId(id, &serverUrl, &token, &itemId, &tag, &kind))
        return new PosterResponse(QUrl(), QImage()); // 空图直接完成
    const QUrl url = imageUrl(serverUrl, itemId, tag, kind);
    // 内存命中:轻量查询(GUI 线程,互斥保护),命中即完成,不启动后台任务。
    {
        QMutexLocker locker(&g_memMutex);
        if (g_memCache.contains(url.toString()))
            return new PosterResponse(url, *g_memCache.object(url.toString()));
    }
    return new PosterResponse(url, token);
}

bool PosterProvider::resolveImageId(const QString &id, QString *serverUrl, QString *token,
                                    QString *itemId, QString *tag, QString *kind) const
{
    if (serverUrl)
        serverUrl->clear();
    if (token)
        token->clear();
    if (itemId)
        itemId->clear();
    if (tag)
        tag->clear();
    if (kind)
        kind->clear();
    // 无状态浏览下图片 id 一律为 <encodeServerKey(serverUrl)>~<itemId>~<tag>~<kind>
    // (模型/详情填充时统一加前缀),按前缀路由到对应服务器凭据;
    // kind 为图片类型(Primary/Backdrop/Thumb),缺省 Primary 向后兼容旧三段 id。
    // 缺前缀/凭据的 id 直接失败(不发起请求)。
    // 分隔符用 ~ 而非 |(| 在 image:// URL 中会被转义为 %7C)。
    if (id.count(QLatin1Char('~')) < 2)
        return false;
    const int s1 = id.indexOf(QLatin1Char('~'));
    const int s2 = id.indexOf(QLatin1Char('~'), s1 + 1);
    const QString url = AccountManager::decodeServerKey(id.left(s1));
    const QString tok = m_accounts->tokenForServer(url);
    const QString iid = QUrl::fromPercentEncoding(id.mid(s1 + 1, s2 - s1 - 1).toUtf8());
    // 末段 "<tag>" 或 "<tag>~<kind>";kind 白名单外一律回退 Primary。
    QString tg;
    QString kd = QStringLiteral("Primary");
    const QString rest = id.mid(s2 + 1);
    const int k = rest.indexOf(QLatin1Char('~'));
    if (k >= 0) {
        tg = rest.left(k);
        kd = rest.mid(k + 1);
        if (kd != QLatin1String("Primary") && kd != QLatin1String("Backdrop")
            && kd != QLatin1String("Thumb"))
            kd = QStringLiteral("Primary");
    } else {
        tg = rest;
    }
    if (url.isEmpty() || iid.isEmpty() || tok.isEmpty())
        return false;
    if (serverUrl)
        *serverUrl = url;
    if (token)
        *token = tok;
    if (itemId)
        *itemId = iid;
    if (tag)
        *tag = tg;
    if (kind)
        *kind = kd;
    return true;
}

QUrl PosterProvider::imageUrl(const QString &serverUrl, const QString &itemId,
                              const QString &tag, const QString &kind)
{
    // 固定尺寸(卡片显示宽度足够)且 URL 不含 api_key:缓存键稳定,
    // 重登换 token 不会导致整盘缓存失效;认证经 X-Emby-Token 请求头。
    QUrlQuery q;
    const int maxW = kind == QLatin1String("Backdrop") ? MoePlayer::kBackdropMaxWidth
                                                       : MoePlayer::kPosterMaxWidth;
    q.addQueryItem(QStringLiteral("maxWidth"), QString::number(maxW));
    if (!tag.isEmpty())
        q.addQueryItem(QStringLiteral("tag"), tag);
    return QUrl(serverUrl + QStringLiteral("/Items/%1/Images/%2?%3")
                                   .arg(itemId, kind, q.toString()));
}

QImage PosterProvider::loadImageSync(const QUrl &url, const QString &token, QString *error)
{
    const QString key = url.toString();
    if (error)
        error->clear();
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
                return img;
            }
        }
    }
    // 2) 回源:占闸(后台阻塞无碍);QNAM 在本线程创建使用(线程亲和)。
    g_fetchGate.acquire();
    QNetworkAccessManager nam;
    nam.setProxy(QNetworkProxy::NoProxy); // Emby 为局域网服务,不走系统代理
    nam.setTransferTimeout(MoePlayer::kNetworkTimeoutMs);
    QNetworkRequest req(url);
    // 统一 UA(软件名/版本号),不用 Qt 默认 UA。
    req.setRawHeader(MoePlayer::kHeaderUserAgent, MoePlayer::userAgent().toUtf8());
    if (!token.isEmpty())
        req.setRawHeader(MoePlayer::kHeaderToken, token.toUtf8());
    QNetworkReply *reply = nam.get(req);
    QEventLoop loop;
    QObject::connect(reply, &QNetworkReply::finished, &loop, &QEventLoop::quit);
    loop.exec(); // 本线程等待(后台线程,不阻塞 GUI)
    const bool ok = reply->error() == QNetworkReply::NoError;
    // 失败/超时(abort)时 reply 的 QIODevice 已关闭,此时 readAll 会报
    // "device not open";仅成功时读取,失败只取错误描述。
    const QByteArray data = ok ? reply->readAll() : QByteArray();
    if (error)
        *error = reply->errorString();
    reply->deleteLater();
    g_fetchGate.release();
    if (!ok)
        return QImage();
    QImage img;
    if (!img.loadFromData(data)) {
        if (error)
            *error = QStringLiteral("图片解码失败");
        return QImage();
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
    return img;
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
