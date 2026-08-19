import QtQuick

// mpv-osd-symbols 图标的手绘近似(QML Canvas 矢量绘制)。
// 官方 OSC 用 mpv-osd-symbols 字体字形(E002-E215 私有区),本仓库只有
// FontForge 源文件(TOOLS/mpv-osd-symbols.sfdir)不捆绑 ttf,故用等宽
// 线条图标复刻经典样式(classic)。
Canvas {
    id: icon

    property string icon: "play"
    property color color: "white"
    property real strokeWidth: 2

    implicitWidth: 20
    implicitHeight: 20

    onIconChanged: requestPaint()
    onColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
        const ctx = getContext("2d")
        ctx.reset()
        const W = width
        const H = height
        const w = strokeWidth
        ctx.strokeStyle = icon.color
        ctx.fillStyle = icon.color
        ctx.lineWidth = w
        ctx.lineCap = "round"
        ctx.lineJoin = "round"

        // 底边 x0、顶点 x1 的实心三角。
        const tri = (x0, x1, y0, y1) => {
            ctx.beginPath()
            ctx.moveTo(x0, y0)
            ctx.lineTo(x1, (y0 + y1) / 2)
            ctx.lineTo(x0, y1)
            ctx.closePath()
            ctx.fill()
        }
        const line = (x0, y0, x1, y1) => {
            ctx.beginPath()
            ctx.moveTo(x0, y0)
            ctx.lineTo(x1, y1)
            ctx.stroke()
        }
        const rect = (x0, y0, x1, y1) => {
            ctx.beginPath()
            ctx.rect(x0, y0, x1 - x0, y1 - y0)
            ctx.stroke()
        }

        switch (icon.icon) {
        case "menu": // E102:三条横线
            line(W * 0.15, H * 0.3, W * 0.85, H * 0.3)
            line(W * 0.15, H * 0.5, W * 0.85, H * 0.5)
            line(W * 0.15, H * 0.7, W * 0.85, H * 0.7)
            break
        case "prev": // E110:竖线 + 双三角(上一曲)
            line(W * 0.2, H * 0.1, W * 0.2, H * 0.9)
            tri(W * 0.85, W * 0.5, H * 0.15, H * 0.85)
            tri(W * 0.6, W * 0.3, H * 0.15, H * 0.85)
            break
        case "next": // E101:双三角 + 竖线(下一曲)
            tri(W * 0.15, W * 0.5, H * 0.15, H * 0.85)
            tri(W * 0.4, W * 0.7, H * 0.15, H * 0.85)
            line(W * 0.8, H * 0.1, W * 0.8, H * 0.9)
            break
        case "pause": // E002:两条竖线
            line(W * 0.3, H * 0.12, W * 0.3, H * 0.88)
            line(W * 0.7, H * 0.12, W * 0.7, H * 0.88)
            break
        case "play": // E101:右三角
            tri(W * 0.2, W * 0.82, H * 0.1, H * 0.9)
            break
        case "clock": // E006:缓冲时钟
            ctx.beginPath()
            ctx.arc(W / 2, H / 2, W * 0.34, 0, Math.PI * 2)
            ctx.stroke()
            line(W / 2, H / 2, W / 2, H * 0.3)
            line(W / 2, H / 2, W * 0.68, H / 2)
            break
        case "chapter_prev": // E104:单三角 + 竖线
            line(W * 0.25, H * 0.1, W * 0.25, H * 0.9)
            tri(W * 0.85, W * 0.4, H * 0.15, H * 0.85)
            break
        case "chapter_next": // E105:竖线 + 单三角
            tri(W * 0.15, W * 0.6, H * 0.15, H * 0.85)
            line(W * 0.75, H * 0.1, W * 0.75, H * 0.9)
            break
        case "audio": // E106:喇叭 + 声波
            tri(W * 0.32, W * 0.12, H * 0.28, H * 0.72)
            line(W * 0.5, H * 0.3, W * 0.5, H * 0.7)
            line(W * 0.68, H * 0.18, W * 0.68, H * 0.82)
            break
        case "subtitle": // E107:气泡 + 两条线
            rect(W * 0.15, H * 0.2, W * 0.8, H * 0.62)
            tri(W * 0.42, W * 0.28, H * 0.56, H * 0.85)
            line(W * 0.3, H * 0.35, W * 0.65, H * 0.35)
            line(W * 0.3, H * 0.48, W * 0.65, H * 0.48)
            break
        case "volume1": // E10B-E10E:喇叭 + 递增声波
        case "volume2":
        case "volume3":
            tri(W * 0.32, W * 0.1, H * 0.3, H * 0.7)
            if (icon.icon !== "volume1") {
                line(W * 0.5, H * 0.3, W * 0.5, H * 0.7)
                if (icon.icon === "volume3")
                    line(W * 0.68, H * 0.16, W * 0.68, H * 0.84)
            }
            break
        case "mute": // E10A:喇叭 + 斜杠
            tri(W * 0.32, W * 0.1, H * 0.3, H * 0.7)
            line(W * 0.55, H * 0.15, W * 0.85, H * 0.85)
            break
        case "fullscreen": // E108:四角外扩 L
            line(W * 0.12, H * 0.12, W * 0.38, H * 0.12)
            line(W * 0.12, H * 0.12, W * 0.12, H * 0.38)
            line(W * 0.88, H * 0.12, W * 0.62, H * 0.12)
            line(W * 0.88, H * 0.12, W * 0.88, H * 0.38)
            line(W * 0.12, H * 0.88, W * 0.38, H * 0.88)
            line(W * 0.12, H * 0.88, W * 0.12, H * 0.62)
            line(W * 0.88, H * 0.88, W * 0.62, H * 0.88)
            line(W * 0.88, H * 0.88, W * 0.88, H * 0.62)
            break
        case "exit_fullscreen": // E109:四角内缩 L
            line(W * 0.35, H * 0.12, W * 0.35, H * 0.35)
            line(W * 0.35, H * 0.35, W * 0.12, H * 0.35)
            line(W * 0.65, H * 0.12, W * 0.65, H * 0.35)
            line(W * 0.65, H * 0.35, W * 0.88, H * 0.35)
            line(W * 0.35, H * 0.88, W * 0.35, H * 0.65)
            line(W * 0.35, H * 0.65, W * 0.12, H * 0.65)
            line(W * 0.65, H * 0.88, W * 0.65, H * 0.65)
            line(W * 0.65, H * 0.65, W * 0.88, H * 0.65)
            break
        case "close": // E115:X
            line(W * 0.22, H * 0.22, W * 0.78, H * 0.78)
            line(W * 0.78, H * 0.22, W * 0.22, H * 0.78)
            break
        case "minimize": // E112:底部横线
            line(W * 0.22, H * 0.8, W * 0.78, H * 0.8)
            break
        case "maximize": // E113:方框
            rect(W * 0.22, H * 0.22, W * 0.78, H * 0.78)
            break
        case "unmaximize": // E114:小框 + 大框
            rect(W * 0.22, H * 0.18, W * 0.6, H * 0.5)
            rect(W * 0.3, H * 0.42, W * 0.78, H * 0.82)
            break
        }
    }
}
