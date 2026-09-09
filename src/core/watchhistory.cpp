#include "watchhistory.h"

#include <QDateTime>
#include <QStandardPaths>

#include <algorithm>

namespace {
// 记录上限:超出按最近播放时间保留最新一批(记录只是定位/聚合线索,旧记录可丢)。
constexpr int kMaxRecords = 500;
const QString kCacheName = QStringLiteral("watch-history");

// 记录归属键:服务器 + 账号(同服多账号的观看记录各自独立)。
QString scopeOf(const QString &serverUrl, const QString &accountId)
{
    return serverUrl.trimmed() + QLatin1Char('|') + accountId;
}
} // namespace

WatchHistory::WatchHistory(QObject *parent)
    : QObject(parent)
    , m_persist(&m_settings, QStandardPaths::writableLocation(QStandardPaths::CacheLocation))
{
    QVariant val;
    if (m_persist.loadCache(kCacheName, val))
        m_records = val.toList();
}

void WatchHistory::record(const QString &serverUrl, const QString &accountId,
                          const QString &itemId, const QString &type,
                          const QString &seriesId, const QString &seriesName,
                          int seasonNo, int episodeNo, double positionTicks, bool played)
{
    if (itemId.isEmpty())
        return;
    const QString scope = scopeOf(serverUrl, accountId);
    QVariantMap rec;
    rec.insert(QStringLiteral("scope"), scope);
    rec.insert(QStringLiteral("itemId"), itemId);
    rec.insert(QStringLiteral("type"), type);
    rec.insert(QStringLiteral("seriesId"), seriesId);
    rec.insert(QStringLiteral("seriesName"), seriesName);
    rec.insert(QStringLiteral("seasonNo"), seasonNo);
    rec.insert(QStringLiteral("episodeNo"), episodeNo);
    rec.insert(QStringLiteral("positionTicks"), positionTicks);
    rec.insert(QStringLiteral("played"), played);
    rec.insert(QStringLiteral("lastPlayedAt"), QDateTime::currentMSecsSinceEpoch());
    // 同一条目再次播放 = 更新同一条(保留唯一,避免记录膨胀)。
    for (int i = 0; i < m_records.size(); ++i) {
        const QVariantMap r = m_records.at(i).toMap();
        if (r.value(QStringLiteral("scope")).toString() == scope
            && r.value(QStringLiteral("itemId")).toString() == itemId) {
            m_records[i] = rec;
            save();
            return;
        }
    }
    m_records.append(rec);
    if (m_records.size() > kMaxRecords) {
        std::sort(m_records.begin(), m_records.end(),
                  [](const QVariant &a, const QVariant &b) {
                      return a.toMap().value(QStringLiteral("lastPlayedAt")).toLongLong()
                             < b.toMap().value(QStringLiteral("lastPlayedAt")).toLongLong();
                  });
        m_records = m_records.mid(m_records.size() - kMaxRecords);
    }
    save();
}

QVariantMap WatchHistory::lastEpisode(const QString &serverUrl, const QString &accountId,
                                      const QString &seriesId) const
{
    const QString scope = scopeOf(serverUrl, accountId);
    QVariantMap best;
    qint64 bestAt = -1;
    for (const QVariant &v : m_records) {
        const QVariantMap r = v.toMap();
        if (r.value(QStringLiteral("scope")).toString() != scope
            || r.value(QStringLiteral("seriesId")).toString() != seriesId)
            continue;
        const qint64 at = r.value(QStringLiteral("lastPlayedAt")).toLongLong();
        if (at > bestAt) {
            bestAt = at;
            best = r;
        }
    }
    return best;
}

void WatchHistory::save()
{
    m_persist.saveCache(kCacheName, m_records);
}
