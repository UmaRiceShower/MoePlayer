pragma Singleton
import QtQuick
import MoePlayer.Core

//! 全局视觉令牌:值来自 ThemeStore(预设 + config.toml 覆盖),页面不直接写色值。
//! 强调色系随预设变化;状态色语义固定(深色底下调饱和 15% 融入整体)。
QtObject {
    // 基础色(随预设)
    readonly property color bg: ThemeStore.bg
    readonly property color surface: ThemeStore.surface
    readonly property color textPrimary: ThemeStore.textPrimary
    readonly property color textMuted: ThemeStore.textMuted

    // 强调色系(随预设;accent 用于小面积描边/悬停/选中)
    readonly property color accent: ThemeStore.accent
    readonly property color accentDeep: ThemeStore.accentDeep   // 深强调:按压/深色描边
    readonly property color accentInk: ThemeStore.accentInk     // 强调底上的文字
    // 实心强调控件 hover 填充:朝 ink 的反方向走——暗色系(深 ink)变浅
    // (accentSoft),亮色系(白 ink)变深(accentDeep)。反着走会让 hover 态
    // 文字不可读(实踩:ink 压 accentDeep ≈2.4:1)。
    readonly property color accentHover: ThemeStore.isLight ? ThemeStore.accentDeep
                                                            : ThemeStore.accentSoft
    readonly property color accentWarm: ThemeStore.accentWarm   // 次级暖强调(徽标/收藏点缀)
    // 强调色作**小字**用:亮色系下鲜艳 accent 对浅底仅 3.6~4.3:1(< 4.5 小字口径),
    // 取 accentDeep(≈5.5:1);暗色系里 accent 对深底本就达标,保持鲜艳值。
    // accent 本体的口径:作填充/描边/大字 ≥3:1(白字压其上 ≥3:1)。
    readonly property color accentText: ThemeStore.isLight ? accentDeep : accent

    // 状态色(语义固定;亮色系加深一档:#369748/#d95d56 对浅底小字仅 ~3.4:1,
    // 低于次文字 4.5:1 口径;加深后 ≥4.9:1。rating/favorite 只用于深底英雄区
    // 与海报图上,不随主题)
    readonly property color danger: ThemeStore.isLight ? "#B8423C" : "#d95d56"     // 错误/失败文字与边框
    readonly property color success: ThemeStore.isLight ? "#2A7A3C" : "#369748"    // 已看/成功
    readonly property color rating: "#f0cb4b"     // 评分星标
    readonly property color favorite: "#ed81b9"   // 收藏

    // 深色浮层/玻璃/工具栏底:由预设底色微调而来(随预设走),页面不再散写字面量。
    // 亮色系配色下悬停态要掺黑(掺白在白底上看不见)。
    readonly property color scrim: ThemeStore.isLight ? Qt.tint(bg, Qt.rgba(0, 0, 0, 0.050))
                                                      : Qt.tint(bg, Qt.rgba(1, 1, 1, 0.055))
    readonly property color scrimSoft: ThemeStore.isLight ? Qt.tint(bg, Qt.rgba(0, 0, 0, 0.028))
                                                          : Qt.tint(bg, Qt.rgba(1, 1, 1, 0.030))
    // 发丝线/弱描边(表面上的分割线、边框):亮底下掺黑,暗底下掺白
    readonly property color borderSoft: ThemeStore.isLight ? Qt.rgba(0, 0, 0, 0.12)
                                                           : Qt.rgba(1, 1, 1, 0.10)
    // 玻璃 rim 描边:暗底下白边反光;亮底下白边不可见,改压深一档保持边缘定义
    readonly property color glassRim: ThemeStore.isLight ? Qt.rgba(0, 0, 0, 0.10)
                                                         : Qt.rgba(1, 1, 1, 0.28)
    readonly property color scrimDeep: Qt.tint(bg, Qt.rgba(0, 0, 0, 0.28))
    // 强调色柔化面:悬停行/药丸/面包屑(随预设强调色)。
    readonly property color tint: Qt.tint(bg, Qt.rgba(accent.r, accent.g, accent.b, 0.16))
    readonly property color tintStrong: Qt.tint(bg, Qt.rgba(accent.r, accent.g, accent.b, 0.26))
    readonly property color accentMuted: Qt.tint(accent, Qt.rgba(0, 0, 0, 0.30))
    // 暖色角标底(评分等,随预设暖强调色)。
    readonly property color badgeScrim: Qt.tint("#000000", Qt.rgba(accentWarm.r, accentWarm.g, accentWarm.b, 0.12))
    readonly property color dangerPressed: Qt.tint(danger, Qt.rgba(0, 0, 0, 0.18))

    // 半透明底(卡片角标/快捷按钮)
    readonly property color overlayBg: "#000000aa"
    // 角标/图标上的纯白文字(显式覆盖场景)。
    readonly property color textOnBadge: "#ffffff"
}
