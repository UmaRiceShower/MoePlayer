#pragma once

#include <QObject>
#include <QSettings>
#include <QVariantList>
#include <QVariantMap>

#include "core/persistmap.h"

//! 本地观看记录(跨服务器聚合的基础设施)。
//! 每条记录带 scope(服务器+账号)与跨服匹配所需字段(type/seriesName/
//! 季集号),后续"同一剧集多服观看聚合"在此之上做(按匹配键合并、取最大
//! 进度);当前用途:详情页定位"上次播放的季/集"(服务器 NextUp 不可用时
//! 的回退,不依赖网络)。
//! 存储:CacheLocation/watch-history.json(独立于配置),版本头由 PersistMap 管。
class WatchHistory : public QObject
{
    Q_OBJECT

public:
    explicit WatchHistory(QObject *parent = nullptr);

    // 记录一次播放发起(同 scope+itemId 覆盖更新,lastPlayedAt 刷新)。
    Q_INVOKABLE void record(const QString &serverUrl, const QString &accountId,
                            const QString &itemId, const QString &type,
                            const QString &seriesId, const QString &seriesName,
                            int seasonNo, int episodeNo,
                            double positionTicks, bool played);
    // 该剧最近播放的集(scope + seriesId 过滤,取 lastPlayedAt 最大);
    // 无记录返回空 map(调用方回退第一季)。
    Q_INVOKABLE QVariantMap lastEpisode(const QString &serverUrl, const QString &accountId,
                                        const QString &seriesId) const;

private:
    void save();

    QSettings m_settings;
    PersistMap m_persist;
    QVariantList m_records;
};
