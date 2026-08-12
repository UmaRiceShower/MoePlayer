#pragma once

#include <QObject>
#include <QNetworkAccessManager>
#include <QJsonArray>
#include <QSettings>
#include <QTimer>
#include <QWebSocket>

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
    Q_PROPERTY(bool wsConnected READ wsConnected NOTIFY wsConnectedChanged)
    Q_PROPERTY(MediaItemModel *viewsModel READ viewsModel CONSTANT)
    Q_PROPERTY(MediaItemModel *itemsModel READ itemsModel CONSTANT)
    Q_PROPERTY(MediaItemModel *seasonsModel READ seasonsModel CONSTANT)
    Q_PROPERTY(MediaItemModel *episodesModel READ episodesModel CONSTANT)
    Q_PROPERTY(MediaItemModel *searchModel READ searchModel CONSTANT)
public:
    explicit EmbyClient(QObject *parent = nullptr);

    // 服务器地址,持久化于 QSettings("network/serverUrl"),默认本地回环 8096 端口。
    QString serverUrl() const { return m_settings.value("network/serverUrl", QStringLiteral("http://127.0.0.1:8096")).toString(); }
    void setServerUrl(const QString &v);
    QString serverName() const { return m_serverName; }
    QString serverVersion() const { return m_serverVersion; }
    QString userName() const { return m_userName; }
    // 已登录(持有 AccessToken)。
    bool connected() const { return !m_accessToken.isEmpty(); }
    // WebSocket 实时通道已连接。
    bool wsConnected() const { return m_ws.state() == QAbstractSocket::ConnectedState; }
    QString accessToken() const { return m_accessToken; }
    QString userId() const { return m_userId; }
    MediaItemModel *viewsModel() { return &m_viewsModel; }
    MediaItemModel *itemsModel() { return &m_itemsModel; }
    MediaItemModel *seasonsModel() { return &m_seasonsModel; }
    MediaItemModel *episodesModel() { return &m_episodesModel; }
    MediaItemModel *searchModel() { return &m_searchModel; }

    // 获取服务器公开信息(/System/Info/Public,无需认证)。
    Q_INVOKABLE void fetchPublicInfo();
    // 用户名密码登录(/Users/AuthenticateByName),成功后填 accessToken/userId。
    Q_INVOKABLE void login(const QString &username, const QString &password);
    // 用已保存的凭据配置会话(多账号切换/启动自动登录):设 serverUrl/token/
    // userId 后直接拉取视图,请求 401 即 token 失效(发 authFailed)。
    // Emby 4.9 无 /Users/Me 端点,userId 由登录时保存。
    Q_INVOKABLE void configureSession(const QString &serverUrl, const QString &token,
                                      const QString &userId, const QString &userName);
    // 获取当前用户的媒体库视图列表(/Users/{id}/Views),填充 viewsModel。
    Q_INVOKABLE void fetchViews();
    // 获取指定视图下的影片条目(/Users/{id}/Items,分页),填充 itemsModel。
    // startIndex=0 时替换模型,否则追加;TotalRecordCount 写入 itemsModel.totalCount。
    // sortBy/sortOrder 传给服务端排序(SortName/DateCreated/DateModified/
    // PremiereDate/ProductionYear/CommunityRating 等;DateLastMediaAdded
    // 在 4.9.5 条目级查询会 SQLiteException,调用方勿用)。
    Q_INVOKABLE void fetchItems(const QString &viewId, int startIndex, int limit,
                                const QString &sortBy = QStringLiteral("DateModified"),
                                const QString &sortOrder = QStringLiteral("Descending"));
    // 收藏/取消收藏(/Users/{id}/FavoriteItems/{itemId} POST/DELETE)。
    Q_INVOKABLE void setFavorite(const QString &itemId, bool fav);
    // 服务端搜索(/Users/{id}/Items?SearchTerm=,跨库递归),填充 searchModel。
    // 空串清空结果;防抖在调用方(QML)做,响应按请求序号丢弃过期结果。
    Q_INVOKABLE void search(const QString &term);
    // 获取剧集的分季列表(/Shows/{id}/Seasons),填充 seasonsModel。
    Q_INVOKABLE void fetchSeasons(const QString &seriesId);
    // 获取指定季的分集列表(/Shows/{id}/Episodes?SeasonId=),填充 episodesModel。
    Q_INVOKABLE void fetchEpisodes(const QString &seriesId, const QString &seasonId);
    // 跨服务器只读拉取(不改变当前会话):按显式凭据请求,结果经对应信号返回。
    // 供首页聚合遍历所有账号时使用;认证头与服务器地址均取参数而非会话状态。
    // 拉取服务器公开信息(/System/Info/Public,无需认证),取 ServerName 作聚合行前缀。
    Q_INVOKABLE void fetchServerPublicInfo(const QString &serverUrl);
    // 拉取指定服务器的视图列表,views 为 [{id,name,posterId}]。
    Q_INVOKABLE void fetchServerViews(const QString &serverUrl, const QString &token,
                                      const QString &userId);
    // 拉取指定库按加入时间倒序的前 limit 条,items 为 [{id,name,posterId,type}]。
    Q_INVOKABLE void fetchServerItems(const QString &serverUrl, const QString &token,
                                      const QString &userId, const QString &viewId, int limit);
    // 跨服务器账密登录(不改当前会话),供 token 失效后重登。
    // 结果经 serverLoginFinished 通知。
    Q_INVOKABLE void loginFor(const QString &serverUrl, const QString &username,
                              const QString &password);
    // 播放协商(/Items/{id}/PlaybackInfo),解析出可播放地址后发 playbackReady。
    Q_INVOKABLE void fetchPlaybackInfo(const QString &itemId);
    // 获取条目详情(/Users/{id}/Items/{itemId}),发 itemDetailReady。
    Q_INVOKABLE void fetchItemDetail(const QString &itemId);
    // 写入已看/继续观看状态(/Users/{id}/Items/{itemId}/UserData)。
    // played=true 表示看完(位置清零);否则写入上次播放位置供继续观看。
    // 服务器不会自动维护继续观看位置,须由客户端在停止时写入。
    Q_INVOKABLE void setWatched(const QString &itemId, bool played,
                                double positionTicks = 0, double playedPercentage = -1);
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
    // 认证失败(HTTP 401):token 失效或权限不足,应回到登录流程。
    void authFailed();
    void viewsReceived();
    void itemsReceived();
    // 搜索完成:searchModel 已更新(含空串请求的清空)。
    void searchResultsReady();
    void seasonsReceived();
    void episodesReceived();
    // 跨服务器拉取结果(见 fetchServer*):serverUrl 标识来源服务器。
    // 请求失败时 views/items 仍发空结果(推进调用方计数),并另发
    // serverRequestFailed 携带失败原因。
    void serverPublicInfoReceived(const QString &serverUrl, const QString &serverName);
    void serverViewsReceived(const QString &serverUrl, const QVariantList &views);
    void serverItemsReceived(const QString &serverUrl, const QString &viewId,
                             const QVariantList &items);
    // 跨服务器请求失败:message 含 "HTTP 401" 表示 token 失效,否则为网络/服务器错误。
    void serverRequestFailed(const QString &serverUrl, const QString &message);
    // 跨服务器账密登录结果(见 loginFor)。
    void serverLoginFinished(const QString &serverUrl, bool ok, const QString &token,
                             const QString &userId, const QString &userName);
    // WebSocket 连接状态变化(登录成功后建立,断线自动重连)。
    void wsConnectedChanged();
    // 服务器实时推送(Emby 4.9 仅广播 UserDataChanged/LibraryChanged/
    // RefreshProgress,不广播播放事件):data 为消息 Data 对象。
    void serverEventReceived(const QString &messageType, const QVariantMap &data);
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
    // 跨服务器 GET(显式 serverUrl/token/userId,不改会话状态)。
    // 失败发 serverRequestFailed + errorOccurred,并调用 onFail(推进计数)。
    void getFrom(const QString &serverUrl, const QString &token, const QString &userId,
                 const QString &path, std::function<void(const QJsonDocument &)> onOk,
                 std::function<void()> onFail, const QString &what);
    // 跨服务器 POST(无认证头,登录端点用),失败发 serverRequestFailed 并调用 onFail。
    void postFrom(const QString &serverUrl, const QString &path, const QJsonObject &body,
                  std::function<void(const QJsonDocument &)> onOk,
                  std::function<void()> onFail, const QString &what);
    // POST JSON 请求,成功回调解析后的 JSON,失败发 errorOccurred。
    void postJson(const QString &path, const QJsonObject &body, bool auth,
                  std::function<void(const QJsonDocument &)> onOk,
                  const QString &what);
    // DELETE 请求(无请求体),成功回调解析后的 JSON,失败发 errorOccurred。
    void del(const QString &path, bool auth,
             std::function<void(const QJsonDocument &)> onOk,
             const QString &what);
    // 发送播放状态回传(失败仅记日志,不阻断播放)。
    void postReport(const QString &endpoint, const QJsonObject &body);
    // 建立/重连 WebSocket(/embywebsocket,带 api_key 认证)。
    void connectWebSocket();
    // 处理服务器推送消息,按 MessageType 分发。
    void handleWsMessage(const QJsonObject &msg);
    // 构造 WebSocket 地址:http(s)://host[:port] → ws(s)://host[:port]/embywebsocket。
    QString webSocketUrl() const;
    // 构造 X-Emby-Authorization 头(官方 "Emby ..." 格式),带 Token 与否可选。
    QString authHeader(bool withToken) const;
    // 按显式凭据构造 X-Emby-Authorization 头(跨服务器请求用)。
    QString authHeaderFor(const QString &userId, const QString &token) const;

    QNetworkAccessManager m_nam;
    QSettings m_settings;
    QWebSocket m_ws; // /embywebsocket 长连接(登录后建立)
    QTimer m_wsReconnect; // 断线重连定时器(指数退避)
    int m_wsReconnectDelay = 3000;
    MediaItemModel m_viewsModel;
    MediaItemModel m_itemsModel;
    MediaItemModel m_seasonsModel;
    MediaItemModel m_episodesModel;
    MediaItemModel m_searchModel;
    QHash<QString, QString> m_rangePrefix; // serverUrl -> "" | "/emby"（Range 前缀探测缓存）
    int m_itemsSeq = 0; // 条目请求序号,丢弃过期响应(视图快速切换时)
    int m_searchSeq = 0; // 搜索请求序号,丢弃过期响应(输入防抖窗口内旧请求)
    QString m_serverName;
    QString m_serverVersion;
    QString m_userId;
    QString m_userName;
    QString m_accessToken;
};
