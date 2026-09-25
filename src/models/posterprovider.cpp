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
#include <QRegularExpression>
#include <QSemaphore>
#include <QThread>
#include <QThreadPool>
#include <QUrlQuery>
#include <QDebug>

#include "core/apppaths.h"
#include "core/accountmanager.h"
#include "core/configmanager.h"
#include "core/constants.h"
#include "core/embyclient.h"

PosterProvider::PosterProvider(EmbyClient *client, AccountManager *accounts,
                               ConfigManager *config)
    : m_client(client)
    , m_accounts(accounts)
    , m_config(config)
{
}

QNetworkProxy PosterProvider::proxy() const
{
    return m_config ? m_config->proxyObject() : QNetworkProxy::NoProxy;
}

namespace {
// 共享缓存设施(线程安全;缓存读写可能来自 GUI 或线程池线程):
// - 内存层:解码后的 QImage,按缓存键 LRU 淘汰,上限 64MB;
// - 磁盘层:CacheLocation/emby-images/<键哈希>.img,30 天 TTL;
// - 回源闸:最多 6 张图同时回源。封面与 API 请求共用服务器连接,
//   无闸时一屏几十张图同时拉取会挤占 JSON 请求带宽;缓存命中不占名额。
QMutex g_memMutex;
constexpr int kCacheMaxBytes = 192 * 1024 * 1024; // 内存缓存上限
constexpr int kFetchConcurrency = 16; // 回源并发
QCache<QString, QImage> g_memCache(kCacheMaxBytes);
QSemaphore g_fetchGate(kFetchConcurrency);
constexpr qint64 kCacheTtlMs = 30LL * 24 * 3600 * 1000;

QString cacheFilePath(const QString &key)
{
    const QByteArray h = QCryptographicHash::hash(key.toUtf8(), QCryptographicHash::Sha256).toHex();
    return AppPaths::cacheDir()
           + QStringLiteral("/emby-images/") + QString::fromLatin1(h) + QStringLiteral(".img");
}

// 磁盘读与网络回源走两个专用池
QThreadPool &diskPool()
{
    static QThreadPool p;
    p.setMaxThreadCount(4);
    return p;
}
QThreadPool &netPool()
{
    static QThreadPool p;
    p.setMaxThreadCount(16);
    return p;
}

void deliver(const QPointer<PosterResponse> &self, const QImage &img, const QString &err)
{
    // 响应对象已销毁时 QPointer 置空,回填被跳过,无悬垂访问。
    if (self)
        QMetaObject::invokeMethod(self, "setResult", Qt::QueuedConnection,
                                  Q_ARG(QImage, img), Q_ARG(QString, err));
}


class NetTask : public QRunnable
{
public:
    NetTask(QPointer<PosterResponse> self, const QUrl &url, const QString &token,
            const QNetworkProxy &proxy, const QString &idKey)
        : m_self(self), m_url(url), m_token(token), m_proxy(proxy), m_idKey(idKey)
    {
    }
    void run() override
    {
        QString err;
        const QImage img = PosterProvider::fetchNetwork(m_url, m_token, &err, m_proxy, m_idKey);
        deliver(m_self, img, err);
    }

private:
    QPointer<PosterResponse> m_self;
    QUrl m_url;
    QString m_token;
    QNetworkProxy m_proxy;
    QString m_idKey;
};

class DiskTask : public QRunnable
{
public:
    DiskTask(QPointer<PosterResponse> self, const QUrl &url, const QString &token,
             const QNetworkProxy &proxy, const QString &idKey)
        : m_self(self), m_url(url), m_token(token), m_proxy(proxy), m_idKey(idKey)
    {
    }
    void run() override
    {
        const QImage img = PosterProvider::loadDisk(m_idKey);
        if (img.isNull()) {
            netPool().start(new NetTask(m_self, m_url, m_token, m_proxy, m_idKey));
            return;
        }
        deliver(m_self, img, QString());
    }

private:
    QPointer<PosterResponse> m_self;
    QUrl m_url;
    QString m_token;
    QNetworkProxy m_proxy;
    QString m_idKey;
};
} // namespace

