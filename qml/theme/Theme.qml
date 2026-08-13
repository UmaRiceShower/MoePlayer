pragma Singleton
import QtQuick

//! 全局视觉令牌:颜色统一在此定义,页面不直接写色值。
QtObject {
    // 基础色
    readonly property color bg: "#0d1117"
    readonly property color surface: "#161b22"
    readonly property color accent: "#00a4dc"
    readonly property color textPrimary: "#e6edf3"
    readonly property color textMuted: "#8b949e"

    // 状态色(语义固定,不随海报色;深色主题下调饱和 15% 融入整体)
    readonly property color danger: "#d95d56"     // 错误/失败文字与边框
    readonly property color success: "#369748"    // 已看/成功
    readonly property color info: "#2e72db"       // 未看集数等信息提示
    readonly property color rating: "#f0cb4b"     // 评分星标
    readonly property color favorite: "#ed81b9"   // 收藏
    readonly property color invalidBg: "#4a2226"  // 失效账号红底
    readonly property color textSelected: "#dddddd" // 强调底上的次级文字

    // 半透明底(卡片角标/快捷按钮)
    readonly property color overlayBg: "#000000aa"
    readonly property color badgeBg: Qt.rgba(0, 0, 0, 0.6)
}
