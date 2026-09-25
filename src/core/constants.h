#pragma once

#include <QByteArray>
#include <QCoreApplication>
#include <QString>

//! 应用级共享常量:网络超时/分页/协议换算等,跨文件统一取值。
//! 调参集中在此;QML 侧对应的布局/交互常量见 qml/theme/Constants.qml
//! (页面尺寸与阈值两侧各自定义,数值一致)。
namespace MoePlayer {

// 应用名(CMake project 注入):用于存储路径、UA/认证头客户端名、
// 单实例锁文件名与窗口标题。改动即变更配置存储路径,需评估迁移。
inline const QString kAppName = QStringLiteral(MOEPLAYER_NAME);
// 桌面集成标识(反向域名,CMake 注入):desktop 文件名、图标名与 Wayland
// app_id 统一取值,与 kAppName 解耦。
inline const QString kAppId = QStringLiteral(MOEPLAYER_APP_ID);
// 常规 API 请求超时(ms)。
inline constexpr int kNetworkTimeoutMs = 20000;
// 图片回源超时(ms,停摆超时:零字节持续该时长才掐断)
inline constexpr int kImageTimeoutMs = 30000;
// 分页上限(Emby 单页上限 200)。
inline constexpr int kMaxPageSize = 200;
// 首页聚合每库条目上限。
inline constexpr int kHomePerLibraryLimit = 60;
// 首页 hero 服务器建议条数(每账号;全部账号展平后由 QML 再截断)。
inline constexpr int kHomeSuggestLimit = 10;
// 播放历史单页条数(每账号):Emby 单页上限 200(kMaxPageSize),取满即一次请求
// 覆盖最多 200 条。列表端点不返回时间戳,条数多少不影响请求数(整页一次拿回),
// 故不再用"60 窗口"限制可及范围。
inline constexpr int kHistoryFetchLimit = 200;
// 播放历史逐页回补的最大页数(每账号):首页不带 Filters(含"在看"),其后每页带
// Filters=IsPlayed 取更早的已看条目,页数上限使单账号最多回补
// kHistoryFetchLimit * kHistoryMaxHistoryPages 条(与 kHistoryStoredPerScope 同量级)。
inline constexpr int kHistoryMaxHistoryPages = 5;
// 播放历史明细补全条数(每账号):列表端点不返回播放次数与上次播放时间,
// 需逐条查单条端点。只对"新增/进度或已看有变化/尚无时间戳"的条目补(见
// AccountManager::onHistoryListReceived),未变且有时间的条目不发请求,稳态下
// 为 0 条。60 只覆盖最新的一小段:更早的条目没有精确时间,按服务器顺序归入
// "更早"(每条 1 次请求,不宜按 200 条的页宽放大)。
inline constexpr int kHistoryDetailLimit = 60;
// 明细补全的并发请求数。Qt 对同一主机的 HTTP/1.1 连接数默认 6,且公开可配:
// QHttp1Configuration::setNumberOfConnectionsPerHost(1..255)+ QNetworkRequest::
// setHttp1Configuration(),须在该主机首个请求之前设置;HTTP/2 下恒为 1 条连接
// 多路复用,不受该值约束。此处取 6 即默认值:历史明细走 EmbyClient 的后台专用
// 连接池(独立 QNetworkAccessManager,与浏览/首页的 6 条互不挤占),6 即该池
// 上限,再多只会排在 Qt 队列里白耗传输超时。
inline constexpr int kHistoryDetailConcurrency = 6;
// 明细合并后的落盘防抖(ms):逐条写文件过密,合并结果延迟合并写一次。
inline constexpr int kHistoryFlushDebounceMs = 1000;
// 继续观看列表拉取条数(每账号):服务器按上次播放倒序,含"有进度"与
// "下一未看集"两类条目,详情页据此定位续播目标。
inline constexpr int kResumeLimit = 60;
// 本地播放历史每账号条目上限:详情页逐季回写会持续增长,超出按
// (上次播放时间, 服务器顺序)保留最新的若干条。
inline constexpr int kHistoryStoredPerScope = 1000;
// 播放历史拉取延迟(ms):启动即拉会与首页聚合抢同一主机的连接配额。
inline constexpr int kHistoryStartupDelayMs = 4000;
// 搜索返回条数上限。
inline constexpr int kSearchLimit = 40;
// 图片请求固定厚档(服务器端缩放并缓存缩略图;与显示尺寸解耦,URL 恒定
// 窗口缩放不重拉;客户端 sourceSize 负责显示缩放)。海报/缩略图 512,
// 背景(Backdrop)默认 1920(FHD 窗 1:1);档位可配(backdropMaxWidth,
// 含原图档),此常量是无配置时的回退值。原图档注意:CrossfadeImage 换图期
// 双帧并存,4K 原图峰值 ~66MB。
inline constexpr int kPosterMaxWidth = 512;
inline constexpr int kBackdropMaxWidth = 1920;
// Emby 时间单位:100ns ticks 换算秒。
inline constexpr double kTicksPerSecond = 1e7;
// 列表请求 Fields:已看/进度/收藏/未看集数/评分/年份随列表返回,零额外请求。
inline const QString kListFields = QStringLiteral(
    "PrimaryImageAspectRatio,ProductionYear,CommunityRating,RunTimeTicks,UserData");

// 认证请求头名。
inline const QByteArray kHeaderAuth = QByteArrayLiteral("X-Emby-Authorization");
inline const QByteArray kHeaderToken = QByteArrayLiteral("X-Emby-Token");
inline const QByteArray kHeaderUserAgent = QByteArrayLiteral("User-Agent");

// Emby URL 参数:流地址附带 api_key,mpv 拉流无需自定义请求头。
inline const QString kApiKeyParam = QStringLiteral("api_key");


// 统一 User-Agent:应用名/版本(Emby 取流与 API 请求共用,不用 Qt 默认 UA)。
inline QString userAgent()
{
    return kAppName + QLatin1Char('/') + QCoreApplication::applicationVersion();
}

} // namespace MoePlayer
