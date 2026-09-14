import QtQuick
import MoePlayer.Core

//! 共享模糊源:多个 FrostedGlass 盖在同一片内容上时(首页固定导航的四个按钮),
//! 由它统一抓一份纹理,各玻璃按自己的采样区取样 —— 抓取次数从 N 次/帧降到 1 次/帧。
//! 每次抓取都要遍历整棵源子树(实测这是滚动场景里的主要成本),所以共享的收益是
//! 数量级的。
//!
//! 更新策略:`live:false` + 两层驱动 —— ① 滚动驱动:调用方挂源内容的
//! contentYChanged → `refresh()`,滚动时逐帧同步(玻璃下方的内容不会滞后);
//! ② 定时兜底:`scheduleUpdate()`(默认 33ms ≈ 30fps)兜住非滚动的内容变化。
//! 纹理按**整片源**抓取、采样区固定,刷新频率只影响滞后、不会错位
//! (跟随控件移动的分区采样才必须每帧同步)。
Item {
    id: root

    // 要抓取的内容(通常是一个可滚动列表)。为 null 时什么都不做。
    property Item sourceItem: null
    // 纹理更新间隔(ms):33ms ≈ 30fps,兜住非滚动的内容变化(图片异步装载等)。
    // 滚动由调用方挂 contentYChanged → refresh() 逐帧驱动,不受此值影响。
    property int updateIntervalMs: 33

    // 0 尺寸:本组件不绘制任何东西,只持有纹理。
    width: 0
    height: 0

    readonly property ShaderEffectSource sharedTexture: ShaderEffectSource {
        sourceItem: root.sourceItem
        sourceRect: root.sourceItem
                    ? Qt.rect(0, 0, root.sourceItem.width, root.sourceItem.height)
                    : Qt.rect(0, 0, 0, 0)
        // 逻辑尺寸(不乘 DPR):与 shader 的 u_texSize(逻辑像素)严格一致。
        textureSize: root.sourceItem
                     ? Qt.size(Math.max(1, Math.round(root.sourceItem.width)),
                                Math.max(1, Math.round(root.sourceItem.height)))
                     : Qt.size(1, 1)
        live: false
        hideSource: false
        onSourceRectChanged: refresh()
    }

    function refresh() { sharedTexture.scheduleUpdate() }

    Timer {
        interval: root.updateIntervalMs
        repeat: true
        running: root.sourceItem !== null
        onTriggered: root.sharedTexture.scheduleUpdate()
    }

    onWidthChanged: refresh()
    onHeightChanged: refresh()
    Component.onCompleted: refresh()
}
