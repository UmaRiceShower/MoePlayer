#include "homerowsfiltermodel.h"

#include "homerowsmodel.h"

#include <QJSEngine>
#include <QtQml>

HomeRowsFilterModel::HomeRowsFilterModel(QObject *parent)
    : QSortFilterProxyModel(parent)
{
}

void HomeRowsFilterModel::setPlainSource(QAbstractItemModel *m)
{
    m_plain = m;
    applySource();
}

void HomeRowsFilterModel::setCustomSource(QAbstractItemModel *m)
{
    m_custom = m;
    applySource();
}

void HomeRowsFilterModel::setCustomActive(bool b)
{
    if (m_customActive == b)
        return;
    m_customActive = b;
    applySource();
    emit customActiveChanged();
}

void HomeRowsFilterModel::applySource()
{
    QAbstractItemModel *t = (m_customActive && m_custom) ? m_custom : m_plain;
    if (t && t != sourceModel())
        setSourceModel(t);
}

void HomeRowsFilterModel::setFilterPredicate(const QJSValue &fn)
{
    m_pred = fn;
    refilter();
}

void HomeRowsFilterModel::refilter()
{
    beginFilterChange();
    endFilterChange();
}

bool HomeRowsFilterModel::filterAcceptsRow(int sourceRow, const QModelIndex &sourceParent) const
{
    if (!m_pred.isCallable())
        return true;
    auto *src = qobject_cast<HomeRowsModel *>(sourceModel());
    if (!src)
        return true;
    // QVariantMap → JS 对象(模型由 QML 创建,qmlEngine 可得)。
    QJSEngine *eng = qmlEngine(this);
    const QJSValue arg = eng ? eng->toScriptValue(src->rowAt(sourceRow))
                             : QJSValue();
    return m_pred.call(QJSValueList{ arg }).toBool();
}
