#include "playbackhistory.h"

#include <QDateTime>
#include <QHash>
#include <QStandardPaths>

#include <algorithm>
#include <functional>
#include <utility>

#include "core/constants.h"

namespace {
const QString kCacheName = QStringLiteral("playback-history");

// 是否有播放痕迹:列表端点(SortBy=DatePlayed)会带回从未播放过的条目(实测
// 0 播放账号也能拉到整页无日期的行),Resume 里的"下一未看集"占位同样如此。
// 只接受有痕迹的行,避免"上次播放"落到没看过的分集、或把"下一集"记成已播。
bool hasPlayTrace(const QVariantMap &m)
{
    return m.value(QStringLiteral("played")).toBool()
           || m.value(QStringLiteral("positionTicks")).toDouble() > 0
           || m.value(QStringLiteral("playedPercentage")).toDouble() > 0
           || m.value(QStringLiteral("playCount")).toInt() > 0
           || m.value(QStringLiteral("lastPlayedAt")).toLongLong() > 0;
}

// 记录归属键:服务器 + 账号(同服多账号的播放历史各自独立)。
QString scopeOf(const QString &serverUrl, const QString &accountId)
{
    return serverUrl.trimmed() + QLatin1Char('|') + accountId;
}

// 条目排序:上次播放时间倒序(未知 = 0 排在其后),同未知者按服务器给的
// 顺序 seq。
bool historyBefore(const QVariant &a, const QVariant &b)
{
    const QVariantMap x = a.toMap();
    const QVariantMap y = b.toMap();
    const qint64 xa = x.value(QStringLiteral("lastPlayedAt")).toLongLong();
    const qint64 ya = y.value(QStringLiteral("lastPlayedAt")).toLongLong();
    if (xa != ya)
        return xa > ya;
    return x.value(QStringLiteral("seq")).toInt() < y.value(QStringLiteral("seq")).toInt();
}
} // namespace

PlaybackHistory::PlaybackHistory(QObject *parent)
    : QObject(parent)
    , m_persist(&m_settings, QStandardPaths::writableLocation(QStandardPaths::CacheLocation))
{
    QVariant val;
    if (m_persist.loadCache(kCacheName, val)) {
        const QVariantMap root = val.toMap();
        m_items = root.value(QStringLiteral("items")).toList();
        m_fetchedAt = root.value(QStringLiteral("fetchedAt")).toMap();
    }
}

void PlaybackHistory::setItems(const QString &serverUrl, const QString &accountId,
                               const QVariantList &items)
{
    const QString scope = scopeOf(serverUrl, accountId);
    // 列表端点不返回播放次数/上次播放时间:同一条目旧值保留(明细补全的
    // 结果不因重拉列表丢失)。
    QHash<QString, QVariantMap> merged;
    for (const QVariant &v : std::as_const(m_items)) {
        const QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("scope")).toString() != scope)
            continue;
        const qint64 at = m.value(QStringLiteral("lastPlayedAt")).toLongLong();
        const int count = m.value(QStringLiteral("playCount")).toInt();
        if (at > 0 || count > 0)
            merged.insert(m.value(QStringLiteral("id")).toString(), m);
    }

    QVariantList kept;
    for (const QVariant &v : std::as_const(m_items)) {
        if (v.toMap().value(QStringLiteral("scope")).toString() != scope)
            kept.append(v);
    }
    for (const QVariant &v : items) {
        QVariantMap m = v.toMap();
        m.insert(QStringLiteral("scope"), scope);
        m.insert(QStringLiteral("serverUrl"), serverUrl);
        m.insert(QStringLiteral("accountId"), accountId);
        if (!hasPlayTrace(m))
            continue; // 从未播放过的条目不入库(见 hasPlayTrace)
        const auto old = merged.constFind(m.value(QStringLiteral("id")).toString());
        if (old != merged.constEnd()) {
            m.insert(QStringLiteral("playCount"), old->value(QStringLiteral("playCount")));
            m.insert(QStringLiteral("lastPlayedAt"), old->value(QStringLiteral("lastPlayedAt")));
        } else {
            m.insert(QStringLiteral("playCount"), 0);
            m.insert(QStringLiteral("lastPlayedAt"), qint64(0));
        }
        kept.append(m);
    }
    m_items = kept;
    m_fetchedAt.insert(scope, QDateTime::currentMSecsSinceEpoch());
    m_dirty = true;
    emit historyChanged();
}

void PlaybackHistory::mergeItemUserData(const QString &serverUrl, const QString &accountId,
                                        const QString &itemId, int playCount,
                                        qint64 lastPlayedAt, double positionTicks, bool played)
{
    const QString scope = scopeOf(serverUrl, accountId);
    for (int i = 0; i < m_items.size(); ++i) {
        QVariantMap m = m_items.at(i).toMap();
        if (m.value(QStringLiteral("scope")).toString() != scope
            || m.value(QStringLiteral("id")).toString() != itemId)
            continue;
        m.insert(QStringLiteral("playCount"), playCount);
        m.insert(QStringLiteral("lastPlayedAt"), lastPlayedAt);
        if (positionTicks >= 0) {
            m.insert(QStringLiteral("positionTicks"), positionTicks);
            m.insert(QStringLiteral("played"), played);
        }
        m_items[i] = m;
        m_dirty = true;
        emit historyChanged();
        return;
    }
}

