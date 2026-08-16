#include "mediaitemmodel.h"

#include <QJsonObject>

MediaItemModel::MediaItemModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int MediaItemModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_items.size();
}

QVariant MediaItemModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_items.size())
        return {};
    const MediaItem &it = m_items.at(index.row());
    switch (role) {
    case NameRole:           return it.name;
    case IdRole:             return it.id;
    case PosterIdRole:       return it.posterId;
    case ParentBackdropIdRole: return it.parentBackdropId;
    case TypeRole:           return it.type;
    case YearRole:           return it.year;
    case RatingRole:         return it.rating;
    case PlayedRole:         return it.played;
    case FavoriteRole:       return it.favorite;
    case PositionTicksRole:  return it.positionTicks;
    case RuntimeTicksRole:   return it.runtimeTicks;
    case UnplayedCountRole:  return it.unplayedCount;
    case EpisodeNoRole:      return it.episodeNo;
    case SeasonNoRole:       return it.seasonNo;
    }
    return {};
}

QHash<int, QByteArray> MediaItemModel::roleNames() const
{
    return {
        { NameRole, "name" },
        { IdRole, "id" },
        { PosterIdRole, "posterId" },
        { ParentBackdropIdRole, "parentBackdropId" },
        { TypeRole, "type" },
        { YearRole, "year" },
        { RatingRole, "rating" },
        { PlayedRole, "played" },
        { FavoriteRole, "favorite" },
        { PositionTicksRole, "positionTicks" },
        { RuntimeTicksRole, "runtimeTicks" },
        { UnplayedCountRole, "unplayedCount" },
        { EpisodeNoRole, "episodeNo" },
        { SeasonNoRole, "seasonNo" },
    };
}

// 解析一条 Emby Items JSON 为模型条目;withPosters 为真时解析 ImageTags.Primary,
// 海报 id 加服务器前缀(prefix~itemId~tag,无状态浏览按服务器路由取图)。
static MediaItem parseItem(const QJsonValue &v, bool withPosters, const QString &prefix)
{
    const QJsonObject o = v.toObject();
    MediaItem it;
    it.name = o.value(QLatin1String("Name")).toString();
    it.id = o.value(QLatin1String("Id")).toString();
    it.type = o.value(QLatin1String("Type")).toString();
    it.year = o.value(QLatin1String("ProductionYear")).toInt(0);
    it.rating = o.value(QLatin1String("CommunityRating")).toDouble(0);
    it.runtimeTicks = o.value(QLatin1String("RunTimeTicks")).toDouble(0);
    it.episodeNo = o.value(QLatin1String("IndexNumber")).toInt(0);
    it.seasonNo = o.value(QLatin1String("ParentIndexNumber")).toInt(0);
    // 季条目(/Shows/x/Seasons)无 ParentIndexNumber,季号在 IndexNumber。
    if (it.type == QLatin1String("Season") && it.seasonNo == 0)
        it.seasonNo = it.episodeNo;
    // UserData 随 /Items 列表返回:已看状态、观看进度、未看集数零额外请求。
    const QJsonObject ud = o.value(QLatin1String("UserData")).toObject();
    it.played = ud.value(QLatin1String("Played")).toBool(false);
    it.favorite = ud.value(QLatin1String("IsFavorite")).toBool(false);
    it.positionTicks = ud.value(QLatin1String("PlaybackPositionTicks")).toDouble(0);
    it.unplayedCount = ud.value(QLatin1String("UnplayedItemCount")).toInt(0);
    if (withPosters) {
        const QString tag = o.value(QLatin1String("ImageTags"))
                                .toObject().value(QLatin1String("Primary")).toString();
        // 分隔符用 ~ 而非 |:后者在 image:// URL 中会被转义,见 PosterProvider。
        // 格式 <prefix>~<id>~<tag>(前缀与 id 之间必须有 ~,供提供器切分)。
        if (!tag.isEmpty())
            it.posterId = prefix + QLatin1Char('~') + it.id + QLatin1Char('~') + tag;
        // 无海报回退图:父级(剧集)背景,格式 <prefix>~<ParentBackdropItemId>~
        // <tag>~Backdrop(ParentBackdropImageTags 属默认返回组,列表请求即带)。
        const QJsonArray pbt = o.value(QLatin1String("ParentBackdropImageTags")).toArray();
        const QString pbid = o.value(QLatin1String("ParentBackdropItemId")).toString();
        if (!pbt.isEmpty() && !pbid.isEmpty())
            it.parentBackdropId = prefix + QLatin1Char('~') + pbid + QLatin1Char('~')
                                  + pbt.first().toString() + QStringLiteral("~Backdrop");
    }
    return it;
}

