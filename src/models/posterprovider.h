#pragma once

#include <QQuickAsyncImageProvider>
#include <QNetworkAccessManager>
#include <QNetworkDiskCache>

class EmbyClient;

//! 异步图片提供器,注册为 "image://emby/<itemId>|<tag>"。
//! 拉取 /Items/{id}/Images/Primary(maxWidth + tag + api_key),经 QNetworkDiskCache 磁盘缓存。
class PosterProvider : public QQuickAsyncImageProvider
{
public:
    explicit PosterProvider(EmbyClient *client);

    // 按 id("<itemId>|<tag>")构造海报请求,返回异步响应对象。
    QQuickImageResponse *requestImageResponse(const QString &id,
                                              const QSize &requestedSize) override;

private:
    EmbyClient *m_client;
    QNetworkAccessManager m_nam;
    QNetworkDiskCache m_cache;
};

//! 一次海报请求的异步响应:下载完成后解码图片并发出 finished()。
class PosterResponse : public QQuickImageResponse
{
    Q_OBJECT
public:
    PosterResponse(const QUrl &url, QNetworkAccessManager *nam);
    ~PosterResponse() override;

    QQuickTextureFactory *textureFactory() const override;
    QString errorString() const override;

private:
    QNetworkReply *m_reply = nullptr;
    QImage m_image;
    QString m_error;
};
