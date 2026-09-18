#include "recentsearches.h"

#include "apppaths.h"

RecentSearches::RecentSearches(QObject *parent)
    : QObject(parent)
    // 用户行为数据
    , m_persist(AppPaths::dataDir())
{
    QVariant v;
    if (m_persist.loadCache(QStringLiteral("recent-searches"), v))
        m_items = v.toStringList();
}

QVariantList RecentSearches::list() const
{
    QVariantList out;
    out.reserve(m_items.size());
    for (const QString &s : m_items)
        out.append(s);
    return out;
}

void RecentSearches::add(const QString &query)
{
    const QString q = query.trimmed();
    if (q.isEmpty())
        return;
    m_items.removeAll(q);
    m_items.prepend(q);
    while (m_items.size() > kMax)
        m_items.removeLast();
    save();
    emit listChanged();
}

void RecentSearches::remove(const QString &query)
{
    if (m_items.removeAll(query) == 0)
        return;
    save();
    emit listChanged();
}

void RecentSearches::save()
{
    m_persist.saveCache(QStringLiteral("recent-searches"), m_items);
}
