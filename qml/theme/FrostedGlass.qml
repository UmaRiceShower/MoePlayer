import QtQuick
import QtQuick.Window
import QtQuick.Effects
import MoePlayer.Core

//! 通用磨砂玻璃组件(iOS 液体玻璃):对控件下方场景做实时折射+模糊,叠加
//! 半透明亮色底、亮描边与外侧投影,营造玻璃的立体感/浮起感。
//!
//! 通用性:调用方只需给 blurSource(要模糊的下方内容 Item),坐标定位与
//! 滚动/缩放跟随全自动——内部用 FrameAnimation 每帧重算采样区(mapToItem),
//! 无需关心控件在普通布局还是滚动 Flickable 内、内容滚动与否。
//! - blurSource 默认取窗口内容根;内联控件须传「不含自身的兄弟内容」避免自采样。
//! - 控件级(按钮/摘要行/卡片)用低 blurRadius/小 thickness;大浮层加大半径。
Rectangle {
    id: root

    // ---- 背景采样 ----
    // 要模糊的下方内容 Item;默认取窗口内容根。
    property var blurSource: Window.window ? Window.window.contentItem : null
    // 磨砂模糊半径(px,shader 内 box blur 采样步长)。控件级 4~8;大浮层 8~16。
    // 仅软化磨砂底色,不影响折射清晰度。
    property real blurRadius: 6
    // 采样扩边(px):采样区比玻璃矩形大四周边距,边缘折射越界时仍能采到
    // 真实背景(否则越界钳到边缘纹素→边缘糊带)。应 ≥ 最大折射偏移量。
    property real sampleMargin: 96
    // ---- 玻璃质感 ----
    // 玻璃底色(半透明亮色)。黑底下降低不透明度(0.22)减灰感——透出背景。
    property color glassColor: Qt.rgba(0.10, 0.11, 0.15, 0.22)
    // 饱和度提升(黑底/模糊去饱和时补回色彩):0=不变,>0 增强。
    property real saturation: 0.4
    // hover 提亮(0=无):提亮折射内容与边缘光,而非盖白膜(白膜黑底发灰)。
    property real hoverGlow: 0.0
    // 描边色(比玻璃更亮,营造边缘反光)。
    property color borderColor: Qt.rgba(1, 1, 1, 0.28)
    // ---- 边缘折射(液体玻璃凸透镜,SDF 法线 + Snell) ----
    // 玻璃边缘隆起厚度(px):≥短边一半时整个截面隆起(参考胶囊玻璃);0≈平面。
    property real thickness: 14
    // 折射率(玻璃 1.5):越大折射越夸张。
    property real ior: 1.5
    // 边缘高光强度:法线越平(边缘)越亮。
    property real edgeLight: 0.5
    // 磨砂模糊量:0=清晰玻璃(折射锐利),1=强磨砂(软化底色)。
    property real frostAmount: 0.5
    // 外侧投影(浮起立体感)。0 关闭。
    property real elevation: 6
    property color shadowColor: Qt.rgba(0, 0, 0, 0.35)
    color: "transparent"
    border.width: 0
    clip: false

    // 通用坐标定位:FrameAnimation 每帧驱动 _frame 自增,sourceRect 绑定 _frame
    // 采样纹理实际几何(sourceRect 钳制到 blurSource 边界后):玻璃在纹理内
    // 的偏移(_glassOff*)与纹理实际尺寸(_texW/H)。供 shader UV 换算——
    // 顶部/左缘控件扩边被钳时,u_srcOrigin 不再是固定 sampleMargin。
    property real _texOriginX: 0
    property real _texOriginY: 0
    property real _glassOffX: 0
    property real _glassOffY: 0
    property real _texW: 1
    property real _texH: 1
    // 滚动驱动源:控件在 Flickable 内滚动时,此 Flickable 的 contentY 是
    // sourceRect 重算的依赖。默认 null;控件在滚动容器内时由调用方传入。
    // (不用 FrameAnimation 每帧驱动——GUI 线程改 sourceRect 与 render 线程
    // 渲纹理竞争,滚动中撕裂。显式依赖在 GUI 线程同步,无撕裂。)
    property var scrollParent: null

    // 背景采样:抓取 blurSource 在本控件覆盖区域的纹理(四周扩 sampleMargin),
    // 降采样让高斯更明显、更省 GPU。
    ShaderEffectSource {
        id: bgSource
        sourceItem: root.blurSource
        // 坐标系:ShaderEffectSource 把 sourceItem 当「根项」渲染(官方:
        // fully opaque root item) → 纹理 = 该 item 视口,内容已含滚动偏移。
        // mapToItem(bs) 把控件角映射到 bs 坐标系(跨滚动/嵌套变换)即采样区。
        // 绑定依赖:mapToItem 是函数调用,绑定系统不追踪,须显式读入所有影响
        // 映射的属性——blurSource 自身滚动(contentY)、scrollParent(控件在
        // 滚动容器内而 blurSource 固定时的滚动源)、双方几何(x/y/w/h,窗口
        // 缩放/布局变化)。GUI 线程同步,无 FrameAnimation 的渲染线程撕裂。
        sourceRect: {
            const bs = root.blurSource
            // 显式依赖:blurSource 自身滚动、scrollParent 滚动、双方几何。
            const _s1 = bs ? bs.contentY : 0
            const _s2 = root.scrollParent ? root.scrollParent.contentY : 0
            const _geom = root.x + root.y + root.width + root.height
                        + (bs ? bs.x + bs.y + bs.width + bs.height : 0)
            if (!bs)
                return Qt.rect(0, 0, 0, 0)
            const p = root.mapToItem(bs, 0, 0)
            const m = root.sampleMargin
            // 钳制到 blurSource 边界:顶部/左缘控件扩边会越界(p-m<0),越界区
            // 无内容致采样黑。钳后玻璃在纹理内的实际偏移 = p - 实际原点。
            const x0 = Math.max(0, p.x - m)
            const y0 = Math.max(0, p.y - m)
            const x1 = Math.min(bs.width, p.x + root.width + m)
            const y1 = Math.min(bs.height, p.y + root.height + m)
            // 记录实际采样原点与玻璃在纹理内的偏移,供 shader UV 换算。
            root._texOriginX = x0
            root._texOriginY = y0
            root._glassOffX = p.x - x0
            root._glassOffY = p.y - y0
            root._texW = Math.max(1, x1 - x0)
            root._texH = Math.max(1, y1 - y0)
            return Qt.rect(x0, y0, root._texW, root._texH)
        }
        // textureSize 留空(默认)= sourceRect 像素尺寸,与 shader u_texSize
        // (逻辑尺寸)一致,避免降采样导致的 UV 换算/清晰度歧义。
        live: true
        hideSource: false
    }

    // 折射输出:采样清晰纹理 bgSource,SDF 圆角矩形 + 屏幕导数法线 + Snell
    // 折射:中心平面清晰无扭曲,边缘隆起处光线弯折产生锐利液体扭曲;磨砂
    // 模糊在 shader 内多 tap 完成(独立叠加,不糊折射);SDF 裁圆角。
    ShaderEffect {
        id: refractFx
        anchors.fill: parent
        property var source: bgSource
        property size u_size: Qt.size(width, height)
        // 玻璃在采样纹理内的实际像素原点(扩边被 blurSource 边界钳制后的偏移)。
        property vector2d u_srcOrigin: Qt.vector2d(root._glassOffX, root._glassOffY)
        // 采样纹理实际像素尺寸(钳制后,可能小于 w+2m)。
        property vector2d u_texSize: Qt.vector2d(root._texW, root._texH)
        property real u_radius: root.radius
        property real u_thickness: root.thickness
        property real u_ior: root.ior
        property real u_edgeLight: root.edgeLight
        property real u_hoverGlow: root.hoverGlow
        property real u_frost: root.frostAmount
        property real u_blurRadius: root.blurRadius
        property real u_saturation: root.saturation
        fragmentShader: "qrc:/qt/qml/MoePlayer/Core/shaders/glass-refract.frag.qsb"
    }

    // 玻璃底色 + 亮描边(在折射之上)。
    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: root.glassColor
        border.width: 1
        border.color: root.borderColor
    }

    // 外侧投影:沿下/侧缘的软阴影,把玻璃从背景「抬」起来(浮起立体感)。
    // 独立底层矩形(不被圆角 mask 裁切,可独立偏移/控透明度)。
    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: root.shadowColor
        visible: root.elevation > 0
        z: -1
        layer.enabled: root.elevation > 0
        layer.effect: MultiEffect {
            blurEnabled: true
            blur: 1.0
            blurMax: Math.max(1, root.elevation * 2)
        }
        // 投影略向下偏移,模拟光源在上方。
        transform: Translate { y: root.elevation * 0.5 }
        opacity: 0.6
    }
}
