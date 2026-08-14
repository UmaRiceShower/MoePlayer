//! 双层图片圆形扩散溶解替换(awww 壁纸切换式,Qt 文档/社区标准做法):
//! source 变化时,新图从圆心一点按圆形裁剪扩散;圆内新图 globalAlpha
//! 0→1 渐进溶解(对齐 awww 圆内像素逐步混合的观感),圆外保持旧图。
//! inward=true 反向(圆外新图,圆向圆心收缩)。动画用 Canvas 每帧两次
//! drawImage + clip(无逐像素循环,避免 Canvas 文档警告的大图/频繁
//! 更新开销)。完成后下层同步新图、画布复位,供下次替换复用。
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
    // 替换流程内部状态。
    property bool _pending: false

    // 底层:常显当前图(替换期间保留旧图)。
    Image {
        id: bottom
        anchors.fill: parent
        retainWhileLoading: true
    }
    // 顶层:过渡中的新图(仅作 Canvas 绘制源;z 0 被画布盖住)。
    Image {
        id: top
        anchors.fill: parent
        fillMode: bottom.fillMode
        asynchronous: bottom.asynchronous
        cache: bottom.cache
        retainWhileLoading: true
    }
    // 混合画布:旧图全屏 + 圆内新图渐入(clip + globalAlpha)。
    Canvas {
        id: view
        anchors.fill: parent
        z: 1
        visible: root._pending
        // 圆半径(像素)与圆内溶解度,动画驱动。
        property real radius: 0
        property real dissolve: 0
        onRadiusChanged: requestPaint()
        onDissolveChanged: requestPaint()
        // 任一图片加载完成:新图就绪则启动扩散。
        onImageLoaded: {
            if (root._pending && view.isImageLoaded(root.source))
                root._beginReveal()
        }
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            const w = width, h = height
            if (w === 0 || h === 0)
                return
            const cx = root.center.x * w, cy = root.center.y * h
            const r = Math.max(0, view.radius)
            // 底图:当前显示的旧图(Image 元素,已加载)。
            ctx.drawImage(bottom, 0, 0, w, h)
            // 新图:经 loadImage 预加载后按 URL 绘制。
            if (!view.isImageLoaded(root.source))
                return
            if (root.inward) {
                // Outer:新图全屏渐入,圆内以旧图盖住(圆从最大收缩到 0)。
                ctx.globalAlpha = view.dissolve
                ctx.drawImage(root.source, 0, 0, w, h)
                ctx.globalAlpha = 1
                ctx.save()
                ctx.beginPath()
                ctx.arc(cx, cy, r, 0, Math.PI * 2)
                ctx.clip()
                ctx.drawImage(bottom, 0, 0, w, h)
                ctx.restore()
            } else {
                // Grow:圆内新图渐入、圆外旧图(圆从点扩散)。
                ctx.save()
                ctx.beginPath()
                ctx.arc(cx, cy, r, 0, Math.PI * 2)
                ctx.clip()
                ctx.globalAlpha = view.dissolve
                ctx.drawImage(root.source, 0, 0, w, h)
                ctx.restore()
            }
        }
    }

    onSourceChanged: {
        const s = root.source
        if (s === "") {
            // 无图:清空两层。
            revealAnim.stop()
            bottom.source = ""
            root._pending = false
            return
        }
        if (root._pending) {
            // 扩散进行中又来新 source:换目标图,重放动画。
            revealAnim.stop()
            view.loadImage(s)
            if (view.isImageLoaded(s))
                root._beginReveal()
        } else if (bottom.source !== "" && bottom.source !== s && bottom.status === Image.Ready) {
            // 底层已有显示中的旧图:新图进画布,加载完成后圆形扩散。
            root._pending = true
            view.radius = 0
            view.dissolve = 0
            top.source = s
            view.loadImage(s)
            if (view.isImageLoaded(s))
                root._beginReveal()
        } else {
            // 首次/无旧图:直接到底层显示。
            bottom.source = s
        }
    }

    function _beginReveal() {
        const w = view.width, h = view.height
        if (w === 0 || h === 0)
            return
        const cx = root.center.x * w, cy = root.center.y * h
        const maxR = Math.sqrt(Math.max(cx, w - cx) * Math.max(cx, w - cx)
                             + Math.max(cy, h - cy) * Math.max(cy, h - cy))
        revealAnim.radiusTo = root.inward ? 0 : maxR
        revealAnim.radiusFrom = root.inward ? maxR : 0
        revealAnim.dissolveFrom = 0
        revealAnim.dissolveTo = 1
        revealAnim.start()
    }

    ParallelAnimation {
        id: revealAnim
        property real radiusFrom: 0
        property real radiusTo: 0
        property real dissolveFrom: 0
        property real dissolveTo: 1
        NumberAnimation {
            target: view
            property: "radius"
            from: revealAnim.radiusFrom
            to: revealAnim.radiusTo
            duration: root.duration
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: view
            property: "dissolve"
            from: revealAnim.dissolveFrom
            to: revealAnim.dissolveTo
            duration: root.duration
            easing.type: Easing.OutCubic
        }
        onFinished: {
            // 画布已成新图:同步底层,复位画布,释放替换流程。
            bottom.source = root.source
            view.radius = 0
            view.dissolve = 0
            top.source = ""
            root._pending = false
        }
    }
}
