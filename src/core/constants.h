#pragma once

#include <QByteArray>
#include <QCoreApplication>
#include <QString>

//! 应用级共享常量:网络超时/分页/协议换算等,跨文件统一取值。
//! 调参集中在此;QML 侧对应的布局/交互常量见 qml/theme/Constants.qml
//! (页面尺寸与阈值两侧各自定义,数值一致)。
namespace MoePlayer {

// 应用名(CMake project 注入):用于 QSettings 存储路径、UA/认证头客户端名、
// 单实例锁文件名与窗口标题。改动即变更配置存储路径,需评估迁移。
inline const QString kAppName = QStringLiteral(MOEPLAYER_NAME);
// 默认服务器地址(用户可覆盖):embyclient 默认值与 settingsstore 共用。
inline const QString kDefaultServerUrl = QStringLiteral("http://127.0.0.1:8096");
// 常规网络请求超时(ms)。
inline constexpr int kNetworkTimeoutMs = 10000;
// 播放地址 Range 探测超时(ms)。
inline constexpr int kProbeTimeoutMs = 5000;
// 分页上限(Emby 单页上限 200)。
inline constexpr int kMaxPageSize = 200;
// 首页聚合每库条目上限。
inline constexpr int kHomePerLibraryLimit = 20;
// 搜索返回条数上限。
inline constexpr int kSearchLimit = 40;
// 海报请求固定取图宽度(缓存键稳定,换 token 不清缓存)。
inline constexpr int kPosterMaxWidth = 320;
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

// QSettings 键:服务器地址(embyclient 与 settingsstore 共用)。
inline const QString kSettingsServerUrlKey = QStringLiteral("network/serverUrl");

// 统一 User-Agent:应用名/版本(Emby 取流与 API 请求共用,不用 Qt 默认 UA)。
inline QString userAgent()
{
    return kAppName + QLatin1Char('/') + QCoreApplication::applicationVersion();
}

} // namespace MoePlayer
