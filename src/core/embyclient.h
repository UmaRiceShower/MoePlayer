#pragma once

#include <QObject>
#include <QNetworkAccessManager>
#include <QJsonArray>
#include <QSettings>

#include <functional>

#include "core/constants.h"
#include "models/mediaitemmodel.h"

//! Emby REST 客户端(QML 单例 "MoePlayer.Core EmbyClient")。
//! 无状态浏览:每个请求显式携带目标服务器凭据(serverUrl/token/userId),
//! 不维护"当前会话";多服务器浏览完全并行(HTTP 无状态),结果按服务器
//! 路由到独立模型。模型按服务器字典化(modelFor(serverUrl) 查询),
//! 页面绑定模型时一次性取引用(serverKey = trimmed serverUrl)。
//! WS 实时通道与播放回传同样按服务器路由(回传凭据随播放 meta 携带;
//! WS 多路为后续工作,当前不自动建立连接)。
class EmbyClient : public QObject
{
    Q_OBJECT
public:
    explicit EmbyClient(QObject *parent = nullptr);

    // 按服务器取模型(首次访问创建);账号删除时用 dropServerModels 清理。
    Q_INVOKABLE MediaItemModel *viewsModelFor(const QString &serverUrl);
    Q_INVOKABLE MediaItemModel *itemsModelFor(const QString &serverUrl);
    Q_INVOKABLE MediaItemModel *seasonsModelFor(const QString &serverUrl);
    Q_INVOKABLE MediaItemModel *episodesModelFor(const QString &serverUrl);
    Q_INVOKABLE MediaItemModel *searchModelFor(const QString &serverUrl);
    // 删除某服务器的全部模型(账号删除时调用,防无界增长)。
    Q_INVOKABLE void dropServerModels(const QString &serverUrl);