bool PosterProvider::isCached(const QString &id) const
{
    {
        QMutexLocker locker(&g_memMutex);
        if (g_memCache.contains(id))
            return true;
    }
    const QFileInfo fi(cacheFilePath(id));
    // 不存在文件的 lastModified 无效:msecsTo 对无效日期返 0,0 < TTL 恒真
    // —— 必须先 exists 判定。
    return fi.exists() && fi.lastModified().msecsTo(QDateTime::currentDateTime()) < kCacheTtlMs;
}

QQuickImageResponse *PosterProvider::requestImageResponse(const QString &id,
                                                          const QSize &requestedSize)
{
    Q_UNUSED(requestedSize)
    const QString base = QString(id).remove(QRegularExpression(QStringLiteral("~r\\d+$")));
    QString serverUrl, token, userId, itemId, tag, kind;
    if (!resolveImageId(base, &serverUrl, &token, &userId, &itemId, &tag, &kind)) {
        qWarning().noquote() << "Poster: 图片地址无效" << id;
        return new PosterResponse(QUrl(), QImage(), QStringLiteral("图片地址无效"));
    }
    // 多线路:取图走当前线路(activeUrlFor 收口;userId 为解析阶段同账号
    // 凭据,同服多账号不串)。
    const QUrl url = imageUrl(m_accounts->activeUrlFor(serverUrl, userId),
                              itemId, tag, kind, requestedSize);
    // 内存命中:轻量查询(GUI 线程,互斥保护),命中即完成,不启动后台任务。
    // 键 = 海报 id(与 loadImageSync 同源);Backdrop 拼请求档位——档位
    // 可配,改档后旧档缓存成孤儿按 TTL 自弃,不会因键复用顶住新档。
    const QString ckey = kind == QLatin1String("Backdrop")
                         ? base + QStringLiteral("~w") + backdropTier()
                         : base;
    {
        QMutexLocker locker(&g_memMutex);
        if (g_memCache.contains(ckey)) {
            return new PosterResponse(url, *g_memCache.object(ckey));
        }
    }
    return new PosterResponse(url, token, proxy(), ckey);
}

bool PosterProvider::resolveImageId(const QString &id0, QString *serverUrl, QString *token, QString *userId,
                                    QString *itemId, QString *tag, QString *kind) const
{
    const QString id = QString(id0).remove(QRegularExpression(QStringLiteral("~r\\d+$")));
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
    // 无状态浏览下图片 id 一律为 <encodeServerKey(accountId)>~<itemId>~<tag>~<kind>
    // (模型/详情填充时统一加前缀),按前缀路由到对应服务器凭据;
    // kind 为图片类型(Primary/Backdrop/Thumb),缺省 Primary 向后兼容旧三段 id。
    // 缺前缀/凭据的 id 直接失败(不发起请求)。
    // 分隔符用 ~ 而非 |(| 在 image:// URL 中会被转义为 %7C)。
    if (id.count(QLatin1Char('~')) < 2)
        return false;
    const int s1 = id.indexOf(QLatin1Char('~'));
    const int s2 = id.indexOf(QLatin1Char('~'), s1 + 1);
    // 前缀 = 账号 id(不可变身份,改地址/切线路免疫)。
    const QVariantMap creds0 = m_accounts->credsForAccount(
        AccountManager::decodeServerKey(id.left(s1)));
    const QString url = creds0.value(QStringLiteral("serverUrl")).toString();
    const QString tok = creds0.value(QStringLiteral("token")).toString();
    const QString uid = creds0.value(QStringLiteral("userId")).toString();
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
    if (userId)
        *userId = uid;
    if (itemId)
        *itemId = iid;
    if (tag)
        *tag = tg;
    if (kind)
        *kind = kd;
    return true;
}

QUrl PosterProvider::resolvedImageUrl(const QString &id, QString *token) const
{
    QString serverUrl, userId, itemId, tag, kind;
    if (!resolveImageId(id, &serverUrl, token, &userId, &itemId, &tag, &kind))
        return QUrl();
    return imageUrl(m_accounts->activeUrlFor(serverUrl, userId), itemId, tag, kind);
}

