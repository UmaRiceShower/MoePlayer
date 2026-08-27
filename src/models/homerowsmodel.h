#pragma once

#include <QAbstractListModel>
#include <QVariantList>

//! 首页聚合行模型(单 role):每行一个 QVariantMap,供 QML 按行增量更新。
//! 单 role("row" 返回整行 map)下 QML delegate 的 modelData 即该行 map,
//! 与原有 `modelData.viewId` 等绑定兼容。setRows 按 (accountId|viewId)
//! 逐行 diff:插入/更新/删除各自发 beginInsertRows/dataChanged/
//! beginRemoveRows,只触发受影响那行的 delegate 重估,不做整表重置。
class HomeRowsModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)
public:
    enum Roles {
        RowRole = Qt::UserRole + 1,
    };

    explicit HomeRowsModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int count() const { return m_rows.size(); }
    // 取第 row 行(整行 map),越界返回空 map。
    Q_INVOKABLE QVariantMap rowAt(int row) const;

    // 用新的行序列同步模型:按 (accountId|viewId) 逐行 diff,只对
    // 实际变化的行发 per-row 信号(插入/更新/删除);顺序跟随 rows。
    void setRows(const QVariantList &rows);
    // 清空全部行。
    void clear();

signals:
    void countChanged();

private:
    static QString idKey(const QVariantMap &row);

    QList<QVariantMap> m_rows;
};
