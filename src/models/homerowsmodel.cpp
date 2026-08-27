#include "homerowsmodel.h"

#include <QSet>

HomeRowsModel::HomeRowsModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int HomeRowsModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_rows.size();
}

QVariant HomeRowsModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_rows.size())
        return QVariant();
    if (role == RowRole)
        return m_rows.at(index.row());
    return QVariant();
}

QHash<int, QByteArray> HomeRowsModel::roleNames() const
{
    return { { RowRole, "row" } };
}

QVariantMap HomeRowsModel::rowAt(int row) const
{
    if (row < 0 || row >= m_rows.size())
        return QVariantMap();
    return m_rows.at(row);
}

QString HomeRowsModel::idKey(const QVariantMap &row)
{
    return row.value(QStringLiteral("accountId")).toString() + QLatin1Char('|')
           + row.value(QStringLiteral("viewId")).toString();
}

void HomeRowsModel::setRows(const QVariantList &rows)
{
    QHash<QString, QVariantMap> byKey;
    for (const auto &r : rows) {
        const QVariantMap m = r.toMap();
        byKey.insert(idKey(m), m);
    }

    int mi = 0; // 模型当前行
    for (int oi = 0; oi < rows.size();) {
        // 清理前缀中已不在 rows 的模型行(按身份判定)。
        while (mi < m_rows.size() && !byKey.contains(idKey(m_rows.at(mi)))) {
            beginRemoveRows(QModelIndex(), mi, mi);
            m_rows.removeAt(mi);
            endRemoveRows();
        }
        const QVariantMap want = rows.at(oi).toMap();
        const QString wantKey = idKey(want);
        if (mi < m_rows.size() && idKey(m_rows.at(mi)) == wantKey) {
            // 已有该行:内容不同才更新(逐行 dataChanged)。
            if (m_rows.at(mi) != want) {
                m_rows[mi] = want;
                emit dataChanged(index(mi), index(mi), { RowRole });
            }
            ++mi;
            ++oi;
        } else {
            // 该位没对应行(新库到位):插入。
            beginInsertRows(QModelIndex(), mi, mi);
            m_rows.insert(mi, want);
            endInsertRows();
            ++mi;
            ++oi;
        }
    }
    // 清掉尾部多余的模型行。
    while (mi < m_rows.size()) {
        beginRemoveRows(QModelIndex(), mi, mi);
        m_rows.removeAt(mi);
        endRemoveRows();
    }
    emit countChanged();
}

void HomeRowsModel::clear()
{
    if (m_rows.isEmpty())
        return;
    beginResetModel();
    m_rows.clear();
    endResetModel();
    emit countChanged();
}
