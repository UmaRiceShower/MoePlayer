#pragma once

#include <QObject>
#include <QSettings>

#include "core/apppaths.h"
#include "core/constants.h"
#include <QVariantList>
#include <QVariantMap>

#include "core/persistmap.h"

// 是否有播放痕迹:列表端点(SortBy=DatePlayed)会带回从未播放过的条目(实测 0 播放
// 账号也能拉到整页无日期的行),Resume 里的"下一未看集"占位同样如此。入库与
// 播放历史明细补全(AccountManager)共用同一判据。
bool hasPlayTrace(const QVariantMap &item);

//! 播放历史本地存储(跨服务器聚合的基础设施)。
//! 服务器不提供逐次播放会话记录:列表端点(/Users/{id}/Items,
//! SortBy=DatePlayed)只给"最近播放"的顺序与当前状态,真实播放次数与
//! 上次播放时间需逐条查单条端点(/Users/{id}/Items/{itemId})补全。
//! 本类按 scope(serverUrl|accountId)归属两类信息,条目字段含跨服务器
//! 合并所需的类型/剧名/季集号,后续"同一剧集多服观看聚合"在此之上做。
//! 存储:CacheLocation/playback-history.json,版本头由 PersistMap 管。
class PlaybackHistory : public QObject
{
    Q_OBJECT

public:
    explicit PlaybackHistory(QObject *parent = nullptr);

    // 覆盖某 scope 的条目列表(列表端点拉取完成时调用;条目自带服务器给出的
    // 顺序 seq)。旧条目已补全的播放次数/上次播放时间按条目 id 保留。
    Q_INVOKABLE void setItems(const QString &serverUrl, const QString &accountId,
                              const QVariantList &items);
    // 单条端点补全:更新某条目的播放次数/上次播放时间/进度(条目不在该 scope
    // 时忽略)。positionTicks < 0 表示该项数据未知,保持原值。
    Q_INVOKABLE void mergeItemUserData(const QString &serverUrl, const QString &accountId,
                                       const QString &itemId, int playCount,
                                       qint64 lastPlayedAt, double positionTicks, bool played);
    // 按需补写条目(详情页进入时的继续观看列表与逐季分集):按 id 合并,已存在的
    // 条目保留其播放次数/上次播放时间(新值非 0 才覆盖),新条目追加;空列表视为
    // 无数据、不清既有(与 setItems 的整体覆盖语义区分)。超出上限按
    // (上次播放时间, 服务器顺序)保留最新若干条。
    Q_INVOKABLE void upsertItems(const QString &serverUrl, const QString &accountId,
                                 const QVariantList &items);
    // 该 scope 的条目:上次播放时间已知者按时间倒序在前,未知者按服务器给的
    // 顺序 seq 排在其后。
    Q_INVOKABLE QVariantList items(const QString &serverUrl, const QString &accountId) const;
    // 全部账号的条目展平并按最近播放倒序(跨服聚合视图),调用方可直接截断。
    Q_INVOKABLE QVariantList allItems() const;
    // 某条目的上次播放时间(ms epoch;0 = 未知)。按最近播放排序用。
    Q_INVOKABLE qint64 lastPlayedAt(const QString &serverUrl, const QString &accountId,
                                    const QString &itemId) const;
    // 该 scope 上次拉取完成时间(ms epoch;0 = 从未拉取)。
    Q_INVOKABLE qint64 fetchedAt(const QString &serverUrl, const QString &accountId) const;
    // 落盘:内存变更后由调用方在一个账号的批次结束时调一次,避免逐条写文件。
    Q_INVOKABLE void flush();
    // 删除某账号的历史(账号被删除时调用,立即落盘)。
    void removeScope(const QString &serverUrl, const QString &accountId);

signals:
    // 条目内容变化(列表到位或明细补全),UI 据此刷新。
    void historyChanged();

private:
    void save();

    // 存储路径经 AppPaths 统一分配(便携模式重定向,详见 apppaths.h)。
    QSettings m_settings{AppPaths::settingsFilePath(), AppPaths::settingsFormat()};
    PersistMap m_persist;
    // 条目(每条含 scope/serverUrl/accountId,便于展平与跨服去重)。
    QVariantList m_items;
    // scope -> 上次拉取完成时间(ms epoch)。
    QVariantMap m_fetchedAt;
    bool m_dirty = false;
};
