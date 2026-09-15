pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import MoePlayer.Core

// 导航折角图标(‹ › ⌃):自制 SVG,原生渲染无锯齿(Shape 路径位图化
// 有阶梯、文本字形油墨不按几何居中,均弃用)。白/暗双变体按主题切换;
// onAccent(压实心 accent 底)恒用白变体。
Image {
    id: glyph
    // 0=‹ 1=› 2=⌃(上)。
    property int dir: 0
    property bool onAccent: false
    width: 15
    height: 15
    source: "qrc:/icons/" + (onAccent ? "" : (ThemeStore.isLight ? "dark/" : ""))
            + (dir === 0 ? "chevron-left" : dir === 1 ? "chevron-right" : "chevron-up") + ".svg"
    fillMode: Image.PreserveAspectFit
    smooth: true
    // SVG 按显示尺寸×DPR 栅格化:避免大图降采样把细描边摊灰。
    sourceSize.width: Math.max(1, Math.round(width * Screen.devicePixelRatio))
    sourceSize.height: Math.max(1, Math.round(height * Screen.devicePixelRatio))
}
