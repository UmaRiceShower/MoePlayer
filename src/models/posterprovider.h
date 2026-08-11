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

//! 一次海报请求的异步响应:内存/磁盘缓存命中直接完成,未命中经回源闸
//! (最多 6 张并发)拉取并回填缓存。
//! 注意:QQuickAsyncImageProvider 的请求在 QML 图片加载线程执行,
//! 本类持有的网络管理器必须在同一线程创建与使用(见构造函数)。
class PosterResponse : public QQuickImageResponse
{
    Q_OBJECT
public:
    // token 用于 X-Emby-Token 请求头(URL 不含凭据,保证缓存键稳定)。
    explicit PosterResponse(const QUrl &url, const QString &token);
    ~PosterResponse() override;

    QQuickTextureFactory *textureFactory() const override;
    QString errorString() const override;

private:
    QNetworkReply *m_reply = nullptr;
    QImage m_image;
    QString m_error;
};
