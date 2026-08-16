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

    // 全局代理(来自 ConfigManager;NoProxy = 直连,默认)。热重载后
    // main.cpp 经 proxyChanged 重新调用,作用于之后的所有请求。
    void setProxy(const QNetworkProxy &proxy);

    // 按服务器取模型(首次访问创建);账号删除时用 dropServerModels 清理。
    Q_INVOKABLE MediaItemModel *viewsModelFor(const QString &serverUrl);
    Q_INVOKABLE MediaItemModel *itemsModelFor(const QString &serverUrl);
    Q_INVOKABLE MediaItemModel *seasonsModelFor(const QString &serverUrl);
    Q_INVOKABLE MediaItemModel *episodesModelFor(const QString &serverUrl);
    Q_INVOKABLE MediaItemModel *searchModelFor(const QString &serverUrl);
    Q_INVOKABLE MediaItemModel *similarModelFor(const QString &serverUrl);
    Q_INVOKABLE MediaItemModel *allEpisodesModelFor(const QString &serverUrl);
    Q_INVOKABLE MediaItemModel *genresModelFor(const QString &serverUrl);
    Q_INVOKABLE MediaItemModel *foldersModelFor(const QString &serverUrl);
    Q_INVOKABLE void dropServerModels(const QString &serverUrl);

    // 服务器公开信息(/System/Info/Public,无需认证),取 ServerName。
    Q_INVOKABLE void fetchServerPublicInfo(const QString &serverUrl);
    // 浏览器式获取服务器图标:请求 web 首页 HTML,解析 <link rel="icon">
    // 标签(apple-touch-icon 192 优先,其次 icon/shortcut icon),href 相对
    // 路径按 RFC 3986 相对文档 URL 解析,随后下载图标图片字节;HTML 拉取
    // 失败或无图标标签时发空结果。Emby 官方 API 无图标端点,图标是 web
    // 静态资源且路径随部署不同,故用 HTML 解析。仅添加服务器时调用;
    // 图片字节由 AccountManager 落盘本地缓存(不存远程 URL)。
    Q_INVOKABLE void fetchServerIcon(const QString &serverUrl);
    // 校验 token 有效性(/System/Info 轻量认证请求):401 经 serverRequestFailed
    // 通知(AccountManager 标失效/重登),网络错误与超时不算失效(静默)。
    Q_INVOKABLE void validateToken(const QString &serverUrl, const QString &token,
                                   const QString &userId);
    // 用户名密码登录(/Users/AuthenticateByName):凭据经 loginSucceeded
    // (serverUrl, token, userId, userName) 返回,不设置会话状态;
    // 调用方(AccountManager 存账号 / 表单直连浏览)自行保管凭据。
    Q_INVOKABLE void login(const QString &serverUrl, const QString &username,
                           const QString &password);
    // 通知服务器会话结束(/Sessions/Logout,官方 Requires authentication
    // as user)。结果完全忽略:部分 Emby 服务器未实现该端点,登出失败
    // 不影响本地删除;不触发任何账号状态信号。
    Q_INVOKABLE void logout(const QString &serverUrl, const QString &token,
                            const QString &userId);
    // 获取用户媒体库视图(/Users/{id}/Views),填充该服务器的 viewsModel。
    Q_INVOKABLE void fetchViews(const QString &serverUrl, const QString &token,
                                const QString &userId);
    // 获取视图条目(/Users/{id}/Items,分页),填充该服务器的 itemsModel。
    // startIndex=0 替换模型否则追加;TotalRecordCount 写入 totalCount。
    // genres/years/minRating/filters 为可选过滤(空串不传):Genres 单值、
    // Years 单值、MinCommunityRating 评分下限、Filters 状态;配合 ParentId
    // (视图或子文件夹 id)即库内多维筛选。
    Q_INVOKABLE void fetchItems(const QString &serverUrl, const QString &token,
                                const QString &userId, const QString &viewId,
                                int startIndex, int limit,
                                const QString &sortBy = QStringLiteral("DateModified"),
                                const QString &sortOrder = QStringLiteral("Descending"),
                                const QString &genres = QString(),
                                const QString &years = QString(),
                                const QString &minRating = QString(),
                                const QString &filters = QString());
    // 库内类型枚举(/Genres?ParentId=,Genre 为 BaseItemDto 带 Id/图),
    // 填充该服务器的 genresModel(名称即 Genres 过滤参数值)。
    Q_INVOKABLE void fetchGenres(const QString &serverUrl, const QString &token,
                                 const QString &userId, const QString &viewId);
    // 库内年份枚举(/Years?ParentId=,TagItem 仅 Name,兼容实现无 Id),
    // 结果经 yearsReceived(serverUrl, names) 返回,QML 端过滤脏值/排序。
    Q_INVOKABLE void fetchYears(const QString &serverUrl, const QString &token,
                                const QString &userId, const QString &viewId);
    // 当前层顶层子文件夹(/Users/{id}/Items?ParentId=&IncludeItemTypes=Folder,
    // 不 Recursive),填充该服务器的 foldersModel,供分组下钻入口。
    Q_INVOKABLE void fetchFolders(const QString &serverUrl, const QString &token,
                                  const QString &userId, const QString &viewId);
    // 收藏/取消收藏(/Users/{id}/FavoriteItems/{itemId} POST/DELETE)。
    Q_INVOKABLE void setFavorite(const QString &serverUrl, const QString &token,
                                 const QString &userId, const QString &itemId, bool fav);
    // 服务端搜索(/Users/{id}/Items?SearchTerm=),填充该服务器的 searchModel。
    // 空串清空结果;防抖在调用方(QML)做,响应按服务器+序号丢弃过期结果。
    // itemTypes/years/filters 空串不传。搜索结果由服务器固定按相关度排序
    // (实测 4.9.5.0 忽略 SortBy/SortOrder),故无排序参数。
    // startIndex=0 替换结果,>0 追加(分页);Limit 内部 +1 探针,多出的
    // 1 条截断并置 model.hasMore 供"加载更多"。
    Q_INVOKABLE void search(const QString &serverUrl, const QString &token,
                            const QString &userId, const QString &term,
                            const QString &itemTypes = QString(),
                            const QString &years = QString(),
                            const QString &filters = QString(),
                            int startIndex = 0,
                            int limit = MoePlayer::kSearchLimit);
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
    // 相似推荐(/Items/{id}/Similar),填充该服务器的 similarModel,发 similarReady。
    Q_INVOKABLE void fetchSimilar(const QString &serverUrl, const QString &token,
                                  const QString &userId, const QString &itemId);
    // 剧集全部集(/Shows/{id}/Episodes 不带 SeasonId),供跨季续播查找。
    Q_INVOKABLE void fetchAllEpisodes(const QString &serverUrl, const QString &token,
                                      const QString &userId, const QString &seriesId);
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
    void similarReady(const QString &serverUrl);
    void allEpisodesReady(const QString &serverUrl);
    // 库内分类枚举结果(见 fetchGenres/fetchYears/fetchFolders):
    // genres/folders 填模型发 serverUrl;years 轻量返回名称列表。
    void genresReceived(const QString &serverUrl);
    void yearsReceived(const QString &serverUrl, const QStringList &years);
    void foldersReceived(const QString &serverUrl);
    // 条目详情(Overview/Genres/ProductionYear/CommunityRating/RunTimeTicks 等)。
    void itemDetailReady(const QString &serverUrl, const QVariantMap &detail);
    // 登录成功:携带目标服务器与凭据(AccountManager 存账号 / 页面直连浏览)。
    void loginSucceeded(const QString &serverUrl, const QString &token,
                        const QString &userId, const QString &userName);
    // 跨服务器拉取结果(见 fetchServer*):serverUrl 标识来源服务器。
    // 请求失败时 views/items 仍发空结果(推进调用方计数),并另发
    // serverRequestFailed 携带失败原因。
    void serverPublicInfoReceived(const QString &serverUrl, const QString &serverName);
    // 服务器图标解析+下载结果(见 fetchServerIcon/downloadServerIconImage):
    // iconUrl 为原始图标 URL(供取扩展名),imageData 为图片字节(空 = 失败,
    // 由 AccountManager 落盘本地缓存,不存远程 URL)。
    void serverIconReceived(const QString &serverUrl, const QString &iconUrl,
                            const QByteArray &imageData);
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
    // 下载图标 URL 图片字节(无认证,Emby /web/ 静态资源):成功发字节、
    // 失败发空,均经 serverIconReceived 返回。fetchServerIcon 解析后调用。
    void downloadServerIconImage(const QString &serverUrl, const QString &iconUrl);
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
    // 解析 HTML 的图标 link 标签:apple-touch-icon 优先(192x192),其次
    // rel 含 icon 的标签;href 相对路径按 baseHtmlUrl 解析,返回绝对 URL。
    static QString parseFaviconLink(const QString &html, const QString &baseHtmlUrl);

    QNetworkAccessManager m_nam;
    QSettings m_settings;
    // 模型按服务器字典化(key = trimmed serverUrl):多服浏览并行互不覆盖。
    QHash<QString, MediaItemModel *> m_viewsModels;
    QHash<QString, MediaItemModel *> m_itemsModels;
    QHash<QString, MediaItemModel *> m_seasonsModels;
    QHash<QString, MediaItemModel *> m_episodesModels;
    QHash<QString, MediaItemModel *> m_searchModels;
    QHash<QString, MediaItemModel *> m_similarModels;
    QHash<QString, MediaItemModel *> m_allEpisodesModels;
    QHash<QString, MediaItemModel *> m_genresModels;
    QHash<QString, MediaItemModel *> m_foldersModels;
    QHash<QString, QString> m_rangePrefix; // serverUrl -> "" | "/emby"(Range 前缀探测缓存)
    // 请求序号按服务器隔离,丢弃过期响应(视图快速切换/输入防抖窗口内旧请求)。
    QHash<QString, int> m_itemsSeq;
    QHash<QString, int> m_searchSeq;
};
