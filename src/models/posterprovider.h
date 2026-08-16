#pragma once

#include <QNetworkProxy>
#include <QQuickAsyncImageProvider>
#include <QNetworkAccessManager>
#include <QNetworkDiskCache>

class EmbyClient;
class AccountManager;
class ConfigManager;

//! 异步图片提供器,注册为 "image://emby/<id>"。
//! 无状态浏览下海报 id 一律为 <encodeServerKey(serverUrl)>~<itemId>~<tag>
//! (模型填充时统一加前缀),提供器按前缀路由到对应服务器的账号 token。
//! 请求路径 /Items/{id}/Images/Primary(maxWidth + tag + api_key)。
class PosterProvider : public QQuickAsyncImageProvider
{
public:
    explicit PosterProvider(EmbyClient *client, AccountManager *accounts,
                            ConfigManager *config = nullptr);

    // 当前配置代理(每次调用现解析,热重载后新请求自动用新代理)。
    QNetworkProxy proxy() const;

    // 按 id 构造海报请求,返回异步响应对象。
    QQuickImageResponse *requestImageResponse(const QString &id,
                                              const QSize &requestedSize) override;

    // 解析海报 id 前缀路由(serverUrl/token/itemId/tag/kind),ColorProvider 复用。
    // 返回 false = 缺前缀/凭据,不发起请求。
    bool resolveImageId(const QString &id, QString *serverUrl, QString *token,
                        QString *itemId, QString *tag, QString *kind) const;

    // 按解析结果构造回源 URL(缓存键稳定,maxWidth 按 kind 分级)。
    static QUrl imageUrl(const QString &serverUrl, const QString &itemId,
                         const QString &tag, const QString &kind);

    // 后台线程同步加载:磁盘缓存命中直读,未命中回源(占并发闸);
    // 失败/解码失败返回空图,error 填错误描述。线程安全,供取色等复用。
    // proxy 用于回源请求(默认直连)。
    static QImage loadImageSync(const QUrl &url, const QString &token, QString *error = nullptr,
                                const QNetworkProxy &proxy = QNetworkProxy::NoProxy);

private:
    EmbyClient *m_client;
    AccountManager *m_accounts;
    ConfigManager *m_config;
};

//! 一次海报请求的异步响应。缓存读取与回源(经并发闸)在线程池线程执行,
//! 不阻塞 GUI;结果经 setResult 回填。内存命中时构造即完成。
class PosterResponse : public QQuickImageResponse
{
    Q_OBJECT
public:
    // 常规:后台线程查缓存/回源,token 用于 X-Emby-Token 请求头,proxy 用于回源。
    explicit PosterResponse(const QUrl &url, const QString &token,
                            const QNetworkProxy &proxy = QNetworkProxy::NoProxy);
    // 同步完成(内存命中/解析失败):携带图片或错误,异步投递 finished,
    // 遵守 QQuickImageProvider 契约(finished 不得在 requestImageResponse 内发出)。
    explicit PosterResponse(const QUrl &url, const QImage &img,
                            const QString &error = QString());
    ~PosterResponse() override;

    QQuickTextureFactory *textureFactory() const override;
    QString errorString() const override;

public slots:
    // 后台加载结果回填(GUI 线程执行),随后发出 finished。
    void setResult(const QImage &img, const QString &error);

private:
    QImage m_image;
    QString m_error;
};