void PlaybackHistory::upsertItems(const QString &serverUrl, const QString &accountId,
                                  const QVariantList &items)
{
    if (items.isEmpty())
        return; // 拉取失败的空结果:不清既有(整体覆盖语义见 setItems)
    const QString scope = scopeOf(serverUrl, accountId);
    QHash<QString, int> indexById;
    int nextSeq = 1;
    for (int i = 0; i < m_items.size(); ++i) {
        const QVariantMap m = m_items.at(i).toMap();
        if (m.value(QStringLiteral("scope")).toString() != scope)
            continue;
        indexById.insert(m.value(QStringLiteral("id")).toString(), i);
        nextSeq = qMax(nextSeq, m.value(QStringLiteral("seq")).toInt() + 1);
    }
    for (const QVariant &v : items) {
        QVariantMap m = v.toMap();
        m.insert(QStringLiteral("scope"), scope);
        m.insert(QStringLiteral("serverUrl"), serverUrl);
        m.insert(QStringLiteral("accountId"), accountId);
        if (!hasPlayTrace(m))
            continue; // Resume 的"下一未看集"占位等无痕迹行不入库(见 hasPlayTrace)
        const auto it = indexById.constFind(m.value(QStringLiteral("id")).toString());
        if (it == indexById.constEnd()) {
            if (m.value(QStringLiteral("seq")).toInt() == 0)
                m.insert(QStringLiteral("seq"), nextSeq++);
            m_items.append(m);
            continue;
        }
        // 已存在:保持既有播放次数/上次播放时间/顺序(新值非 0 才覆盖)。
        const QVariantMap old = m_items.at(*it).toMap();
        for (const char *field : { "playCount", "lastPlayedAt", "seq" }) {
            const QString f = QLatin1String(field);
            if (m.value(f).toLongLong() == 0)
                m.insert(f, old.value(f));
        }
        m_items[*it] = m;
    }
    // 上限:超出按 (上次播放时间 desc, seq asc) 保留最新的若干条。
    QList<int> idx;
    for (int i = 0; i < m_items.size(); ++i) {
        if (m_items.at(i).toMap().value(QStringLiteral("scope")).toString() == scope)
            idx.append(i);
    }
    if (idx.size() > MoePlayer::kHistoryStoredPerScope) {
        std::stable_sort(idx.begin(), idx.end(), [this](int a, int b) {
            const QVariantMap x = m_items.at(a).toMap();
            const QVariantMap y = m_items.at(b).toMap();
            const qint64 xa = x.value(QStringLiteral("lastPlayedAt")).toLongLong();
            const qint64 ya = y.value(QStringLiteral("lastPlayedAt")).toLongLong();
            if (xa != ya)
                return xa > ya;
            return x.value(QStringLiteral("seq")).toInt() < y.value(QStringLiteral("seq")).toInt();
        });
        QList<int> drop = idx.mid(MoePlayer::kHistoryStoredPerScope);
        std::stable_sort(drop.begin(), drop.end(), std::greater<int>());
        for (int i : std::as_const(drop))
            m_items.removeAt(i);
    }
    m_dirty = true;
    emit historyChanged();
}

QVariantList PlaybackHistory::items(const QString &serverUrl, const QString &accountId) const
{
    const QString scope = scopeOf(serverUrl, accountId);
    QVariantList out;
    for (const QVariant &v : m_items) {
        const QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("scope")).toString() == scope)
            out.append(m);
    }
    std::stable_sort(out.begin(), out.end(), historyBefore);
    return out;
}

QVariantList PlaybackHistory::allItems() const
{
    // 全部账号的条目展平后按最近播放倒序(跨服聚合视图用),调用方可直接
    // 截断取前 N。
    QVariantList out;
    for (const QVariant &v : m_items)
        out.append(v.toMap());
    std::stable_sort(out.begin(), out.end(), historyBefore);
    return out;
}

qint64 PlaybackHistory::lastPlayedAt(const QString &serverUrl, const QString &accountId,
                                     const QString &itemId) const
{
    const QString scope = scopeOf(serverUrl, accountId);
    for (const QVariant &v : m_items) {
        const QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("scope")).toString() == scope
            && m.value(QStringLiteral("id")).toString() == itemId)
            return m.value(QStringLiteral("lastPlayedAt")).toLongLong();
    }
    return 0;
}

qint64 PlaybackHistory::fetchedAt(const QString &serverUrl, const QString &accountId) const
{
    return m_fetchedAt.value(scopeOf(serverUrl, accountId)).toLongLong();
}

void PlaybackHistory::removeScope(const QString &serverUrl, const QString &accountId)
{
    const QString scope = scopeOf(serverUrl, accountId);
    if (m_fetchedAt.remove(scope) == 0)
        return;
    QVariantList kept;
    for (const QVariant &v : std::as_const(m_items)) {
        if (v.toMap().value(QStringLiteral("scope")).toString() != scope)
            kept.append(v);
    }
    m_items = kept;
    m_dirty = true;
    emit historyChanged();
    save();
}

void PlaybackHistory::flush()
{
    save();
}

void PlaybackHistory::save()
{
    if (!m_dirty)
        return;
    QVariantMap root;
    root.insert(QStringLiteral("items"), m_items);
    root.insert(QStringLiteral("fetchedAt"), m_fetchedAt);
    if (m_persist.saveCache(kCacheName, root))
        m_dirty = false;
}
