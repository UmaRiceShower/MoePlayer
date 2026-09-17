import QtQuick
import QtQuick.Window
import QtQuick.Effects
import MoePlayer.Core

//! 通用磨砂玻璃组件(iOS 液体玻璃):对控件下方场景做实时折射+模糊,叠加
//! 半透明亮色底、亮描边与外侧投影,营造玻璃的立体感/浮起感。
//!
//! 通用性:调用方只需给 blurSource(要模糊的下方内容 Item),坐标定位与
//! 滚动跟随全自动——sourceRect 绑定显式读入滚动/几何依赖,内容滚动由
//! ShaderEffectSource.live:true 自动吸收。无需关心内容滚动与否。
//! 约束:blurSource 须与玻璃同窗口、为固定容器(或窗口内容根);玻璃随
//! 某 Flickable 滚动时须传 scrollParent=该 Flickable。仅支持平移/缩放,
//! blurSource 或玻璃带旋转时轴对齐采样区不成立。
//! - blurSource 默认取窗口内容根;内联控件须传「不含自身的兄弟内容」避免自采样。
//! - 控件级(按钮/摘要行/卡片)用低 blurRadius/小 thickness;大浮层加大半径。
Rectangle {
    id: root

    // ---- 背景采样 ----
    // 要模糊的下方内容 Item;默认取窗口内容根。
    // 类型化 Item(非 var):QML 对 var 持有的对象内部属性(width/contentY)
    // 不做依赖追踪 → blurSource 尺寸/滚动变化不重算 sourceRect(首值 0 卡死)。
    // property Item 让引擎追踪其属性变化。
    property Item blurSource: Window.window ? Window.window.contentItem : null
    // 磨砂模糊半径(px,shader 内 box blur 采样步长)。控件级 4~8;大浮层 8~16。
    // 仅软化磨砂底色,不影响折射清晰度。
    property real blurRadius: 6
    // 采样扩边(px):采样区比玻璃矩形大四周边距,边缘折射越界时仍能采到
    // 真实背景(否则越界钳到边缘纹素→边缘糊带)。应 ≥ 最大折射偏移量。
    property real sampleMargin: 96
    // ---- 玻璃质感 ----
    // 玻璃底色(半透明亮色)。黑底下降低不透明度(0.22)减灰感——透出背景。
    property color glassColor: Qt.rgba(Theme.scrim.r, Theme.scrim.g, Theme.scrim.b, 0.22)
    // 饱和度提升(黑底/模糊去饱和时补回色彩):0=不变,>0 增强。
    property real saturation: 0.4
    // hover 提亮(0=无):提亮折射内容与边缘光,而非盖白膜(白膜黑底发灰)。
    property real hoverGlow: 0.0
    // 描边色(比玻璃更亮,营造边缘反光;亮色系换压深一档的 rim)。
    property color borderColor: Theme.glassRim
    // rim/边缘光的边掩码(上,右,下,左;1=画 0=不画):贴边全宽的条把
    // 顶着窗框的三边光关掉,只留内侧沿。
    property vector4d rimMask: Qt.vector4d(1, 1, 1, 1)
    // ---- 边缘折射(液体玻璃凸透镜,SDF 法线 + Snell) ----
    // 玻璃边缘隆起厚度(px):≥短边一半时整个截面隆起(参考胶囊玻璃);0≈平面。
    property real thickness: 14
    // 边缘折射强度(0..1):边缘带采样点沿径向向外偏移 = 半径 × 该值。
    property real bend: 0.2
    // 边缘高光强度:法线越平(边缘)越亮。
    property real edgeLight: 0.5
    // 磨砂模糊量:0=清晰玻璃(折射锐利),1=强磨砂(软化底色)。
    property real frostAmount: 0.5
    // 外侧投影(浮起立体感)。0 关闭。
    property real elevation: 6
    // 投影:亮色系下投影是层级的主要手段(浅底上明显,收敛到不脏的量)
    property color shadowColor: ThemeStore.isLight ? Qt.rgba(0, 0, 0, 0.20)
                                                   : Qt.rgba(0, 0, 0, 0.35)
    color: "transparent"
    border.width: 0
    clip: false

    // 采样纹理实际几何(sourceRect 钳制到 blurSource 边界后):玻璃在纹理
    // 内的偏移(_glassOff*)与纹理实际尺寸(_texW/H)。供 shader UV 换算——
    // 顶部/左缘控件扩边被钳时,u_srcOrigin 不再是固定 sampleMargin。
    property real _glassOffX: 0
    property real _glassOffY: 0
    property real _texW: 1
    property real _texH: 1
    // 滚动驱动源:玻璃随某 Flickable 滚动时传此 Flickable,其 contentY 作为
    // sourceRect 重算的显式依赖(绑定不追踪 mapToGlobal 函数调用)。默认 null:
    // 玻璃固定时内容滚动由 live:true 自动吸收,sourceRect 值不变不重算。
    // 采用显式依赖而非每帧驱动:GUI 线程改 sourceRect 与 render 线程渲纹理
    // 竞争,滚动中会撕裂;显式依赖在 GUI 线程同步,无撕裂。
    property Item scrollParent: null

    // 自抓模式的更新策略:true = 每帧重抓(默认,跟随内容实时变化);
    // false = 首抓一次,之后由调用方挂内容信号驱动 refresh()(如
    // contentXChanged)——采样映射固定、只有内容会变的场景(行内滚动钮)
    // 借此把每帧抓取降为事件驱动。共享模式(blurGroup)下本属性无意义。
    property bool liveCapture: true
    function refresh() {
        if (!_sharedGlass)
            bgSource.scheduleUpdate()
    }

    // 背景采样:抓取 blurSource 在本控件覆盖区域的纹理(四周扩 sampleMargin),

    // 降采样让高斯更明显、更省 GPU。
    ShaderEffectSource {
        id: bgSource
        // 共享模式:本组件不再自建抓取(省掉每帧一次整片源遍历)。
        sourceItem: root._sharedGlass ? null : root.blurSource
        // 坐标系:ShaderEffectSource 把 sourceItem 当「根项」渲染(官方:
        // fully opaque root item) → 纹理 = 该 item 视口,内容已含滚动偏移。
        // 映射用 mapToGlobal 双端点相减(全局坐标走场景统一参考系,跨兄弟
        // 比 mapToItem 更稳)。
        // 绑定依赖:mapToGlobal 是函数调用,绑定系统不追踪,须显式读入所有
        // 影响映射的属性——blurSource 自身滚动(_s1,玻璃为源后代随其滚动时)、
        // scrollParent 滚动(_s2,玻璃在独立滚动容器内时)、双方几何(_geom,
        // 窗口缩放/布局变化)。GUI 线程同步,无渲染线程撕裂。
        sourceRect: {
            const bs = root.blurSource
            // 显式依赖:blurSource 自身滚动、scrollParent 滚动、双方几何。
            const _s1 = bs ? bs.contentY : 0
            const _s2 = root.scrollParent ? root.scrollParent.contentY : 0
            // 显式依赖:沿 root.parent 祖先链累积读各级 x/y/width/height。
            // mapToGlobal 是函数调用不被绑定追踪,只读 root 自身几何会漏掉
            // 祖先位置变化(如详情页原地换集:hero 高度变 → 本卡全局 y 变,但
            // root 局部坐标不变 → 绑定不重算 → 采样冻结旧位置,滚动才恢复)。
            // 沿父链读属性即注册依赖,任何祖先几何变化都触发重算。
            let _geom = root.x + root.y + root.width + root.height
            for (let a = root.parent; a; a = a.parent)
                _geom += a.x + a.y + a.width + a.height
            if (bs)
                _geom += bs.x + bs.y + bs.width + bs.height
            if (!bs)
                return Qt.rect(0, 0, 0, 0)
            const g = root.mapToGlobal(0, 0)
            const bsG = bs.mapToGlobal(0, 0)
            const p = Qt.point(g.x - bsG.x, g.y - bsG.y)
            const m = root.sampleMargin
            // 钳制到 blurSource 边界:顶部/左缘控件扩边会越界(p-m<0),越界区
            // 无内容致采样黑。钳后玻璃在纹理内的实际偏移 = p - 实际原点。
            const x0 = Math.max(0, p.x - m)
            const y0 = Math.max(0, p.y - m)
            const x1 = Math.min(bs.width, p.x + root.width + m)
            const y1 = Math.min(bs.height, p.y + root.height + m)
            // 记录玻璃在纹理内的偏移与实际尺寸,供 shader UV 换算。
            // 局部变量算尺寸:return 若直接引用 root._texW/_texH(刚赋值的属性),
            // 构成「绑定内写又读同属性」的 binding loop。用局部量,赋值与返回
            // 都基于它,打断循环。
            root._glassOffX = p.x - x0
            root._glassOffY = p.y - y0
            const tw = Math.max(1, x1 - x0)
            const th = Math.max(1, y1 - y0)
            root._texW = tw
            root._texH = th
            return Qt.rect(x0, y0, tw, th)
        }
        // textureSize 须显式指定:默认值 = sourceRect × devicePixelRatio
        // (Qt 实现按 DPR 放大纹理),而 shader u_texSize 是逻辑尺寸,DPR≠1
        // 时 UV 换算错位,玻璃会采样到错误区域。显式设逻辑尺寸让纹理与
        // u_texSize 严格一致;代价仅是 HiDPI 下不超采样,磨砂/折射本就不
        // 需要高分辨率。
        textureSize: Qt.size(Math.max(1, Math.round(root._texW)),
                              Math.max(1, Math.round(root._texH)))
        live: !root._sharedGlass && root.liveCapture
        hideSource: false
    }

    // 共享模糊源:多个玻璃盖在同一片内容上时(如首页固定导航的四个按钮)传同一个
    // GlassBlurSource —— 只抓一次纹理,采样区固定整片源,低频更新只造成内容滞后、
    // 不会错位。未传时自建按区抓取(旧行为,每帧同步、跟随控件移动)。
    property GlassBlurSource blurGroup: null
    readonly property bool _sharedGlass: blurGroup !== null
    // 玻璃在共享纹理里的位置(整片源为参考系):与 bgSource 的 sourceRect 一样
    // 用 mapToGlobal 双端点相减,并显式读入滚动/几何依赖(绑定不追踪函数调用)。
    property point _sharedPos: {
        const bs = root.blurSource
        const _s1 = bs ? bs.contentY : 0
        const _s2 = root.scrollParent ? root.scrollParent.contentY : 0
        let _geom = root.x + root.y + root.width + root.height
        for (let a = root.parent; a; a = a.parent)
            _geom += a.x + a.y + a.width + a.height
        if (!bs)
            return Qt.point(0, 0)
        const g = root.mapToGlobal(0, 0)
        const bsG = bs.mapToGlobal(0, 0)
        return Qt.point(g.x - bsG.x, g.y - bsG.y)
    }

    // 折射输出:采样清晰纹理 bgSource,SDF 圆角矩形 + 屏幕导数法线 + Snell
    // 折射:中心平面清晰无扭曲,边缘隆起处光线弯折产生锐利液体扭曲;磨砂
    // 模糊在 shader 内多 tap 完成(独立叠加,不糊折射);SDF 裁圆角。
    ShaderEffect {
        id: refractFx
        anchors.fill: parent
        property var source: root._sharedGlass ? root.blurGroup.sharedTexture : bgSource
        property size u_size: Qt.size(width, height)
        // 玻璃在采样纹理内的实际像素原点(扩边被 blurSource 边界钳制后的偏移)。
        property vector2d u_srcOrigin: root._sharedGlass
                                     ? Qt.vector2d(root._sharedPos.x, root._sharedPos.y)
                                     : Qt.vector2d(root._glassOffX, root._glassOffY)
        // 采样纹理实际像素尺寸(钳制后,可能小于 w+2m)。
        property vector2d u_texSize: root._sharedGlass
                                     ? Qt.vector2d(root.blurSource ? root.blurSource.width : 1,
                                                   root.blurSource ? root.blurSource.height : 1)
                                     : Qt.vector2d(root._texW, root._texH)
        property real u_radius: root.radius
        property real u_thickness: root.thickness
        property real u_bend: root.bend
        property real u_edgeLight: root.edgeLight
        property real u_hoverGlow: root.hoverGlow
        property real u_frost: root.frostAmount
        property real u_blurRadius: root.blurRadius
        property real u_saturation: root.saturation
        // 亮色系:加法边缘光/反射收敛(浅底加亮过曝)
        property real u_light: ThemeStore.isLight ? 1.0 : 0.0
        // 采样透明区(页面留白)回退到主题底色:亮主题下否则透出黑盘
        property color u_backColor: ThemeStore.background.baseTop
        // 玻璃底色与亮描边都进 shader:描边画在 SDF 边缘且叠于底色之上
        // (QML 覆盖层 Rectangle 的 border 与玻璃体是两次独立绘制,读作双环)。
        property color u_glassColor: root.glassColor
        property color u_rimColor: root.borderColor
        property vector4d u_rimMask: root.rimMask
        fragmentShader: "qrc:/qt/qml/MoePlayer/Core/shaders/glass-refract.frag.qsb"
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
