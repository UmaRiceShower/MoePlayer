pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import MoePlayer.Core

//! 播放窗口:MpvItem 渲染视频,UI 控件由 QML 自绘(播放/暂停/进度/音量/全屏)。
//! 鼠标/键盘事件不再转发给 mpv,由 QML 层直接调用 MpvItem API。
//! 保留 Emby 播放状态回传:起播、10s 进度、暂停、停止、每 10 分钟 Ping。
Window {
    id: root
    width: 960
    height: 540
    visible: true
    title: root.loading ? Qt.application.name + " · 正在获取播放地址…"
          : source.length ? Qt.application.name + " · " + source.split("/").pop()
          : Qt.application.name
    color: "black"

    property string source: ""
    property var headers: []
    // 播放元数据:{itemId, mediaSourceId, playSessionId, playMethod}。
    property var meta: ({})

    // 协商中(窗口已建、播放地址未到):显示加载态,startPlayback 后隐藏。
    property bool loading: false
    // 协商失败文案:非空显示失败态(错误信息 + 关闭按钮)。
    property string loadError: ""

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

    // 停止回传已发出(stop 触发的 playbackEnded 不再重复上报)。
    property bool stoppedReported: false

    // 自定义 UI 显隐。
    property bool controlsVisible: true
    readonly property bool isFullScreen: root.visibility === Window.FullScreen

    // 窗口关闭完成(Main 据此从播放窗口列表移除)。
    signal windowClosed()
    // 正常播完(错误退出不发):主窗口据此重拉当前页已看/进度。
    signal playbackFinished()

    // 播放地址协商完成:设置元数据并起播(先开窗后台协商模式下,
    // 窗口创建时无 source,起播统一经此入口)。
    function startPlayback(url, headers, meta) {
        root.source = url
        root.headers = headers || []
        root.meta = meta || {}
        root.loading = false
        root.loadError = ""
        mpv.load(url, root.headers)
    }
    // 协商失败:显示错误态,由用户关闭(或直接点窗口 X)。
    function showLoadError(message) {
        root.loading = false
        root.loadError = message || ""
    }

    // 关窗时上报最终位置(用缓存值,mpv 已停止读取不到)并停止播放:
    // Window.close() 只隐藏窗口,对象与 mpv 继续存活、音频照播。
    onClosing: {
        if (root.reporting && !root.stoppedReported) {
            root.stoppedReported = true
            EmbyClient.reportPlaybackStopped(root.meta.serverUrl, root.meta.token,
                                             root.meta.userId, root.meta.itemId,
                                             root.meta.mediaSourceId, root.meta.playSessionId,
                                             root.lastPosition)
        }
        mpv.command(["stop"])
        root.windowClosed()
        // 隐藏窗口的 MpvItem/mpv 残留,显式销毁释放。
        root.destroy()
    }

    onActiveChanged: if (active) keyCatcher.forceActiveFocus()
    Component.onCompleted: keyCatcher.forceActiveFocus()

    MpvItem {
        id: mpv
        anchors.fill: parent
        Component.onCompleted: {
            // 播放流代理:配置层已限 HTTP(https 目标走 CONNECT 隧道)。
            mpv.httpProxy = ConfigManager.proxy
            // 先开窗后协商模式:创建时 source 为空,起播统一经
            // root.startPlayback;仅在调用方直接携带 url 创建时立即加载。
            if (root.source !== "")
                load(root.source, root.headers)
        }
    }

    // 代理热重载:新开的流用新代理(进行中的流不受影响)。
    Connections {
        target: ConfigManager
        function onProxyChanged() {
            mpv.httpProxy = ConfigManager.proxy
        }
    }

    // 播放状态回传驱动。用 Connections 而非 MpvItem 内联 handler:
    // Qt 6.11 中属性 change 信号的内联 handler 作用域异常,引用 root 会得到 null。
    Connections {
        target: mpv
        // 与文件级 owner 同机制:处理器函数内 id 解析不可靠,经绑定期
        // 捕获的实例引用访问 root;声明为本对象属性可让 qmllint 识别。
        property var owner: root.owner
        // 开始解码(时长首次有效) → 上报播放开始;续播则跳到上次位置。
        function onPlaybackStarted() {
            owner.lastDuration = mpv.duration
            if (owner.reporting)
                // 回传按源路由:凭据随 meta 携带(见 fetchPlaybackInfo)。
                EmbyClient.reportPlaybackStart(owner.meta.serverUrl, owner.meta.token,
                                               owner.meta.userId, owner.meta.itemId,
                                               owner.meta.mediaSourceId, owner.meta.playSessionId,
                                               owner.meta.playMethod, 0)
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
                EmbyClient.reportPlaybackProgress(owner.meta.serverUrl, owner.meta.token,
                                                  owner.meta.userId, owner.meta.itemId,
                                                  owner.meta.mediaSourceId, owner.meta.playSessionId,
                                                  owner.meta.playMethod, mpv.position, false)
            }
        }
        // 暂停/恢复等状态变化立即上报一次(携带 IsPaused)。
        function onStateChanged() {
            if (!owner.reporting || mpv.state === "idle")
                return
            EmbyClient.reportPlaybackProgress(owner.meta.serverUrl, owner.meta.token,
                                              owner.meta.userId, owner.meta.itemId,
                                              owner.meta.mediaSourceId, owner.meta.playSessionId,
                                              owner.meta.playMethod, mpv.position,
                                              mpv.state === "paused")
        }
        // 播放结束(正常播完或出错) → 上报停止。
        // resume 位置与已看由服务器维护(Progress 每 10s 写入位置,
        // 播完 ≥90% 时服务器自动标已看)。
        function onPlaybackEnded(error) {
            if (owner.reporting && !owner.stoppedReported) {
                owner.stoppedReported = true
                EmbyClient.reportPlaybackStopped(owner.meta.serverUrl, owner.meta.token,
                                                 owner.meta.userId, owner.meta.itemId,
                                                 owner.meta.mediaSourceId, owner.meta.playSessionId,
                                                 owner.lastPosition)
            }
            // 正常播完:通知主窗口重拉当前页(等效替代 WS 实时推送)。
            if (!error)
                owner.playbackFinished()
        }
    }

    // 播放中每 10 分钟 Ping 一次,维持服务器会话。
    Timer {
        interval: Constants.pingIntervalMs
        running: root.reporting && mpv.state !== "idle"
        repeat: true
        onTriggered: EmbyClient.reportPlaybackPing(root.meta.serverUrl, root.meta.token,
                                                   root.meta.userId, root.meta.playSessionId)
    }

    // ---------- 自绘播放 UI ----------
    function toggleFullscreen() {
        root.visibility = root.isFullScreen ? Window.Windowed : Window.FullScreen
    }
    function playPause() {
        if (mpv.state === "playing")
            mpv.setPause(true)
        else if (mpv.state === "paused")
            mpv.setPause(false)
    }
    function seekRelative(seconds) {
        const pos = mpv.position + seconds
        mpv.seek(Math.max(0, Math.min(pos, mpv.duration || pos)))
    }
    function seekTo(ratio) {
        const pos = (mpv.duration || 0) * Math.max(0, Math.min(1, ratio))
        mpv.seek(pos)
    }
    function formatTime(seconds) {
        const s = Math.max(0, Math.round(seconds || 0))
        const h = Math.floor(s / 3600)
        const m = Math.floor((s % 3600) / 60)
        const sec = s % 60
        const mm = m < 10 ? "0" + m : m
        const ss = sec < 10 ? "0" + sec : sec
        return h > 0 ? h + ":" + mm + ":" + ss : mm + ":" + ss
    }

    // 自动隐藏控制栏。
    Timer {
        id: hideControlsTimer
        interval: 3000
        repeat: false
        onTriggered: {
            if (!controlBarArea.containsMouse)
                root.controlsVisible = false
        }
    }
    function showControls() {
        root.controlsVisible = true
        hideControlsTimer.restart()
    }

    // 视频区域鼠标交互:移动显示控件,点击播放/暂停,双击全屏,滚轮音量。
    MouseArea {
        id: overlayMouse
        anchors.fill: parent
        hoverEnabled: true
        onPositionChanged: root.showControls()
        onPressed: {
            root.showControls()
            // 点击非控件区域切换播放/暂停。
            if (!controlBarArea.containsMouse)
                root.playPause()
        }
        onDoubleClicked: root.toggleFullscreen()
        onWheel: function (wheel) {
            root.showControls()
            const delta = wheel.angleDelta.y / 120
            mpv.volume = Math.max(0, Math.min(100, mpv.volume + delta * 5))
        }
    }

    // 顶部信息栏。
    Rectangle {
        id: topBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 48
        color: Qt.rgba(0, 0, 0, 0.35)
        opacity: root.controlsVisible ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 220 } }

        AppText {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 16
            text: root.title
            color: "white"
            font.pixelSize: 14
            elide: Text.ElideRight
            width: parent.width - 120
        }
        Button {
            id: closeBtn
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: 12
            width: 80
            height: 30
            text: "关闭"
            onClicked: root.close()
            background: Rectangle {
                radius: height / 2
                color: closeBtn.hovered ? Constants.moePinkDark : Constants.moePink
            }
            contentItem: AppText {
                text: closeBtn.text
                color: "white"
                font.pixelSize: 13
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }
    }

    // 暂停/播放大图标（居中提示）。
    AppText {
        anchors.centerIn: parent
        text: mpv.state === "paused" ? "⏸" : "▶"
        color: "white"
        font.pixelSize: 64
        opacity: mpv.state === "paused" ? 0.75 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 220 } }
    }

    // 底部控制栏。
    Rectangle {
        id: controlBar
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 68
        color: Qt.rgba(0, 0, 0, 0.55)
        opacity: root.controlsVisible ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 220 } }

        MouseArea {
            id: controlBarArea
            anchors.fill: parent
            hoverEnabled: true
            onPositionChanged: root.showControls()
        }

        Row {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 12

            // 播放/暂停。
            Button {
                id: ppBtn
                width: 44
                height: 44
                onClicked: root.playPause()
                background: Rectangle {
                    radius: height / 2
                    color: ppBtn.hovered ? Constants.moePinkDark : Constants.moePink
                }
                contentItem: AppText {
                    text: mpv.state === "playing" ? "⏸" : "▶"
                    color: "white"
                    font.pixelSize: 18
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            // 时间。
            AppText {
                id: timeLabel
                anchors.verticalCenter: parent.verticalCenter
                text: root.formatTime(mpv.position) + " / " + root.formatTime(mpv.duration)
                color: "white"
                font.pixelSize: 13
            }

            // 进度条。
            Item {
                id: seekBar
                anchors.verticalCenter: parent.verticalCenter
                height: 24
                width: parent.width - 320
                property real progress: mpv.duration > 0 ? mpv.position / mpv.duration : 0

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: 4
                    radius: 2
                    color: Qt.rgba(1, 1, 1, 0.25)
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * seekBar.progress
                    height: 4
                    radius: 2
                    color: Constants.moePink
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    x: parent.width * seekBar.progress - 6
                    width: 12
                    height: 12
                    radius: 6
                    color: "white"
                }
                MouseArea {
                    anchors.fill: parent
                    onPressed: root.seekTo(mouse.x / seekBar.width)
                    onPositionChanged: if (pressed) root.seekTo(mouse.x / seekBar.width)
                }
            }

            // 音量按钮。
            Button {
                id: volBtn
                width: 44
                height: 44
                onClicked: mpv.volume = mpv.volume > 0 ? 0 : 100
                background: Rectangle {
                    radius: height / 2
                    color: volBtn.hovered ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                }
                contentItem: AppText {
                    text: mpv.volume > 0 ? "🔊" : "🔇"
                    color: "white"
                    font.pixelSize: 18
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
            // 音量滑条。
            Item {
                id: volBar
                anchors.verticalCenter: parent.verticalCenter
                width: 80
                height: 16
                property real ratio: mpv.volume / 100

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: 4
                    radius: 2
                    color: Qt.rgba(1, 1, 1, 0.25)
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * volBar.ratio
                    height: 4
                    radius: 2
                    color: Constants.moePink
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    x: parent.width * volBar.ratio - 5
                    width: 10
                    height: 10
                    radius: 5
                    color: "white"
                }
                MouseArea {
                    anchors.fill: parent
                    onPressed: mpv.volume = Math.max(0, Math.min(100, (mouse.x / volBar.width) * 100))
                    onPositionChanged: if (pressed) mpv.volume = Math.max(0, Math.min(100, (mouse.x / volBar.width) * 100))
                }
            }

            // 全屏。
            Button {
                id: fsBtn
                width: 44
                height: 44
                onClicked: root.toggleFullscreen()
                background: Rectangle {
                    radius: height / 2
                    color: fsBtn.hovered ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                }
                contentItem: AppText {
                    text: root.isFullScreen ? "⛶" : "⛶"
                    color: "white"
                    font.pixelSize: 18
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }

    // 键盘处理。
    Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function (event) {
            const key = event.key
            if (key === Qt.Key_Space) { root.playPause(); event.accepted = true }
            else if (key === Qt.Key_Left) { root.seekRelative(-5); event.accepted = true }
            else if (key === Qt.Key_Right) { root.seekRelative(5); event.accepted = true }
            else if (key === Qt.Key_Up) { mpv.volume = Math.min(100, mpv.volume + 5); event.accepted = true }
            else if (key === Qt.Key_Down) { mpv.volume = Math.max(0, mpv.volume - 5); event.accepted = true }
            else if (key === Qt.Key_F) { root.toggleFullscreen(); event.accepted = true }
            else if (key === Qt.Key_M) { mpv.volume = mpv.volume > 0 ? 0 : 100; event.accepted = true }
            else if (key === Qt.Key_Escape) {
                if (root.isFullScreen) { root.visibility = Window.Windowed; event.accepted = true }
            }
            else if (key >= Qt.Key_0 && key <= Qt.Key_9) {
                const pct = (key - Qt.Key_0) / 10
                if (mpv.duration > 0) mpv.seek(mpv.duration * pct)
                event.accepted = true
            }
            root.showControls()
        }
    }

    // 协商加载/失败覆盖层:窗口创建即显示加载态,startPlayback 后隐藏;
    // 协商失败显示错误文案 + 关闭按钮(不自动关,用户可查错误信息)。
    Item {
        anchors.fill: parent
        visible: root.loading || root.loadError !== ""
        z: 10
        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0.07, 0.05, 0.09, 0.9)
        }
        Column {
            anchors.centerIn: parent
            spacing: 20
            // 粉圈转圈:Canvas 画 270° 圆弧 + 旋转动画。
            BusyIndicator {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.loading
                running: root.loading
                implicitWidth: 44
                implicitHeight: 44
                contentItem: Canvas {
                    id: spinCanvas
                    width: 44
                    height: 44
                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.reset()
                        ctx.strokeStyle = Constants.moePink
                        ctx.lineWidth = 4
                        ctx.lineCap = "round"
                        ctx.beginPath()
                        ctx.arc(width / 2, height / 2, width / 2 - 6,
                                -Math.PI / 2, Math.PI * 1.4)
                        ctx.stroke()
                    }
                    RotationAnimator on rotation {
                        from: 0; to: 360
                        duration: 900
                        loops: Animation.Infinite
                    }
                }
            }
            AppText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.loading ? "正在获取播放地址…" : "获取播放地址失败"
                color: root.loading ? Theme.textPrimary : Theme.danger
                font.pixelSize: 18
            }
            AppText {
                visible: root.loadError !== ""
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.loadError
                color: Theme.textMuted
                font.pixelSize: 13
                wrapMode: Text.Wrap
                width: Math.min(root.width - 120, 480)
                horizontalAlignment: Text.AlignHCenter
            }
            Button {
                id: errCloseBtn
                visible: root.loadError !== ""
                anchors.horizontalCenter: parent.horizontalCenter
                width: 120
                height: 38
                text: "关闭"
                onClicked: root.close()
                background: Rectangle {
                    radius: height / 2
                    color: errCloseBtn.hovered ? Constants.moePinkDark : Constants.moePink
                }
                contentItem: AppText {
                    text: errCloseBtn.text
                    color: "white"
                    font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }
}
