import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import MoePlayer.Playback
import "qrc:/qml/theme"

//! 播放窗口:MpvItem 播放视频,官方 OSC(进度条/按钮/时间)由 mpv 直接绘制。
//! 无自绘控件,鼠标/键盘事件转发给 mpv 以驱动 OSC 交互。
//! 携带播放元数据(meta)时执行 Emby 播放状态回传:
//! 起播 reportStart,播放中每 10s reportProgress,结束/关窗 reportStopped,每 10 分钟 Ping。
Window {
    id: root
    width: 960
    height: 540
    visible: true
    title: source.length ? Qt.application.name + " · " + source.split("/").pop() : Qt.application.name
    color: "black"

    property string source: ""
    property var headers: []
    // 播放元数据:{itemId, mediaSourceId, playSessionId, playMethod}。
    property var meta: ({})

    readonly property bool reporting: meta && meta.playSessionId !== undefined && meta.playSessionId !== ""
    property double lastProgressReport: 0
    // 最后已知播放位置:关窗时 mpv 已复位(time-pos 失效),回传须用缓存值。
    property double lastPosition: 0
    // 媒体总时长缓存(播完判定用)。
    property double lastDuration: 0
    // 续播位置(100ns ticks,来自详情页继续观看),起播后跳转。
    readonly property double resumeTicks: (meta && meta.resumePositionTicks) || 0

    // 供 Connections 处理器引用:Qt 6.11 中信号处理器函数内的 id 解析
    // 在部分实例上会得到 null(运行时报 TypeError),绑定求值于创建时,
    // 持有的是实例引用,不经过运行时 id 查找。
    readonly property var owner: root

    MpvItem {
        id: mpv
        anchors.fill: parent
        Component.onCompleted: load(root.source, root.headers)
    }

    // 播放状态回传驱动。用 Connections 而非 MpvItem 内联 handler:
    // Qt 6.11 中属性 change 信号的内联 handler 作用域异常,引用 root 会得到 null。
    Connections {
        target: mpv
        // 开始解码(时长首次有效) → 上报播放开始;续播则跳到上次位置。
        function onPlaybackStarted() {
            owner.lastDuration = mpv.duration
            if (owner.reporting)
                EmbyClient.reportPlaybackStart(owner.meta.itemId, owner.meta.mediaSourceId,
                                               owner.meta.playSessionId, owner.meta.playMethod, 0)
            if (owner.resumeTicks > 0)
                mpv.seek(owner.resumeTicks / Constants.ticksPerSecond)
        }
        // 播放中每 10 秒上报一次进度。
        function onPositionChanged() {
            owner.lastPosition = mpv.position
            if (!owner.reporting || mpv.state !== "playing")
                return
            const now = Date.now()
            if (now - owner.lastProgressReport >= Constants.progressReportMs) {
                owner.lastProgressReport = now
                EmbyClient.reportPlaybackProgress(owner.meta.itemId, owner.meta.mediaSourceId,
                                                  owner.meta.playSessionId, owner.meta.playMethod,
                                                  mpv.position, false)
            }
        }
        // 暂停/恢复等状态变化立即上报一次(携带 IsPaused)。
        function onStateChanged() {
            if (!owner.reporting || mpv.state === "idle")
                return
            EmbyClient.reportPlaybackProgress(owner.meta.itemId, owner.meta.mediaSourceId,
                                              owner.meta.playSessionId, owner.meta.playMethod,
                                              mpv.position, mpv.state === "paused")
        }
        // 播放结束(正常播完或出错) → 上报停止。
        // resume 位置与已看由服务器维护(Progress 每 10s 写入位置,
        // 播完 ≥90% 时服务器自动标已看)。
        function onPlaybackEnded(error) {
            if (owner.reporting && !owner.stoppedReported) {
                owner.stoppedReported = true
                EmbyClient.reportPlaybackStopped(owner.meta.itemId, owner.meta.mediaSourceId,
                                                 owner.meta.playSessionId, owner.lastPosition)
            }
        }
    }

    // 播放中每 10 分钟 Ping 一次,维持服务器会话。
    Timer {
        interval: Constants.pingIntervalMs
        running: root.reporting && mpv.state !== "idle"
        repeat: true
        onTriggered: EmbyClient.reportPlaybackPing(root.meta.playSessionId)
    }

    // 停止回传已发出(stop 触发的 playbackEnded 不再重复上报)。
    property bool stoppedReported: false

    // 窗口关闭完成(Main 据此从播放窗口列表移除)。
    signal windowClosed()

    // 关窗时上报最终位置(用缓存值,mpv 已停止读取不到)并停止播放:
    // Window.close() 只隐藏窗口,对象与 mpv 继续存活、音频照播。
    onClosing: {
        if (root.reporting && !root.stoppedReported) {
            root.stoppedReported = true
            EmbyClient.reportPlaybackStopped(root.meta.itemId, root.meta.mediaSourceId,
                                             root.meta.playSessionId, root.lastPosition)
        }
        mpv.command(["stop"])
        root.windowClosed()
        // 隐藏窗口的 MpvItem/mpv 残留,显式销毁释放。
        root.destroy()
    }

    // 鼠标转发:mpv `mouse <x> <y> <button> [mode]`(button -1=移动,0/1/2=左/中/右键);
    // 坐标为整数(mpv 的 mouse 命令不接受浮点),滚轮经 keypress WHEEL_UP|WHEEL_DOWN 转发。
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onPositionChanged: mpv.command(["mouse", Math.round(x), Math.round(y), -1])
        onPressed: function (mouse) {
            const btn = mouse.button === Qt.LeftButton ? 0
                      : mouse.button === Qt.MiddleButton ? 1 : 2
            mpv.command(["mouse", Math.round(mouse.x), Math.round(mouse.y), btn, "single"])
        }
        onWheel: function (wheel) {
            if (wheel.angleDelta.y > 0)
                mpv.command(["keypress", "WHEEL_UP"])
            else if (wheel.angleDelta.y < 0)
                mpv.command(["keypress", "WHEEL_DOWN"])
        }
    }

    // 键盘转发:Qt 键码映射到 mpv 键名,经 keypress 下发(MpvItem 已开启默认绑定)。
    Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.onPressed: function (event) {
            const map = {
                [Qt.Key_Space]: "SPACE",
                [Qt.Key_Left]: "LEFT",
                [Qt.Key_Right]: "RIGHT",
                [Qt.Key_Up]: "UP",
                [Qt.Key_Down]: "DOWN",
                [Qt.Key_Escape]: "ESC",
                [Qt.Key_P]: "p",
                [Qt.Key_M]: "m",
                [Qt.Key_F]: "f",
                [Qt.Key_Return]: "ENTER",
                [Qt.Key_Enter]: "ENTER",
                [Qt.Key_Slash]: "/",
                [Qt.Key_Asterisk]: "*",
                [Qt.Key_9]: "9",
                [Qt.Key_0]: "0"
            }
            const name = map[event.key]
            if (name) {
                mpv.command(["keypress", name])
                event.accepted = true
            }
        }
    }

    Component.onCompleted: keyCatcher.forceActiveFocus()
    onActiveChanged: if (active) keyCatcher.forceActiveFocus()
}
