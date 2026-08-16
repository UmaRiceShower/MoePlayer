#pragma once

#include <QAbstractListModel>
#include <QJsonArray>

#include <QtQml/qqmlregistration.h>

//! 单个媒体条目(Emby Items JSON 解析结果)。
struct MediaItem {
    QString name;
    QString id;
    QString posterId;
    QString parentBackdropId;  // 无海报回退:父级(剧集)背景图 id(无则空)。
    QString type;
    int year = 0;              // ProductionYear,无则为 0。
    double rating = 0;         // CommunityRating,无则为 0。
    bool played = false;       // UserData.Played 已看完。
    bool favorite = false;     // UserData.IsFavorite 已收藏。
    double positionTicks = 0;  // UserData.PlaybackPositionTicks 观看进度。
    double runtimeTicks = 0;   // RunTimeTicks 总时长。
    int unplayedCount = 0;     // UserData.UnplayedItemCount 未看集数(剧集)。
    int episodeNo = 0;         // IndexNumber 集号(分集条目)。
    int seasonNo = 0;          // ParentIndexNumber 季号(分集条目)。
};

//! Emby 视图/媒体库条目列表模型,由 EmbyClient 填充。
//! 角色:name(名称)、id(条目 id)、posterId("<serverKey>~<itemId>~<tag>",
//! 无主图则为空)、parentBackdropId(无海报时的父级背景回退图,无则为空)、
//! type(条目类型,如 "Movie")、year(年份)、rating(评分)、
//! played(已看完)、favorite(收藏)、positionTicks/runtimeTicks(观看进度/总时长)、
//! unplayedCount(未看集数)。
class MediaItemModel : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    //! 服务器端条目总数(Items 查询的 TotalRecordCount),用于分页判断。
    Q_PROPERTY(int totalCount READ totalCount NOTIFY totalCountChanged)
public:
    enum Roles {
        NameRole = Qt::UserRole + 1,
        IdRole,
        PosterIdRole,
        ParentBackdropIdRole,
        TypeRole,
        YearRole,
        RatingRole,
        PlayedRole,
        FavoriteRole,
        PositionTicksRole,
        RuntimeTicksRole,
        UnplayedCountRole,
        EpisodeNoRole,
        SeasonNoRole,
    };

    explicit MediaItemModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int count() const { return m_items.size(); }
    int totalCount() const { return m_total; }

    // 设置海报服务器前缀(encodeServerKey(serverUrl)),此后填充的海报
    // id 形如 <前缀>~<itemId>~<tag>;无状态浏览下所有海报必须带前缀,
    // PosterProvider 据此路由到对应服务器的凭据。
    void setServerPrefix(const QString &prefix) { m_serverPrefix = prefix; }

    // 用 Emby Items JSON 数组重建模型;withPosters 为真时解析 ImageTags.Primary 拼 posterId。
    Q_INVOKABLE void setItems(const QJsonArray &items, bool withPosters);
    // 追加一页条目(分页加载用)。
    Q_INVOKABLE void appendItems(const QJsonArray &items, bool withPosters);
    // 设置服务器端总数。
    Q_INVOKABLE void setTotal(int total);
    // 清空全部条目。
    Q_INVOKABLE void clear();
    // 取第 row 条的 id,越界返回空串。
    Q_INVOKABLE QString idAt(int row) const;
    // 取第 row 条的名称,越界返回空串。
    Q_INVOKABLE QString nameAt(int row) const;
    // 取第 row 条的海报 id(<itemId>~<tag>),越界返回空串。
    Q_INVOKABLE QString posterIdAt(int row) const;
    // 取第 row 条的完整条目(全部 role),越界返回空 map。
    // 详情页选集条/剧集播放键需要按行读取进度/集号等字段。
    Q_INVOKABLE QVariantMap itemAt(int row) const;
    // 就地翻转已看状态(卡片快捷操作后同步模型行,不重拉列表)。
    Q_INVOKABLE void setPlayedAt(int row, bool played);
    // 就地翻转收藏状态。
    Q_INVOKABLE void setFavoriteAt(int row, bool fav);
    // 按条目 id 就地翻转已看/收藏(通用卡片组件用,不依赖行号)。
    Q_INVOKABLE void setPlayedById(const QString &itemId, bool played);
    Q_INVOKABLE void setFavoriteById(const QString &itemId, bool fav);

signals:
    void countChanged();
    void totalCountChanged();

private:
    QList<MediaItem> m_items;
    int m_total = 0;
    QString m_serverPrefix; // 海报 id 服务器前缀(见 setServerPrefix)。
};
