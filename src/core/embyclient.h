#pragma once

#include <QObject>
#include <QNetworkAccessManager>
#include <QJsonArray>
#include <QSettings>

#include <functional>

#include "models/mediaitemmodel.h"

//! Emby REST 客户端(QML 单例 "MoePlayer.Core EmbyClient")。
//! 所有请求异步执行,结果经信号回调;JSON 解析与 DTO 转换均在本类完成,QML 侧只消费信号。
//! 播放流地址一律取自 PlaybackInfo 响应,不在客户端拼装。
class EmbyClient : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString serverUrl READ serverUrl WRITE setServerUrl NOTIFY serverUrlChanged)
    Q_PROPERTY(QString serverName READ serverName NOTIFY serverInfoChanged)
    Q_PROPERTY(QString serverVersion READ serverVersion NOTIFY serverInfoChanged)
    Q_PROPERTY(QString userName READ userName NOTIFY loginChanged)
    Q_PROPERTY(bool connected READ connected NOTIFY loginChanged)
    Q_PROPERTY(MediaItemModel *viewsModel READ viewsModel CONSTANT)
    Q_PROPERTY(MediaItemModel *itemsModel READ itemsModel CONSTANT)
public:
    explicit EmbyClient(QObject *parent = nullptr);

    // 服务器地址,持久化于 QSettings("network/serverUrl"),默认本机 8096 端口。
    QString serverUrl() const { return m_settings.value("network/serverUrl", QStringLiteral("http://127.0.0.1:8096")).toString(); }
    void setServerUrl(const QString &v);
    QString serverName() const { return m_serverName; }
    QString serverVersion() const { return m_serverVersion; }
    QString userName() const { return m_userName; }
    // 已登录(持有 AccessToken)。
    bool connected() const { return !m_accessToken.isEmpty(); }
    QString accessToken() const { return m_accessToken; }
    QString userId() const { return m_userId; }
    MediaItemModel *viewsModel() { return &m_viewsModel; }
    MediaItemModel *itemsModel() { return &m_itemsModel; }

    // 获取服务器公开信息(/System/Info/Public,无需认证)。
    Q_INVOKABLE void fetchPublicInfo();
    // 用户名密码登录(/Users/AuthenticateByName),成功后填 accessToken/userId。
    Q_INVOKABLE void login(const QString &username, const QString &password);
    // 获取当前用户的媒体库视图列表(/Users/{id}/Views),填充 viewsModel。
    Q_INVOKABLE void fetchViews();
    // 获取指定视图下的影片条目(/Users/{id}/Items,分页),填充 itemsModel。
    // startIndex=0 时替换模型,否则追加;TotalRecordCount 写入 itemsModel.totalCount。
    Q_INVOKABLE void fetchItems(const QString &viewId, int startIndex, int limit);
    // 播放协商(/Items/{id}/PlaybackInfo),解析出可播放地址后发 playbackReady。
    Q_INVOKABLE void fetchPlaybackInfo(const QString &itemId);
    // 获取条目详情(/Users/{id}/Items/{itemId}),发 itemDetailReady。
    Q_INVOKABLE void fetchItemDetail(const QString &itemId);
    // 播放状态回传四件套(/Sessions/Playing*,PlaySessionId 贯穿)。
    Q_INVOKABLE void reportPlaybackStart(const QString &itemId, const QString &mediaSourceId,
                                         const QString &playSessionId, const QString &playMethod,
                                         double positionSecs);
    Q_INVOKABLE void reportPlaybackProgress(const QString &itemId, const QString &mediaSourceId,
                                            const QString &playSessionId, const QString &playMethod,
                                            double positionSecs, bool paused);
    Q_INVOKABLE void reportPlaybackStopped(const QString &itemId, const QString &mediaSourceId,
                                           const QString &playSessionId, double positionSecs);
    Q_INVOKABLE void reportPlaybackPing(const QString &playSessionId);
    // 登出并清空模型与令牌。
    Q_INVOKABLE void disconnectServer();

private:
    // 探测播放地址支持的路径前缀:部分反向代理只在 /emby/ 前缀下正确处理 Range 请求,
    // 探测到该情况则把地址改到 /emby 前缀;探测失败一律回退原地址,结果按服务器缓存。
    void probeSeekableUrl(const QString &url, std::function<void(const QString &)> onDone);
    // 发送 Range: bytes=0-0 探测请求,onDone(是否返回 206)。
    void probeRange(const QString &url, std::function<void(bool ok)> onDone);

signals:
    void serverUrlChanged();
    void serverInfoChanged();
    void loginChanged();
    void publicInfoReceived();
    void loginSucceeded();
    void viewsReceived();
    void itemsReceived();
    // url 为绝对播放地址;headers 为流请求所需的 "Name: Value" 头列表;
    // meta 含 itemId/mediaSourceId/playSessionId/playMethod,供播放回传使用。
    void playbackReady(const QString &url, const QVariantList &headers, const QVariantMap &meta);
    // 条目详情(Overview/Genres/ProductionYear/CommunityRating/RunTimeTicks 等)。
    void itemDetailReady(const QVariantMap &detail);
    void errorOccurred(const QString &message);

private:
    // 构造 QNetworkRequest:拼接服务器地址与路径,附带认证头。
    QNetworkRequest makeRequest(const QString &path, bool auth, bool json = false) const;
    // GET 请求,成功回调解析后的 JSON,失败发 errorOccurred。
    void get(const QString &path, bool auth,
             std::function<void(const QJsonDocument &)> onOk,
             const QString &what);
    // POST JSON 请求,成功回调解析后的 JSON,失败发 errorOccurred。
    void postJson(const QString &path, const QJsonObject &body, bool auth,
                  std::function<void(const QJsonDocument &)> onOk,
                  const QString &what);
    // 发送播放状态回传(失败仅记日志,不阻断播放)。
    void postReport(const QString &endpoint, const QJsonObject &body);
    // 构造 X-Emby-Authorization 头(官方 "Emby ..." 格式),带 Token 与否可选。
    QString authHeader(bool withToken) const;

    QNetworkAccessManager m_nam;
    QSettings m_settings;
    MediaItemModel m_viewsModel;
    MediaItemModel m_itemsModel;
    QHash<QString, QString> m_rangePrefix; // serverUrl -> "" | "/emby"（Range 前缀探测缓存）
    int m_itemsSeq = 0; // 条目请求序号,丢弃过期响应(视图快速切换时)
    QString m_serverName;
    QString m_serverVersion;
    QString m_userId;
    QString m_userName;
    QString m_accessToken;
};
