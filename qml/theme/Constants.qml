pragma Singleton
import QtQuick

//! 应用级布局/交互/协议常量:跨文件统一取值,调参集中在此。
//! 视觉颜色见 Theme.qml;动画时长/缓动见本文件与 Theme 配合使用。
//! 协议类常量(分页/ticks 换算)与 C++ src/core/constants.h 数值一致。
QtObject {
    // ---- 卡片与网格(媒体库/搜索/分集共用) ----
    readonly property int cardW: 168
    readonly property int cardH: 252
    readonly property int cellW: 176
    readonly property int cellH: 260

    // ---- 详情页(Hero + 右侧选集条) ----
    readonly property int detailHeroH: 400        // Hero 内容区高度(海报/文字/按钮;桌面端随窗口缩放)
    readonly property int detailTextRevealMs: 3000 // hero 文字滑动揭示动画时长
    readonly property int detailBackdropH: 560    // Hero 背景图总高 = 内容区 + 向下延伸 160(延伸区
                                                  // 经渐变遮罩融入正文底色;只延伸背景,不动内容布局)
    readonly property int detailPosterW: 200      // Hero 海报宽(2:3 竖版)
    readonly property int detailPosterH: 300      // Hero 海报高
    readonly property int detailSidebarW: 260     // 右侧选集条宽
    readonly property int detailEpisodeRowH: 165   // 选集条行高(含海报缩略图)
    readonly property int detailEpisodeRowMargin: 15
    readonly property real detailHeroFadeBand: 0.2
    readonly property real detailEpisodeHoverScale: 1.06 // 选集条行 hover 放大
    readonly property int detailBodyMaxW: 1000    // 正文区最大宽(窗口过宽时不拉成一条线)
    readonly property int detailCardW: 112        // 相似推荐/演职人员头像卡宽
    readonly property int detailCardH: 168        // 相似推荐海报卡高

    // ---- 首页行(堆叠轮盘) ----
    readonly property int rowCardW: 112
    readonly property int rowCardH: 168
    readonly property int rowLibraryW: 124
    readonly property int rowHeight: 172
    readonly property int rowTitleH: 24
    readonly property int rowOverlap: 44        // 行间负间距(重叠量)
    readonly property int rowSpacing: 12        // 条目卡片间距
    readonly property int rowCellStep: rowCardW + rowSpacing // 一格宽
    readonly property int rowLeftMargin: 24     // 行内容左边距
    readonly property int rowStepFallback: rowTitleH + rowHeight - rowOverlap // 行距兜底

    // ---- 分页 ----
    readonly property int pageSize: 200         // Emby 单页上限
    readonly property int homePerLibraryLimit: 20

    // ---- 交互阈值/防抖 ----
    readonly property int dragThresholdCard: 30
    readonly property int dragThresholdBlank: 40

    // ---- 服务器管理卡(ServerManager) ----
    readonly property int serverCardW: 280
    readonly property int serverCardH: 150
    readonly property int serverIconSize: 52
    readonly property int serverGridSpacing: 16
    readonly property real serverHoverScale: 1.12
    readonly property int serverMoveMs: 320
    readonly property int serverDragMs: 480
    readonly property int serverFadeMs: 320
    readonly property int searchDebounceMs: 300
    readonly property int episodePushDebounceMs: 500
    readonly property int wheelLogWindowMs: 350 // 滚轮速度记账窗口
    readonly property real scrollVelocityInitial: 800
    readonly property int scrollVelocityMin: 300
    readonly property int scrollVelocityMax: 3200

    // ---- 滚动动画 ----
    readonly property int animMinMs: 30
    readonly property int animMaxMs: 250
    readonly property int pullOverrun: 24       // 到头拉动画越界量
    readonly property int pullOutMs: 110
    readonly property int pullBackMs: 240
    readonly property real pullOvershoot: 1.4
    readonly property real bounceOvershoot: 1.6   // 横向单格滚动回弹
    readonly property real bigBounceOvershoot: 2.0 // 大幅跨行回弹

    // ---- 首页堆叠行(缩放/透明度随距视口中心距离) ----
    readonly property real rowMinScale: 0.55      // 最远行最小缩放
    readonly property real rowScaleFactor: 0.14   // 缩放衰减斜率
    readonly property real rowMinOpacity: 0.3     // 最远行最小透明度
    readonly property real rowOpacityFactor: 0.7  // 透明度衰减斜率
    readonly property real rowCenterBand: 60      // 距中心该距离内全尺寸/全透明
    readonly property real rowZNear: 90           // z=3(最近层)距离阈值
    readonly property real rowZMid: 220           // z=2(中间层)距离阈值

    // ---- 播放回传间隔 / 协议换算 ----
    readonly property int progressReportMs: 10000
    readonly property int pingIntervalMs: 600000
    readonly property real ticksPerSecond: 1e7 // 100ns ticks → 秒
}
