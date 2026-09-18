#pragma once

#include <QObject>
#include <QStringList>
#include <QVariantList>

#include "persistmap.h"

//! 最近搜索词(全局单例,QML 名 RecentSearches):全局搜索框的历史记录。
//! 存储 = PersistMap 缓存层(DataLocation/recent-searches.json);
//! 最多 10 条,新词置前、去重(大小写敏感,
//! 与搜索行为一致)。
class RecentSearches : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList list READ list NOTIFY listChanged)
public:
    explicit RecentSearches(QObject *parent = nullptr);

    QVariantList list() const;
    // 记录一次搜索(回车/点结果):空串去空白后忽略。
    Q_INVOKABLE void add(const QString &query);
    Q_INVOKABLE void remove(const QString &query);

signals:
    void listChanged();

private:
    void save();

    static constexpr int kMax = 10;
    QStringList m_items;
    PersistMap m_persist;
};
