#pragma once

#include <QQuickAsyncImageProvider>
#include <QNetworkAccessManager>
#include <QNetworkDiskCache>

class EmbyClient;
class AccountManager;

//! 异步图片提供器,注册为 "image://emby/<id>"。
//! id 两种格式:
//! - 会话内: <itemId>~<tag>,按当前会话的服务器与 token 请求;
//! - 跨服务器(首页聚合行): <encodeServerKey(serverUrl)>~<itemId>~<tag>,
//!   按编码的服务器地址取对应账号 token 请求。
//! 请求路径 /Items/{id}/Images/Primary(maxWidth + tag + api_key)。
class PosterProvider : public QQuickAsyncImageProvider
{
public:
    explicit PosterProvider(EmbyClient *client, AccountManager *accounts);

    // 按 id 构造海报请求,返回异步响应对象。
    QQuickImageResponse *requestImageResponse(const QString &id,
                                              const QSize &requestedSize) override;

private:
    EmbyClient *m_client;
    AccountManager *m_accounts;
};

//! 一次海报请求的异步响应。缓存读取与回源(经并发闸)在线程池线程执行,
//! 不阻塞 GUI;结果经 setResult 回填。内存命中时构造即完成。
class PosterResponse : public QQuickImageResponse
{
    Q_OBJECT
public:
    // 常规:后台线程查缓存/回源,token 用于 X-Emby-Token 请求头。
    explicit PosterResponse(const QUrl &url, const QString &token);
    // 内存命中:直接携带图片完成。
    explicit PosterResponse(const QUrl &url, const QImage &img);
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