    // 服务器公开信息(/System/Info/Public,无需认证),取 ServerName。
    Q_INVOKABLE void fetchServerPublicInfo(const QString &serverUrl);
    // 用户名密码登录(/Users/AuthenticateByName):凭据经 loginSucceeded
    // (serverUrl, token, userId, userName) 返回,不设置会话状态;
    // 调用方(AccountManager 存账号 / 表单直连浏览)自行保管凭据。
    Q_INVOKABLE void login(const QString &serverUrl, const QString &username,
                           const QString &password);
    // 获取用户媒体库视图(/Users/{id}/Views),填充该服务器的 viewsModel。
    Q_INVOKABLE void fetchViews(const QString &serverUrl, const QString &token,
                                const QString &userId);
    // 获取视图条目(/Users/{id}/Items,分页),填充该服务器的 itemsModel。
    // startIndex=0 替换模型否则追加;TotalRecordCount 写入 totalCount。
    Q_INVOKABLE void fetchItems(const QString &serverUrl, const QString &token,
                                const QString &userId, const QString &viewId,
                                int startIndex, int limit,
                                const QString &sortBy = QStringLiteral("DateModified"),
                                const QString &sortOrder = QStringLiteral("Descending"));
    // 收藏/取消收藏(/Users/{id}/FavoriteItems/{itemId} POST/DELETE)。
    Q_INVOKABLE void setFavorite(const QString &serverUrl, const QString &token,
                                 const QString &userId, const QString &itemId, bool fav);
    // 服务端搜索(/Users/{id}/Items?SearchTerm=),填充该服务器的 searchModel。
    // 空串清空结果;防抖在调用方(QML)做,响应按服务器+序号丢弃过期结果。
    Q_INVOKABLE void search(const QString &serverUrl, const QString &token,
                            const QString &userId, const QString &term);
    // 剧集分季列表(/Shows/{id}/Seasons),填充该服务器的 seasonsModel。
    Q_INVOKABLE void fetchSeasons(const QString &serverUrl, const QString &token,
                                  const QString &userId, const QString &seriesId);
    // 指定季分集列表(/Shows/{id}/Episodes),填充该服务器的 episodesModel。
    Q_INVOKABLE void fetchEpisodes(const QString &serverUrl, const QString &token,
                                   const QString &userId, const QString &seriesId,
                                   const QString &seasonId);
    // 拉取指定服务器的视图列表(首页聚合,不走模型,结果经 serverViewsReceived)。
    Q_INVOKABLE void fetchServerViews(const QString &serverUrl, const QString &token,
                                      const QString &userId);
    // 拉取指定库按更新时间倒序的前 limit 条(首页聚合,结果经 serverItemsReceived)。
    Q_INVOKABLE void fetchServerItems(const QString &serverUrl, const QString &token,
                                      const QString &userId, const QString &viewId, int limit);
    // 跨服务器账密登录(不改任何状态),供 token 失效后重登。
    // 结果经 serverLoginFinished 通知。
    Q_INVOKABLE void loginFor(const QString &serverUrl, const QString &username,
                              const QString &password);
    // 播放协商(/Items/{id}/PlaybackInfo),解析可播放地址后发 playbackReady。
    Q_INVOKABLE void fetchPlaybackInfo(const QString &serverUrl, const QString &token,
                                       const QString &userId, const QString &itemId);
    // 条目详情(/Users/{id}/Items/{itemId}),发 itemDetailReady。
    Q_INVOKABLE void fetchItemDetail(const QString &serverUrl, const QString &token,
                                     const QString &userId, const QString &itemId);
    // 写入已看/继续观看状态(/Users/{id}/Items/{itemId}/UserData)。
    // played=true 表示看完(位置清零);否则写入上次播放位置供继续观看。
    Q_INVOKABLE void setWatched(const QString &serverUrl, const QString &token,
                                const QString &userId, const QString &itemId, bool played,
                                double positionTicks = 0, double playedPercentage = -1);
    // 播放状态回传四件套(/Sessions/Playing*,按源路由:凭据随 meta 携带)。
    Q_INVOKABLE void reportPlaybackStart(const QString &serverUrl, const QString &token,
                                         const QString &userId, const QString &itemId,
                                         const QString &mediaSourceId, const QString &playSessionId,
                                         const QString &playMethod, double positionSecs);
    Q_INVOKABLE void reportPlaybackProgress(const QString &serverUrl, const QString &token,
                                            const QString &userId, const QString &itemId,
                                            const QString &mediaSourceId, const QString &playSessionId,
                                            const QString &playMethod, double positionSecs, bool paused);
    Q_INVOKABLE void reportPlaybackStopped(const QString &serverUrl, const QString &token,
                                           const QString &userId, const QString &itemId,
                                           const QString &mediaSourceId, const QString &playSessionId,
                                           double positionSecs);
    Q_INVOKABLE void reportPlaybackPing(const QString &serverUrl, const QString &token,
                                        const QString &userId, const QString &playSessionId);

signals:
    // 浏览结果按服务器路由(页面据此判断是否自己的请求)。
    void viewsReceived(const QString &serverUrl);
    void itemsReceived(const QString &serverUrl);
    void searchResultsReady(const QString &serverUrl);
    void seasonsReceived(const QString &serverUrl);
    void episodesReceived(const QString &serverUrl);
    // 条目详情(Overview/Genres/ProductionYear/CommunityRating/RunTimeTicks 等)。
    void itemDetailReady(const QString &serverUrl, const QVariantMap &detail);
    // 登录成功:携带目标服务器与凭据(AccountManager 存账号 / 页面直连浏览)。
    void loginSucceeded(const QString &serverUrl, const QString &token,
                        const QString &userId, const QString &userName);
    // 跨服务器拉取结果(见 fetchServer*):serverUrl 标识来源服务器。
    // 请求失败时 views/items 仍发空结果(推进调用方计数),并另发
    // serverRequestFailed 携带失败原因。
    void serverPublicInfoReceived(const QString &serverUrl, const QString &serverName);
    void serverViewsReceived(const QString &serverUrl, const QVariantList &views);
    void serverItemsReceived(const QString &serverUrl, const QString &viewId,
                             const QVariantList &items);
    // 服务器请求失败:message 含 "HTTP 401" 表示 token 失效,否则为网络/服务器错误。
    // 所有失败(含浏览路径)都发此信号,AccountManager 据此标失效/重登。
    void serverRequestFailed(const QString &serverUrl, const QString &message);
    // 跨服务器账密登录结果(见 loginFor)。
    void serverLoginFinished(const QString &serverUrl, bool ok, const QString &token,
                             const QString &userId, const QString &userName);
    // 播放协商结果:url 为绝对播放地址;headers 为流请求所需的 "Name: Value"
    // 头列表;meta 含 itemId/mediaSourceId/playSessionId/playMethod 及
    // serverUrl/token/userId(播放回传按源路由用)。
    void playbackReady(const QString &serverUrl, const QString &url,
                       const QVariantList &headers, const QVariantMap &meta);
    // 请求错误(按服务器;失败同时发 serverRequestFailed 供账号状态处理)。
    void errorOccurred(const QString &serverUrl, const QString &message);

private:
    // 构造 QNetworkRequest:按显式服务器/凭据拼接路径与认证头。
    QNetworkRequest makeRequest(const QString &serverUrl, const QString &token,
                                const QString &userId, const QString &path, bool json) const;
    // GET 请求:失败发 serverRequestFailed + errorOccurred(均带 serverUrl),
    // 并调用 onFail(可为空;聚合计数推进用)。
    void get(const QString &serverUrl, const QString &token, const QString &userId,
             const QString &path, std::function<void(const QJsonDocument &)> onOk,
             std::function<void()> onFail, const QString &what);
    // 跨服务器 POST(无认证头,登录端点用),失败发 serverRequestFailed 并调用 onFail。
    void postFrom(const QString &serverUrl, const QString &path, const QJsonObject &body,
                  std::function<void(const QJsonDocument &)> onOk,
                  std::function<void()> onFail, const QString &what);
    // POST JSON 请求,失败同上。
    void postJson(const QString &serverUrl, const QString &token, const QString &userId,
                  const QString &path, const QJsonObject &body,
                  std::function<void(const QJsonDocument &)> onOk, const QString &what);
    // DELETE 请求(无请求体),失败同上。
    void del(const QString &serverUrl, const QString &token, const QString &userId,
             const QString &path, std::function<void(const QJsonDocument &)> onOk,
             const QString &what);
    // 发送播放状态回传(失败仅记日志,不阻断播放)。
    void postReport(const QString &serverUrl, const QString &token, const QString &userId,
                    const QString &endpoint, const QJsonObject &body);
    // 探测播放地址支持的路径前缀(见 probeRange);WS 多路为后续工作。
    void probeSeekableUrl(const QString &serverUrl, const QString &token, const QString &userId,
                          const QString &url, std::function<void(const QString &)> onDone);
    // 发送 Range: bytes=0-0 探测请求,onDone(是否返回 206)。
    void probeRange(const QString &serverUrl, const QString &token, const QString &userId,
                    const QString &url, std::function<void(bool ok)> onDone);
    // 按显式凭据构造 X-Emby-Authorization 头(官方 "Emby ..." 格式)。
    QString authHeaderFor(const QString &userId, const QString &token) const;

    QNetworkAccessManager m_nam;
    QSettings m_settings;
    // 模型按服务器字典化(key = trimmed serverUrl):多服浏览并行互不覆盖。
    QHash<QString, MediaItemModel *> m_viewsModels;
    QHash<QString, MediaItemModel *> m_itemsModels;
    QHash<QString, MediaItemModel *> m_seasonsModels;
    QHash<QString, MediaItemModel *> m_episodesModels;
    QHash<QString, MediaItemModel *> m_searchModels;
    QHash<QString, QString> m_rangePrefix; // serverUrl -> "" | "/emby"(Range 前缀探测缓存)
    // 请求序号按服务器隔离,丢弃过期响应(视图快速切换/输入防抖窗口内旧请求)。
    QHash<QString, int> m_itemsSeq;
    QHash<QString, int> m_searchSeq;
};