QString PosterProvider::backdropTier() const
{
    if (m_config)
        return m_config->backdropMaxWidth();
    return QString::number(MoePlayer::kBackdropMaxWidth);
}

QUrl PosterProvider::imageUrl(const QString &serverUrl, const QString &itemId,
                              const QString &tag, const QString &kind,
                              const QSize &requestedSize) const
{
    Q_UNUSED(requestedSize)
    // 固定厚档请求(服务器缩放并缓存缩略图,Emby 官方"web 客户端"行为):
    // 海报/缩略图 512(常量);背景走配置 backdropMaxWidth(见 backdropTier)。
    // 与显示尺寸解耦——
    // URL 恒定,窗口缩放不重拉;客户端 sourceSize 负责显示缩放。
    // 较原图请求省流量与本地/服务器缓存空间。
    // URL 不含 api_key,重登换 token 不失效;认证经请求头。
    QUrlQuery q;
    if (kind == QLatin1String("Backdrop")) {
        // 档位可配(设置「详情页」背景图清晰度);original = 不带 maxWidth 拉原图。
        const QString tier = backdropTier();
        if (tier != QLatin1String("original"))
            q.addQueryItem(QStringLiteral("maxWidth"), tier);
    } else {
        q.addQueryItem(QStringLiteral("maxWidth"), QString::number(MoePlayer::kPosterMaxWidth));
    }
    if (!tag.isEmpty())
        q.addQueryItem(QStringLiteral("tag"), tag);
    return QUrl(serverUrl + QStringLiteral("/Items/%1/Images/%2?%3")
                                   .arg(itemId, kind, q.toString()));
}

// 磁盘层(TTL 内):读文件解码,回填内存层;未命中/失败返回空图。
QImage PosterProvider::loadDisk(const QString &idKey)
{
    const QString path = cacheFilePath(idKey);
    const QFileInfo fi(path);
    if (!fi.exists() || fi.lastModified().msecsTo(QDateTime::currentDateTime()) >= kCacheTtlMs)
        return QImage();
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) {
        qDebug().noquote() << "Poster: 磁盘缓存读取失败,回源" << path << f.errorString();
        return QImage();
    }
    QImage img;
    if (!img.loadFromData(f.readAll())) {
        qDebug().noquote() << "Poster: 磁盘缓存解码失败,回源" << path;
        return QImage();
    }
    QMutexLocker locker(&g_memMutex);
    g_memCache.insert(idKey, new QImage(img), img.sizeInBytes());
    return img;
}

