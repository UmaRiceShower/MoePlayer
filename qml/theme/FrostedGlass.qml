import QtQuick
import QtQuick.Window
import QtQuick.Effects
import MoePlayer.Core

//! iOS 风磨砂玻璃组件:对控件下方场景做实时高斯模糊,叠加半透明亮色底、
//! 亮描边、边缘折射扭曲与边缘高光,底部内反光与外侧投影共同营造玻璃的
//! 立体感/浮起感。
//! - blurSource 传入要模糊的背景 Item(如 ListView / StackView / 页面内容根);
//!   不给则取窗口 contentItem。内联控件须传「不含自身的兄弟内容」避免自采样。
//! - 用作按钮底/摘要行/小面板:小尺寸用低 blurRadius 与弱投影;大浮层加大半径。
//! 与 GlassPanel 的差异:GlassPanel 面向「整幅浮层遮罩」,本组件面向「控件级
//! 玻璃质感」——多了边缘折射/边缘高光/顶部高光/底部反光/外投影等立体层。
Rectangle {
    id: root

    // ---- 背景模糊 ----
    // 要模糊的背景 Item;默认取窗口内容根。
    property var blurSource: Window.window ? Window.window.contentItem : null
    // 滚动容器(可选,Flickable):控件在滚动内容内而 blurSource 固定时,
    // 其 contentY 是 sourceRect 重算的依赖(blurSource 自身无 contentY)。
    // 例如 Detail 正文卡:blurSource=detailBg(固定),scrollSource=overview。
    property var scrollSource: null
    // 磨砂模糊半径(px,shader 内 box blur 采样步长)。控件级 4~8;大浮层 8~16。
    // 仅软化磨砂底色,不影响折射清晰度。
    property real blurRadius: 6
    // 采样扩边(px):bgSource 比玻璃矩形大四周边距,边缘折射越界时
    // 仍能采到真实背景(否则越界钳到边缘纹素→边缘糊带)。
    property real sampleMargin: 96
    // 采样降分辨率倍数:越大越省 GPU、模糊越柔;2 为清晰度/性能平衡。
    property real downsample: 2

    // ---- 玻璃质感 ----
    // 玻璃底色(半透明亮色,iOS 亮玻璃偏白、暗玻璃偏深色)。默认暗玻璃。
    // 黑底下降低不透明度(0.22)减灰感——透出背景而非盖灰。
    property color glassColor: Qt.rgba(0.10, 0.11, 0.15, 0.22)
    // 饱和度提升(黑底/模糊去饱和时补回色彩):0=不变,>0 增强。0.3~0.6 自然。
    property real saturation: 0.4
    // hover 提亮(0=无):提亮折射内容与边缘光,而非盖白膜(白膜在黑底发灰)。
    // iOS 玻璃 hover 是「透过的光变亮」,保持透亮不遮色。
    property real hoverGlow: 0.0
    // 描边色(比玻璃更亮,营造边缘反光)。默认偏白的亮边。
    property color borderColor: Qt.rgba(1, 1, 1, 0.28)
    // 顶部镜面高光强度(0 关闭)。iOS 玻璃顶部受光,0.18~0.30 自然。
    property real highlightOpacity: 0.22
    // 底部内反光强度(0 关闭)。底部受下方场景反光,弱于顶部。
    property real reflectionOpacity: 0.10
    // ---- 边缘折射(液体玻璃,SDF 法线 + Snell) ----
    // 玻璃边缘隆起厚度(px):越大边缘弯曲越陡、折射越强。0≈平面玻璃(无扭曲)。
    // 控件级 8~16;浮层级 20~32。
    property real thickness: 14
    // 折射率(玻璃 1.5):越大折射越夸张。1.3~1.8 自然。
    property real ior: 1.5
    // 边缘高光强度:法线越平(边缘)越亮。0 关闭;0.3~0.6 明显。
    property real edgeLight: 0.5
    // 磨砂模糊量:0=清晰玻璃(折射锐利),1=强磨砂(软化底色)。0.3~0.6 自然。
    // 折射扭曲始终清晰,模糊只软化整体底色(参考真玻璃按钮)。
    property real frostAmount: 0.5
    // 外侧投影(浮起立体感)。控件级小、浮层级大;0 关闭。
    property real elevation: 6
    property color shadowColor: Qt.rgba(0, 0, 0, 0.35)

    color: "transparent"
    border.width: 0
    clip: false

    // 背景采样:抓取 blurSource 在本控件覆盖区域的纹理,降采样让高斯更明显。
    ShaderEffectSource {
        id: bgSource
        sourceItem: root.blurSource
        // ★ 坐标系:ShaderEffectSource 把 sourceItem 当「根项」渲染(官方:
        //   fully opaque root item) → 纹理 = 该 item 视口,内容已含滚动偏移。
        //   mapToItem(bs) 把控件角映射到 bs 坐标系(跨滚动变换),即为采样区。
        // ★ 绑定依赖:mapToItem 是函数调用,绑定系统不追踪。须显式读入所有
        //   影响映射的属性:blurSource 滚动(contentY,自身滚动时)、scrollSource
        //   (控件在外层 Flickable 内而 blurSource 固定时的滚动源)、几何(双方
        //   x/y/w/h,窗口缩放/布局变化)。缺哪个都会在对应变化时错位。
        sourceRect: {
            const bs = root.blurSource
            if (!bs)
                return Qt.rect(0, 0, 0, 0)
            // 显式依赖(首行读取,触发重算;undefined 按 0)。
            const _s1 = bs.contentY
            const _s2 = root.scrollSource ? root.scrollSource.contentY : 0
            const _geom = root.x + root.y + root.width + root.height
                        + bs.x + bs.y + bs.width + bs.height
            const p = root.mapToItem(bs, 0, 0)
            // 四周扩边 sampleMargin:边缘折射越界时仍能采到真实背景。
            const m = root.sampleMargin
            return Qt.rect(p.x - m, p.y - m,
                           root.width + m * 2, root.height + m * 2)
        }
        textureSize: Qt.size(
            Math.max(1, (root.width + root.sampleMargin * 2) / root.downsample),
            Math.max(1, (root.height + root.sampleMargin * 2) / root.downsample))
        live: true
        hideSource: false
        // 不设 visible:false:ShaderEffectSource 自身可见性不影响其纹理被
        // MultiEffect 取用;visible:false 可能阻止纹理生成(致"无模糊")。
    }

    // 单级:清晰折射 + 内部磨砂模糊 + 圆角裁剪(可见输出)。采样清晰纹理
    // bgSource,SDF 圆角矩形 + 屏幕导数法线 + Snell 折射:中心平面清晰无扭曲,
    // 边缘隆起处光线弯折产生锐利液体扭曲(参考 iquilezles 玻璃按钮——折射
    // 采样清晰背景,模糊是独立叠加而非前置)。磨砂模糊在 shader 内多 tap 完成,
    // 由 blurAmount 控制与清晰折射的混合比。
    ShaderEffect {
        id: refractFx
        anchors.fill: parent
        // 采样清晰背景纹理(非模糊纹理——折射要锐利)。
        property var source: bgSource
        property size u_size: Qt.size(width, height)
        // 采样纹理中玻璃矩形的原点(扩边后左上角,纹理像素坐标)。
        property vector2d u_srcOrigin: Qt.vector2d(root.sampleMargin, root.sampleMargin)
        // 采样纹理尺寸(玻璃 + 扩边)。
        property vector2d u_texSize: Qt.vector2d(width + root.sampleMargin * 2,
                                                  height + root.sampleMargin * 2)
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


    // 玻璃底色 + 亮描边(在模糊之上)。
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
