//! 双层图片圆形扩散溶解替换(awww 壁纸切换式):source 变化时,新图从圆心
//! 一点按圆形裁剪扩散,圆内新图渐入、圆外保持旧图(inward=true 反向)。
//!
//! 实现:bottom/top Image 元素 visible:false(防遮挡)+ ShaderEffectSource
//! 直接采样(官方文档:sourceItem 本身可 invisible,仍渲染进纹理;无需
//! layer.enabled,避免额外一层 FBO),ShaderEffect 溶解层采样两纹理,
//! 在 shader 内完成圆形扩散 + 圆角裁切。
//! - 圆角:corner SDF 在溶解 shader 内做(cornerRadius >= 短边一半即圆形,
//!   如演职人员头像);圆角外 alpha=0 真透明,透出页面背景(离屏纹理源
//!   visible:false,无直角内容可露)。
//! - 纹理:ShaderEffectSource textureSize 按物理分辨率(x devicePixelRatio),
//!   DPR>1 屏幕 1:1 采样锐利。
//! - 全部走普通 ShaderEffect(非 layer.effect):QML 属性绑定 uniform 的
//!   路径经溶解动画实测可靠(layer.effect 的纹理坐标/自定义 uniform 行为
//!   不可靠,弃用)。
//!
//! 为什么不用 Canvas:Qt6 Canvas 的 backing store 固定为元素逻辑尺寸
//! (devicePixelRatio 属性已在 Qt6 移除),DPR>1 屏幕上放大渲染必然模糊。
import QtQuick

Item {
    id: root

    // 普通属性(非 alias):source 变化由 onSourceChanged 驱动双层流程。
    property string source: ""
    property alias fillMode: bottom.fillMode
    property alias asynchronous: bottom.asynchronous
    property alias cache: bottom.cache
    // 底层图加载状态(调用方做加载失败回退判断)。
    property alias status: bottom.status
    // 扩散时长。
    property int duration: 800
    // true=新图从四周向圆心收缩(Outer);false=从圆心一点扩散(Grow)。
    property bool inward: false
    // 扩散圆心(归一化 0-1,相对本组件)。
    property vector2d center: Qt.vector2d(0.5, 0.5)
    // 圆角半径(0=直角);>= 短边一半时呈圆形。
    property real cornerRadius: 0
    // 替换流程内部状态。
    property bool _pending: false

    onSourceChanged: {
        const s = root.source
        if (s === "") {
            // 无图:清空两层。
            revealAnim.stop()
            bottom.source = ""
            top.source = ""
            root._pending = false
            fx.u_reveal = 0
            fx.u_dissolve = 0
            return
        }
        if (root._pending) {
            // 扩散进行中又来新 source:换目标图,重放动画。
            revealAnim.stop()
            top.source = s
            if (top.status === Image.Ready)
                root._beginReveal()
        } else if (bottom.source !== "" && bottom.source !== s && bottom.status === Image.Ready) {
            // 底层已有显示中的旧图:新图进顶层,加载完成后圆形扩散。
            root._pending = true
            fx.u_reveal = 0
            fx.u_dissolve = 0
            top.source = s
            if (top.status === Image.Ready)
                root._beginReveal()
        } else {
            // 首次/无旧图:直接到底层显示。
            bottom.source = s
        }
    }

    function _beginReveal() {
        const w = root.width, h = root.height
        if (w === 0 || h === 0)
            return
        const cx = root.center.x * w, cy = root.center.y * h
        const maxR = Math.sqrt(Math.max(cx, w - cx) * Math.max(cx, w - cx)
                             + Math.max(cy, h - cy) * Math.max(cy, h - cy))
        revealAnim.radiusTo = root.inward ? 0 : maxR
        revealAnim.radiusFrom = root.inward ? maxR : 0
        fx.u_dissolve = 0
        revealAnim.start()
    }

    // 底层:当前图。visible:false 防遮挡,ShaderEffectSource 直接采样
    // 渲染进纹理(官方文档:sourceItem 可 invisible 仍入纹理)。
    Image {
        id: bottom
        anchors.fill: parent
        visible: false
        retainWhileLoading: true
    }
    // 顶层:过渡中的新图(同离屏处理)。
    Image {
        id: top
        anchors.fill: parent
        visible: false
        fillMode: bottom.fillMode
        asynchronous: bottom.asynchronous
        cache: bottom.cache
        retainWhileLoading: true
        onStatusChanged: {
            if (status === Image.Ready && root._pending)
                root._beginReveal()
        }
    }
    // 溶解层:圆形扩散 + 圆角(普通 ShaderEffect,属性绑定可靠)。
    ShaderEffect {
        id: fx
        anchors.fill: parent
        z: 2
        property var srcOld: ShaderEffectSource {
            sourceItem: bottom
            live: true
            textureSize: Qt.size(Math.round(root.width * Screen.devicePixelRatio),
                                 Math.round(root.height * Screen.devicePixelRatio))
        }
        property var srcNew: ShaderEffectSource {
            sourceItem: top
            live: true
            textureSize: Qt.size(Math.round(root.width * Screen.devicePixelRatio),
                                 Math.round(root.height * Screen.devicePixelRatio))
        }
        property real u_radius: root.cornerRadius
        property vector2d u_size: Qt.vector2d(root.width, root.height)
        property vector2d u_center: Qt.vector2d(root.width * root.center.x,
                                                root.height * root.center.y)
        property real u_reveal: 0
        property real u_dissolve: 0
        property real u_inward: root.inward ? 1.0 : 0.0
        fragmentShader: "qrc:/qt/qml/MoePlayer/Core/shaders/crossfade.frag.qsb"
    }

    ParallelAnimation {
        id: revealAnim
        property real radiusFrom: 0
        property real radiusTo: 0
        onFinished: {
            // 画布已成新图:同步底层,复位,释放替换流程。
            bottom.source = root.source
            fx.u_reveal = 0
            fx.u_dissolve = 0
            top.source = ""
            root._pending = false
        }
        NumberAnimation {
            target: fx
            property: "u_reveal"
            from: revealAnim.radiusFrom
            to: revealAnim.radiusTo
            duration: root.duration
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: fx
            property: "u_dissolve"
            from: 0
            to: 1
            duration: root.duration
            easing.type: Easing.OutCubic
        }
    }
}