void MediaItemModel::setItems(const QJsonArray &items, bool withPosters)
{
    beginResetModel();
    m_items.clear();
    m_items.reserve(items.size());
    for (const auto &v : items) {
        const MediaItem it = parseItem(v, withPosters, m_serverPrefix);
        if (!it.id.isEmpty())
            m_items.append(it);
    }
    endResetModel();
    emit countChanged();
}

void MediaItemModel::appendItems(const QJsonArray &items, bool withPosters)
{
    const int first = m_items.size();
    QList<MediaItem> page;
    page.reserve(items.size());
    for (const auto &v : items) {
        const MediaItem it = parseItem(v, withPosters, m_serverPrefix);
        if (!it.id.isEmpty())
            page.append(it);
    }
    if (page.isEmpty())
        return;
    beginInsertRows(QModelIndex(), first, first + page.size() - 1);
    m_items.append(page);
    endInsertRows();
    emit countChanged();
}

void MediaItemModel::setTotal(int total)
{
    if (total == m_total)
        return;
    m_total = total;
    emit totalCountChanged();
}

void MediaItemModel::clear()
{
    beginResetModel();
    m_items.clear();
    endResetModel();
    emit countChanged();
}

QString MediaItemModel::idAt(int row) const
{
    return (row >= 0 && row < m_items.size()) ? m_items.at(row).id : QString();
}

QString MediaItemModel::nameAt(int row) const
{
    return (row >= 0 && row < m_items.size()) ? m_items.at(row).name : QString();
}

QVariantMap MediaItemModel::itemAt(int row) const
{
    QVariantMap m;
    if (row < 0 || row >= m_items.size())
        return m;
    const MediaItem &it = m_items.at(row);
    m.insert(QStringLiteral("name"), it.name);
    m.insert(QStringLiteral("id"), it.id);
    m.insert(QStringLiteral("posterId"), it.posterId);
    m.insert(QStringLiteral("parentBackdropId"), it.parentBackdropId);
    m.insert(QStringLiteral("type"), it.type);
    m.insert(QStringLiteral("year"), it.year);
    m.insert(QStringLiteral("rating"), it.rating);
    m.insert(QStringLiteral("played"), it.played);
    m.insert(QStringLiteral("favorite"), it.favorite);
    m.insert(QStringLiteral("positionTicks"), it.positionTicks);
    m.insert(QStringLiteral("runtimeTicks"), it.runtimeTicks);
    m.insert(QStringLiteral("unplayedCount"), it.unplayedCount);
    m.insert(QStringLiteral("episodeNo"), it.episodeNo);
    m.insert(QStringLiteral("seasonNo"), it.seasonNo);
    return m;
}


QString MediaItemModel::posterIdAt(int row) const
{
    return (row >= 0 && row < m_items.size()) ? m_items.at(row).posterId : QString();
}

void MediaItemModel::setPlayedAt(int row, bool played)
{
    if (row < 0 || row >= m_items.size() || m_items.at(row).played == played)
        return;
    m_items[row].played = played;
    emit dataChanged(index(row), index(row), { PlayedRole });
}

void MediaItemModel::setFavoriteAt(int row, bool fav)
{
    if (row < 0 || row >= m_items.size() || m_items.at(row).favorite == fav)
        return;
    m_items[row].favorite = fav;
    emit dataChanged(index(row), index(row), { FavoriteRole });
}

void MediaItemModel::setPlayedById(const QString &itemId, bool played)
{
    for (int i = 0; i < m_items.size(); ++i) {
        if (m_items.at(i).id == itemId) {
            setPlayedAt(i, played);
            return;
        }
    }
}

void MediaItemModel::setFavoriteById(const QString &itemId, bool fav)
{
    for (int i = 0; i < m_items.size(); ++i) {
        if (m_items.at(i).id == itemId) {
            setFavoriteAt(i, fav);
            return;
        }
    }
}