// 网络回源(并发闸 + 超时 + 一次传输重试),成功写磁盘与内存缓存。
QImage PosterProvider::fetchNetwork(const QUrl &url, const QString &token, QString *error,
                                    const QNetworkProxy &proxy, const QString &idKey)
{
    // 缓存键 = 海报 id(accountId~itemId~tag~kind,不可变身份)
    const QString key = idKey.isEmpty() ? url.toString() : idKey;
    if (error)
        error->clear();
    const QString path = cacheFilePath(key);
    // 占闸(后台阻塞无碍);thread_local QNAM —— 栈对象会让每张
    // 图付全额 TCP+TLS 握手、零连接复用;
    // 线程池线程长寿,复用自然建立,且不破线程亲和。
    g_fetchGate.acquire();
    thread_local QNetworkAccessManager nam;
    // 配置代理(空 = 直连)。不走系统代理:Emby 多为局域网服务,且 Qt 在
    // Linux 上不识别 no_proxy,显式指定避免意外走系统代理。
    nam.setProxy(proxy);
    nam.setTransferTimeout(MoePlayer::kImageTimeoutMs);
    QNetworkRequest req(url);
    // h1:与 API 同口径(独立连接,防御性)
    req.setAttribute(QNetworkRequest::Http2AllowedAttribute, false);
    // 统一 UA(软件名/版本号),不用 Qt 默认 UA。
    req.setRawHeader(MoePlayer::kHeaderUserAgent, MoePlayer::userAgent().toUtf8());
    if (!token.isEmpty())
        req.setRawHeader(MoePlayer::kHeaderToken, token.toUtf8());
    // 有界重试:仅传输层失败(无 HTTP 状态码)重试一次;4xx/5xx 是服务器
    // 明确应答,重试无义。停摆掐断的连接可能半死,重试换新连接。
    QNetworkReply *reply = nullptr;
    for (int attempt = 0; attempt < 2 && !reply; ++attempt) {
        if (attempt > 0) {
            qInfo().noquote() << "Poster: 传输层失败,换连接重试" << url.toString();
            nam.clearAccessCache(); // 丢弃半死连接,强制新建
            QThread::msleep(500);
        }
        reply = nam.get(req);
        QEventLoop loop;
        QObject::connect(reply, &QNetworkReply::finished, &loop, &QEventLoop::quit);
        loop.exec(); // 本线程等待(后台线程,不阻塞 GUI)
        const bool transportFail =
            reply->error() != QNetworkReply::NoError
            && reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() == 0;
        if (transportFail && attempt == 0) {
            reply->deleteLater();
            reply = nullptr; // 触发重试
        }
    }
    const bool ok = reply->error() == QNetworkReply::NoError;
    // 失败/超时(abort)时 reply 的 QIODevice 已关闭,此时 readAll 会报
    // "device not open";仅成功时读取,失败只取错误描述。
    // 注意:某些远程响应的 error()==NoError 但 errorString() 非空(如
    // "未知错误"),成功响应不得据此判失败——仅在 !ok 时填 error。
    const QByteArray data = ok ? reply->readAll() : QByteArray();
    if (!ok && error)
        *error = reply->errorString();
    reply->deleteLater();
    g_fetchGate.release();
    if (!ok) {
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        qWarning().noquote() << "Poster: 图片回源失败" << url.toString()
                             << reply->errorString() << "HTTP" << status;
        return QImage();
    }
    QImage img;
    if (!img.loadFromData(data)) {
        qWarning().noquote() << "Poster: 图片解码失败(非图片数据?)" << url.toString()
                             << "字节数" << data.size();
        if (error)
            *error = QStringLiteral("图片解码失败");
        return QImage();
    }
    // 回填磁盘与内存(写失败不算错:缓存只是优化)。
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile f(path);
    if (f.open(QIODevice::WriteOnly))
        f.write(data);
    else
        qDebug().noquote() << "Poster: 磁盘缓存写入失败(忽略)" << path << f.errorString();
    {
        QMutexLocker locker(&g_memMutex);
        g_memCache.insert(key, new QImage(img), img.sizeInBytes());
    }
    return img;
}

QImage PosterProvider::loadImageSync(const QUrl &url, const QString &token, QString *error,
                                     const QNetworkProxy &proxy, const QString &idKey)
{
    // 同步调用方(取色等):磁盘命中直出,未命中回源。
    const QImage disk = loadDisk(idKey.isEmpty() ? url.toString() : idKey);
    if (!disk.isNull()) {
        if (error)
            error->clear();
        return disk;
    }
    return fetchNetwork(url, token, error, proxy, idKey);
}

PosterResponse::PosterResponse(const QUrl &url, const QString &token,
                               const QNetworkProxy &proxy, const QString &idKey)
{
    // 磁盘读 → 未命中转网络池;均不阻塞调用线程(GUI)。
    diskPool().start(new DiskTask(QPointer<PosterResponse>(this), url, token, proxy, idKey));
}

PosterResponse::PosterResponse(const QUrl &url, const QImage &img, const QString &error)
{
    Q_UNUSED(url)
    m_image = img;
    m_error = error;
    // QQuickImageProvider 契约:finished 不得在 requestImageResponse 调用栈内
    // 同步发出(构造期间 emit 先于 QQuickPixmap 的 connect 丢失;空图时 Qt
    // 判"已 Finished 无图片数据"报"未知错误")。QueuedConnection 异步投递,
    // 引擎先注册连接再收到完成;对象提前销毁时投递被 Qt 丢弃,无悬垂。
    QMetaObject::invokeMethod(this, "setResult", Qt::QueuedConnection,
                              Q_ARG(QImage, m_image), Q_ARG(QString, m_error));
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
