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
    case NameRole:     return it.name;
    case IdRole:       return it.id;
    case PosterIdRole: return it.posterId;
    case TypeRole:     return it.type;
    }
    return {};
}

QHash<int, QByteArray> MediaItemModel::roleNames() const
{
    return {
        { NameRole, "name" },
        { IdRole, "id" },
        { PosterIdRole, "posterId" },
        { TypeRole, "type" },
    };
}

// 解析一条 Emby Items JSON 为模型条目;withPosters 为真时解析 ImageTags.Primary。
static MediaItem parseItem(const QJsonValue &v, bool withPosters)
{
    const QJsonObject o = v.toObject();
    MediaItem it;
    it.name = o.value(QLatin1String("Name")).toString();
    it.id = o.value(QLatin1String("Id")).toString();
    it.type = o.value(QLatin1String("Type")).toString();
    if (withPosters) {
        const QString tag = o.value(QLatin1String("ImageTags"))
                                .toObject().value(QLatin1String("Primary")).toString();
        // 分隔符用 ~ 而非 |:后者在 image:// URL 中会被转义,见 PosterProvider。
        if (!tag.isEmpty())
            it.posterId = it.id + QLatin1Char('~') + tag;
    }
    return it;
}

void MediaItemModel::setItems(const QJsonArray &items, bool withPosters)
{
    beginResetModel();
    m_items.clear();
    m_items.reserve(items.size());
    for (const auto &v : items) {
        const MediaItem it = parseItem(v, withPosters);
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
        const MediaItem it = parseItem(v, withPosters);
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

QString MediaItemModel::posterIdAt(int row) const
{
    return (row >= 0 && row < m_items.size()) ? m_items.at(row).posterId : QString();
}
