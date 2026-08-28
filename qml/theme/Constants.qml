pragma Singleton
import QtQuick

//! 应用级布局/交互/协议常量:按使用文件分组,调参集中在此。
//! 顶部的全局节为多文件共用;各文件节的值可引用全局节(如 gridCardW 引用
//! cellGap)。视觉颜色见 Theme.qml;协议类常量(分页/ticks 换算)与 C++
//! src/core/constants.h 数值一致。
QtObject {

    // ===================== 全局(多文件共用) =====================

    // ---- 萌系粉白甜系配色 ----
    readonly property color moePink: Qt.rgba(1.0, 0.62, 0.74, 1.0)
    readonly property color moePinkLight: Qt.rgba(1.0, 0.82, 0.88, 1.0)
    readonly property color moePinkDark: Qt.rgba(0.86, 0.45, 0.63, 1.0)
    readonly property color moePinkGlow: Qt.rgba(1.0, 0.62, 0.74, 0.35)
    readonly property color moePinkText: Qt.rgba(1.0, 0.92, 0.95, 1.0)
    readonly property color moeGold: Qt.rgba(1.0, 0.78, 0.42, 1.0)

    // ---- 动画时长(Detail/PosterCard 共用) ----
    readonly property int animMinMs: 30
    readonly property int animMaxMs: 250

    // ---- 网格计算(Library/SearchOverlay 共用) ----
    // 弹性列数:卡宽在 [minW, maxW] 区间伸缩,窗口 resize 时列数自动增减、
    // 整行铺满(等价 CSS Grid repeat(auto-fill, minmax(minW, 1fr)));delegate
    // 卡宽由 gridCardW 给出。2:3 竖版海报。
    readonly property int cellGap: 24             // 卡间距(卡 + gap = cell)
    readonly property real cellAspect: 2 / 3      // 卡宽高比
    // 弹性卡宽(GridView 无 gap 语义:cell 宽 = 卡宽 + cellGap,delegate 取卡宽,
    // cell 内右/下缘留 gap → 卡间距 = cellGap、整行铺满无空白)。按"卡宽+gap"
    // 求满行列数,总宽减去 n 个 gap 后均分到各列;结果不足 minW 时按 minW
    // 减列重算(卡放大,可略超 maxW)。
    function gridCardW(availW, minW, maxW) {
        const gap = cellGap
        let n = Math.max(1, Math.floor((availW + gap) / (maxW + gap)))
        let w = (availW - n * gap) / n
        if (w < minW) {
            n = Math.max(1, Math.floor((availW + gap) / (minW + gap)))
            w = (availW - n * gap) / n
        }
        return w
    }
    function gridCardH(w) {
        return Math.round(w / cellAspect)
    }
    // cell = 卡 + gap。GridView 内部列数 = int((width - cellWidth)/cellWidth
    // + 1)(C++ 截断):cellWidth = avail/n 数学整除,但 double 除法舍入可落
    // 5.9999… → 截断少一列 → 右侧空一整列(网格贴左)。cell 宽下偏 1e-6
    // 使 int(width/cellWidth) 恰为 n(右空 < n×1e-6 px,不可见)。
    function gridCellW(availW, minW, maxW) {
        return gridCardW(availW, minW, maxW) + cellGap - 1e-6
    }
    function gridCellH(w) {
        return gridCardH(w) + cellGap - 1e-6
    }

    // ===================== Home.qml =====================

    // ---- 顶部导航 ----
    readonly property int homeNavH: 48                    // 导航高
    readonly property int homeNavTitlePx: 22              // 导航标题字号
    readonly property int homeNavBtnSize: 42              // 圆形按钮尺寸
    readonly property int homeNavMarginL: 20              // 标题左边距
    readonly property int homeNavMarginR: 16              // 按钮组右边距
    readonly property int homeNavSpacing: 12              // 按钮间距

    // ---- Hero 轮播 ----
    readonly property real homeHeroCardH: 0.86            // 卡高占 hero 区比例
    readonly property real homeHeroCardAspect: 16.0 / 9.0 // 卡宽高比
    readonly property real homeHeroCardWCap: 0.50         // 卡宽上限 = 窗口宽 × 比例
    // 宽度预算:使中心卡宽恰达卡宽上限对应的 hero 高(≈0.37×窗口宽);
    // 窄窗时 hero 高收缩、卡片保持满带宽,宽窗由高度预算/上限决定。
    readonly property real homeHeroWidthRatio: homeHeroCardWCap / homeHeroCardAspect / homeHeroCardH
    readonly property real homeHeroPathStartX: 0.12       // 路径左弧 x 比例
    readonly property real homeHeroPathCenterX: 0.5       // 路径中弧 x 比例
    readonly property real homeHeroPathEndX: 0.88         // 路径右弧 x 比例
    readonly property real homeHeroSideScale: 0.72        // 侧卡缩放
    readonly property real homeHeroOffPathScale: 0.78     // 未入路径兜底缩放
    readonly property int homeHeroRadius: 16              // 卡圆角
    readonly property int homeHeroDotsGap: 12             // 圆点距卡底间隙
    readonly property int homeHeroDotSize: 7              // 圆点直径
    readonly property int homeHeroDotSizeSel: 14          // 选中圆点宽
    readonly property int homeHeroDotSpacing: 8           // 圆点间距
    readonly property int homeHeroTimerMs: 5000           // 自动轮播间隔
    readonly property int homeHeroTitlePx: 25             // 卡右下标题字号
    readonly property int homeHeroYearPx: 16              // 卡右下年份字号

    // ---- 媒体库节 ----
    readonly property int homeMediaCardW: 260             // 库卡宽
    readonly property int homeMediaCardH: 150             // 库卡高
    readonly property int homeMediaCardRadius: 12         // 库卡圆角
    readonly property int homeMediaTitlePx: 18            // 节标题字号
    readonly property real homeMediaGradH: 44             // 卡底渐变压暗高
    readonly property int homeMediaTextMargin: 10         // 库名左右留白
    readonly property int homeMediaTextBottom: 8          // 库名底边距
    readonly property int homeMediaTextPx: 13             // 库名字号
    readonly property int homeMediaBottomPad: 12          // 节底部留白(首行标题上间距)

    // ---- 库行 ----
    readonly property int homeRowTitlePx: 16              // 行标题字号
    readonly property int homeRowTitlePad: 12             // 标题与「查看全部」间距
    readonly property int homeSeeAllPx: 13                // 「查看全部」字号
    readonly property int homeRowGap: 6                   // 行间间距
    readonly property int homeRowTitleGap: 4              // 标题与条目行间距
    readonly property int homeRowHoverPad: 16             // 条目行 hover 垂直溢出缓冲

    // ---- 库行卡片尺寸 ----
    readonly property int rowHeight: 230                  // 海报卡高
    readonly property int rowCardW: Math.round(rowHeight * 2 / 3) // 条目海报卡宽(2:3)
    readonly property int rowTitleH: 24                   // 行标题行高
    readonly property int rowSpacing: 12                  // 条目卡间距
    readonly property int rowLeftMargin: 24               // 行内容左边距

    readonly property int homePerLibraryLimit: 20         // 每库首页拉取条数

    // ===================== Detail.qml =====================

    // ---- Hero 文字揭示/布局 ----
    readonly property int detailTextRevealMs: 1000 // hero 文字滑动揭示动画时长
    readonly property int detailPosterW: 200      // Hero 海报宽(2:3 竖版)
    readonly property int detailPosterH: 300      // Hero 海报高
    readonly property int detailSidebarW: 260     // 右侧选集条宽
    readonly property int detailEpisodeRowH: 165   // 选集条行高(含海报缩略图)
    readonly property int detailEpisodeRowMargin: 15
    readonly property real detailHeroFadeBand: 0.2
    readonly property real detailEpisodeHoverScale: 1.06 // 选集条行 hover 放大
    // 正文区块(演职/媒体信息/相似推荐)靠左边距;区块宽 = 内容区 - 2×边距。
    readonly property int detailSectionMargin: 24
    readonly property int detailCardW: 112        // 相似推荐/演职人员头像卡宽
    readonly property int detailCardH: 168        // 相似推荐海报卡高

    // ---- 详情/播放 ----
    readonly property real ticksPerSecond: 1e7    // 100ns ticks → 秒
    readonly property int episodePushDebounceMs: 500 // 切集防抖

    // ===================== ServerManager.qml =====================

    readonly property int serverCardW: 280
    readonly property int serverCardH: 150
    readonly property int serverIconSize: 52
    readonly property int serverGridSpacing: 16
    readonly property real serverHoverScale: 1.12
    readonly property int serverMoveMs: 320
    readonly property int serverDragMs: 480
    readonly property int serverFadeMs: 320

    // ===================== Library.qml =====================

    readonly property int cellMinW: 186                  // 网格卡宽下限
    readonly property int cellMaxW: 206                  // 网格卡宽上限
    readonly property int searchDebounceMs: 300          // 库内搜索防抖
    readonly property int pageSize: 200                  // Emby 单页上限

    // ===================== SearchOverlay.qml =====================

    readonly property int searchCellMinW: 156            // 搜索网格卡宽下限(比库网格更小)
    readonly property int searchCellMaxW: 172            // 搜索网格卡宽上限
    readonly property int searchPageSize: 40             // 搜索每页条数(与 C++ kSearchLimit 一致)
}
