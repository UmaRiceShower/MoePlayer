#pragma once

#include <QQuickAsyncImageProvider>
#include <QNetworkAccessManager>
#include <QNetworkDiskCache>

class EmbyClient;

//! 异步图片提供器,注册为 "image://emby/<itemId>~<tag>"。
//! 拉取 /Items/{id}/Images/Primary(maxWidth + tag + api_key)。
class PosterProvider : public QQuickAsyncImageProvider
{
public:
    explicit PosterProvider(EmbyClient *client);

    // 按 id("<itemId>~<tag>")构造海报请求,返回异步响应对象。
    QQuickImageResponse *requestImageResponse(const QString &id,
                                              const QSize &requestedSize) override;

private:
    EmbyClient *m_client;
};

//! 一次海报请求的异步响应:下载完成后解码图片并发出 finished()。
//! 注意:QQuickAsyncImageProvider 的请求在 QML 图片加载线程执行,
//! 本类持有的网络管理器必须在同一线程创建与使用(见构造函数)。
class PosterResponse : public QQuickImageResponse
{
    Q_OBJECT
public:
    explicit PosterResponse(const QUrl &url);
    ~PosterResponse() override;

    QQuickTextureFactory *textureFactory() const override;
    QString errorString() const override;

private:
    QNetworkAccessManager m_nam; // 与创建本对象的线程亲和
    QNetworkDiskCache m_cache;
    QNetworkReply *m_reply = nullptr;
    QImage m_image;
    QString m_error;
};
