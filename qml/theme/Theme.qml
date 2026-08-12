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

    // 状态色
    readonly property color danger: "#e5534b"     // 错误/失败文字与边框
    readonly property color success: "#2ea043"    // 已看/成功
    readonly property color info: "#1f6feb"       // 未看集数等信息提示
    readonly property color rating: "#ffd33d"     // 评分星标
    readonly property color favorite: "#f778ba"   // 收藏
    readonly property color invalidBg: "#4a2226"  // 失效账号红底
    readonly property color textSelected: "#dddddd" // 强调底上的次级文字

    // 半透明底(卡片角标/快捷按钮)
    readonly property color overlayBg: "#000000aa"
    readonly property color badgeBg: Qt.rgba(0, 0, 0, 0.6)
}
