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
    title: root.loading ? Qt.application.name + " · 正在获取播放地址…" : Qt.application.name
    color: "black"

    function syncTitle() {
        if (root.loading) {
            root.title = Qt.application.name + " · 正在获取播放地址…"
            return
        }
        const mt = mpv.mediaTitle || (source.length ? source.split("/").pop() : "")
        let t = mt
        if (mpv.playlistCount > 1)
            t = "[" + (mpv.playlistPos + 1) + "/" + mpv.playlistCount + "] " + mt
        root.title = t ? Qt.application.name + " · " + t : Qt.application.name
    }

    onLoadingChanged: root.syncTitle()

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

    readonly property bool isMaximized: root.visibility === Window.Maximized

    // 供 Connections 处理器引用:Qt 6.11 中信号处理器函数内的 id 解析
    // 在部分实例上会得到 null(运行时报 TypeError),绑定求值于创建时,
    // 持有的是实例引用,不经过运行时 id 查找。
    readonly property var owner: root

    // 停止回传已发出(stop 触发的 playbackEnded 不再重复上报)。
    property bool stoppedReported: false

    // 自定义 UI 显隐。
    property bool controlsVisible: true
    property bool showSettings: false
    readonly property bool isFullScreen: root.visibility === Window.FullScreen

    // 版本/音轨/字幕信息(来自 EmbyClient.fetchPlaybackInfo 返回的 meta)。
    property var mediaSources: []
    property var audioStreams: []
    property var subtitleStreams: []
    property int currentAudioIndex: -1
    property int currentSubtitleIndex: -1
    property bool switchingVersion: false

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

        // 保存版本/音轨/字幕信息。
        root.mediaSources = root.meta.mediaSources || []
        root.audioStreams = root.meta.audioStreams || []
        root.subtitleStreams = root.meta.subtitleStreams || []
        // 默认选中 Emby 返回的默认轨(通过 isDefault 标记)。
        root.currentAudioIndex = root.defaultStreamIndex(root.audioStreams)
        root.currentSubtitleIndex = root.defaultStreamIndex(root.subtitleStreams)

        root.syncTitle()
        mpv.load(url, root.headers)
    }
    // 返回默认轨索引;无默认则取第一个。
    function defaultStreamIndex(streams) {
        for (let i = 0; i < streams.length; ++i) {
            if (streams[i].isDefault)
                return i
        }
        return streams.length > 0 ? 0 : -1
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

    // 标题随 mpv 媒体标题/播放列表变化同步。
    Connections {
        target: mpv
        function onMediaTitleChanged() { root.syncTitle() }
        function onPlaylistPosChanged() { root.syncTitle() }
        function onPlaylistCountChanged() { root.syncTitle() }
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

    // 版本切换:重新拉取 PlaybackInfo 后加载新 URL。
    Connections {
        target: EmbyClient
        function onPlaybackReady(serverUrl, url, headers, meta) {
            if (!root.switchingVersion)
                return
            root.switchingVersion = false
            if (serverUrl !== root.meta.serverUrl || meta.itemId !== root.meta.itemId)
                return
            const savedPos = root.lastPosition
            root.stoppedReported = false
            root.meta = Object.assign({}, meta)
            root.source = url
            root.headers = headers || []
            root.mediaSources = meta.mediaSources || []
            root.audioStreams = meta.audioStreams || []
            root.subtitleStreams = meta.subtitleStreams || []
            root.currentAudioIndex = root.defaultStreamIndex(root.audioStreams)
            root.currentSubtitleIndex = root.defaultStreamIndex(root.subtitleStreams)
            mpv.load(url, root.headers)
            if (savedPos > 0)
                mpv.seek(savedPos)
        }
    }

    // ---------- 自绘播放 UI ----------
    function toggleFullscreen() {
        root.visibility = root.isFullScreen ? Window.Windowed : Window.FullScreen
    }
    function toggleMaximize() {
        if (root.isFullScreen)
            root.visibility = Window.Windowed
        else if (root.isMaximized)
            root.visibility = Window.Windowed
        else
            root.visibility = Window.Maximized
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
    function streamLabel(stream) {
        if (!stream)
            return ""
        if (stream.displayTitle)
            return stream.displayTitle
        const parts = []
        if (stream.title)
            parts.push(stream.title)
        if (stream.displayLanguage)
            parts.push(stream.displayLanguage)
        else if (stream.language)
            parts.push(stream.language)
        if (stream.codec)
            parts.push(stream.codec.toUpperCase())
        return parts.length > 0 ? parts.join(" · ") : "未知"
    }
    function setAudioStream(index) {
        root.currentAudioIndex = index
        const s = root.audioStreams[index]
        if (s)
            mpv.command(["set", "aid", String(s.index)])
    }
    function setSubtitleStream(index) {
        root.currentSubtitleIndex = index
        if (index < 0 || !root.subtitleStreams[index]) {
            mpv.command(["set", "sid", "no"])
            return
        }
        const s = root.subtitleStreams[index]
        if (s.isExternal && s.deliveryUrl) {
            // 外挂字幕先加载再选择:补全前缀并附带 api_key(与主视频流
            // withApiKey 同法,字幕接口同样需要认证;mpv 命令无头可带)。
            let u = root.meta.serverUrl
                     + (s.deliveryUrl.startsWith("/") ? s.deliveryUrl : "/" + s.deliveryUrl)
            if (root.meta.token && u.indexOf("api_key=") < 0)
                u += (u.indexOf("?") >= 0 ? "&" : "?") + "api_key=" + root.meta.token
            mpv.command(["sub-add", u])
        }
        mpv.command(["set", "sid", String(s.index)])
    }
    function switchVersion(mediaSourceId) {
        if (!mediaSourceId || mediaSourceId === root.meta.mediaSourceId || root.switchingVersion)
            return
        root.switchingVersion = true
        const pos = mpv.position
        root.lastPosition = pos
        EmbyClient.fetchPlaybackInfo(root.meta.serverUrl, root.meta.token,
                                     root.meta.userId, root.meta.itemId,
                                     mediaSourceId)
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
            id: topTitle
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.right: topControls.left
            anchors.rightMargin: 12
            text: root.title
            color: "white"
            font.pixelSize: 14
            elide: Text.ElideRight
        }

        Row {
            id: topControls
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: 12
            spacing: 8

            Button {
                id: playlistPrevBtn
                width: 32
                height: 32
                visible: mpv.playlistCount > 1
                onClicked: mpv.playlistPrev()
                background: Rectangle {
                    radius: height / 2
                    color: playlistPrevBtn.hovered ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                }
                contentItem: AppText {
                    text: "⏴"
                    color: "white"
                    font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
            Button {
                id: playlistNextBtn
                width: 32
                height: 32
                visible: mpv.playlistCount > 1
                onClicked: mpv.playlistNext()
                background: Rectangle {
                    radius: height / 2
                    color: playlistNextBtn.hovered ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                }
                contentItem: AppText {
                    text: "⏵"
                    color: "white"
                    font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
            Button {
                id: minimizeBtn
                width: 32
                height: 32
                onClicked: root.showMinimized()
                background: Rectangle {
                    radius: height / 2
                    color: minimizeBtn.hovered ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                }
                contentItem: AppText {
                    text: "−"
                    color: "white"
                    font.pixelSize: 18
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
            Button {
                id: maximizeBtn
                width: 32
                height: 32
                onClicked: root.toggleMaximize()
                background: Rectangle {
                    radius: height / 2
                    color: maximizeBtn.hovered ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                }
                contentItem: AppText {
                    text: root.isMaximized ? "⛶" : "□"
                    color: "white"
                    font.pixelSize: 16
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
            Button {
                id: closeBtn
                width: 32
                height: 32
                onClicked: root.close()
                background: Rectangle {
                    radius: height / 2
                    color: closeBtn.hovered ? Constants.moePinkDark : Constants.moePink
                }
                contentItem: AppText {
                    text: "×"
                    color: "white"
                    font.pixelSize: 18
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
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
        visible: opacity > 0 && !mpv.pausedForCache
        Behavior on opacity { NumberAnimation { duration: 220 } }
    }

    // 缓冲提示。
    Column {
        anchors.centerIn: parent
        spacing: 12
        visible: mpv.pausedForCache && mpv.state !== "idle"
        opacity: visible ? 0.9 : 0
        Behavior on opacity { NumberAnimation { duration: 220 } }
        BusyIndicator {
            anchors.horizontalCenter: parent.horizontalCenter
            running: parent.visible
            implicitWidth: 40
            implicitHeight: 40
            contentItem: Canvas {
                width: 40
                height: 40
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
            text: "缓冲中…"
            color: "white"
            font.pixelSize: 14
        }
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

            // 快退 5s。
            Button {
                id: skipBackwardBtn
                width: 34
                height: 34
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.seekRelative(-5)
                background: Rectangle {
                    radius: height / 2
                    color: skipBackwardBtn.hovered ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                }
                contentItem: AppText {
                    text: "⏪"
                    color: "white"
                    font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
            // 上一章节。
            Button {
                id: chapterPrevBtn
                width: 34
                height: 34
                anchors.verticalCenter: parent.verticalCenter
                visible: mpv.chapterList.length > 0
                onClicked: mpv.chapterPrev()
                background: Rectangle {
                    radius: height / 2
                    color: chapterPrevBtn.hovered ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                }
                contentItem: AppText {
                    text: "⏮"
                    color: "white"
                    font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            // 播放/暂停。
            Button {
                id: ppBtn
                width: 44
                height: 44
                anchors.verticalCenter: parent.verticalCenter
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

            // 下一章节。
            Button {
                id: chapterNextBtn
                width: 34
                height: 34
                anchors.verticalCenter: parent.verticalCenter
                visible: mpv.chapterList.length > 0
                onClicked: mpv.chapterNext()
                background: Rectangle {
                    radius: height / 2
                    color: chapterNextBtn.hovered ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                }
                contentItem: AppText {
                    text: "⏭"
                    color: "white"
                    font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
            // 快进 5s。
            Button {
                id: skipForwardBtn
                width: 34
                height: 34
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.seekRelative(5)
                background: Rectangle {
                    radius: height / 2
                    color: skipForwardBtn.hovered ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                }
                contentItem: AppText {
                    text: "⏩"
                    color: "white"
                    font.pixelSize: 14
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
                // 固定宽(小时级时长最坏 17 字符),供 seekBar 宽度公式抵扣。
                width: 110
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignLeft
            }

            // 进度条。宽度 = 控制栏剩余(固定按钮组总宽 502 + 11 项间距 120
            // = 622;可见性变化使按钮组变窄时尾部留白,不挤压 seekBar)。
            Item {
                id: seekBar
                anchors.verticalCenter: parent.verticalCenter
                height: 24
                width: Math.max(120, parent.width - 622)
                property real progress: mpv.duration > 0 ? mpv.position / mpv.duration : 0
                property real hoverX: 0
                property real hoverRatio: 0
                property bool hoverActive: false

                Rectangle {
                    id: seekTrack
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: 4
                    radius: 2
                    color: Qt.rgba(1, 1, 1, 0.25)
                }
                // 缓存范围覆盖在当前位置之后。
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    x: parent.width * seekBar.progress
                    width: Math.max(0, Math.min(parent.width - x,
                                                  parent.width * (mpv.demuxerCacheDuration / mpv.duration)))
                    height: 4
                    radius: 2
                    color: Qt.rgba(1, 1, 1, 0.35)
                    visible: mpv.demuxerCacheDuration > 0 && mpv.duration > 0
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * seekBar.progress
                    height: 4
                    radius: 2
                    color: Constants.moePink
                }
                // 章节标记。
                Repeater {
                    model: mpv.chapterList
                    delegate: Rectangle {
                        required property var modelData
                        anchors.verticalCenter: parent.verticalCenter
                        visible: mpv.duration > 0
                        x: (modelData.time / mpv.duration) * parent.width - 1
                        y: -4
                        width: 2
                        height: 12
                        radius: 1
                        color: "white"
                        opacity: 0.7
                    }
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    x: parent.width * seekBar.progress - 6
                    width: 12
                    height: 12
                    radius: 6
                    color: "white"
                }
                // 悬停时间提示。
                Rectangle {
                    id: seekTooltip
                    x: Math.max(0, Math.min(parent.width - width, seekBar.hoverX - width / 2))
                    y: -28
                    width: seekTooltipText.implicitWidth + 12
                    height: 22
                    radius: 11
                    color: Qt.rgba(0, 0, 0, 0.75)
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, 0.3)
                    visible: seekBar.hoverActive && mpv.duration > 0
                    AppText {
                        id: seekTooltipText
                        anchors.centerIn: parent
                        text: root.formatTime(seekBar.hoverRatio * mpv.duration)
                        color: "white"
                        font.pixelSize: 11
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onPressed: root.seekTo(mouse.x / seekBar.width)
                    onPositionChanged: {
                        if (pressed) root.seekTo(mouse.x / seekBar.width)
                        seekBar.hoverX = mouse.x
                        seekBar.hoverRatio = Math.max(0, Math.min(1, mouse.x / seekBar.width))
                    }
                    onEntered: seekBar.hoverActive = true
                    onExited: seekBar.hoverActive = false
                }
            }

            // 音量按钮。
            Button {
                id: volBtn
                width: 44
                height: 44
                onClicked: mpv.toggleMute()
                background: Rectangle {
                    radius: height / 2
                    color: volBtn.hovered ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                }
                contentItem: AppText {
                    text: mpv.mute || mpv.volume === 0 ? "🔇" : "🔊"
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

            // 播放设置(版本/音轨/字幕)。
            Button {
                id: settingsBtn
                width: 44
                height: 44
                onClicked: root.showSettings = true
                background: Rectangle {
                    radius: height / 2
                    color: settingsBtn.hovered ? Qt.rgba(1, 1, 1, 0.15) : "transparent"
                }
                contentItem: AppText {
                    text: "⚙"
                    color: "white"
                    font.pixelSize: 18
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
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

    // 播放设置弹窗（版本/音轨/字幕）。
    Rectangle {
        anchors.fill: parent
        visible: root.showSettings
        color: Qt.rgba(0, 0, 0, 0.55)
        z: 20
        MouseArea {
            anchors.fill: parent
            onClicked: root.showSettings = false
        }
        Rectangle {
            anchors.centerIn: parent
            width: 360
            height: settingsCol.implicitHeight + 48
            radius: 12
            color: Theme.surface
            border.width: 1
            border.color: Qt.rgba(Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 0.35)
            MouseArea {
                anchors.fill: parent
            }
            Column {
                id: settingsCol
                anchors.top: parent.top
                anchors.topMargin: 24
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width - 48
                spacing: 20

                Row {
                    spacing: 8
                    AppText {
                        text: "♥"
                        color: Constants.moePink
                        font.pixelSize: 24
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    AppText {
                        text: "播放设置"
                        color: Theme.textPrimary
                        font.pixelSize: 20
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // 版本
                Column {
                    width: parent.width
                    spacing: 6
                    visible: root.mediaSources.length > 1
                    AppText {
                        text: "版本"
                        color: Theme.textPrimary
                        font.pixelSize: 14
                        font.bold: true
                    }
                    Column {
                        width: parent.width
                        spacing: 4
                        Repeater {
                            model: root.mediaSources
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                width: parent.width
                                height: 34
                                radius: 17
                                color: root.meta.mediaSourceId === modelData.id
                                       ? Constants.moePink : (verHover.hovered ? Theme.bg : Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.5))
                                border.width: 1
                                border.color: root.meta.mediaSourceId === modelData.id ? Constants.moePink : Theme.textMuted
                                AppText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left
                                    anchors.leftMargin: 14
                                    text: modelData.name || "默认版本"
                                    color: root.meta.mediaSourceId === modelData.id ? "white" : Theme.textPrimary
                                    font.pixelSize: 13
                                }
                                MouseArea {
                                    id: verHover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: {
                                        root.switchVersion(modelData.id)
                                        root.showSettings = false
                                    }
                                }
                            }
                        }
                    }
                }

                // 音轨
                Column {
                    width: parent.width
                    spacing: 6
                    visible: root.audioStreams.length > 0
                    AppText {
                        text: "音轨"
                        color: Theme.textPrimary
                        font.pixelSize: 14
                        font.bold: true
                    }
                    Column {
                        width: parent.width
                        spacing: 4
                        Repeater {
                            model: root.audioStreams
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                width: parent.width
                                height: 34
                                radius: 17
                                color: root.currentAudioIndex === index
                                       ? Constants.moePink : (audioHover.hovered ? Theme.bg : Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.5))
                                border.width: 1
                                border.color: root.currentAudioIndex === index ? Constants.moePink : Theme.textMuted
                                AppText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left
                                    anchors.leftMargin: 14
                                    text: root.streamLabel(modelData)
                                    color: root.currentAudioIndex === index ? "white" : Theme.textPrimary
                                    font.pixelSize: 13
                                }
                                MouseArea {
                                    id: audioHover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: {
                                        root.setAudioStream(index)
                                        root.showSettings = false
                                    }
                                }
                            }
                        }
                    }
                }

                // 字幕
                Column {
                    width: parent.width
                    spacing: 6
                    visible: root.subtitleStreams.length > 0
                    AppText {
                        text: "字幕"
                        color: Theme.textPrimary
                        font.pixelSize: 14
                        font.bold: true
                    }
                    Column {
                        width: parent.width
                        spacing: 4
                        Rectangle {
                            width: parent.width
                            height: 34
                            radius: 17
                            color: root.currentSubtitleIndex < 0
                                   ? Constants.moePink : (subOffHover.hovered ? Theme.bg : Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.5))
                            border.width: 1
                            border.color: root.currentSubtitleIndex < 0 ? Constants.moePink : Theme.textMuted
                            AppText {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.leftMargin: 14
                                text: "关闭字幕"
                                color: root.currentSubtitleIndex < 0 ? "white" : Theme.textPrimary
                                font.pixelSize: 13
                            }
                            MouseArea {
                                id: subOffHover
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: {
                                    root.setSubtitleStream(-1)
                                    root.showSettings = false
                                }
                            }
                        }
                        Repeater {
                            model: root.subtitleStreams
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                width: parent.width
                                height: 34
                                radius: 17
                                color: root.currentSubtitleIndex === index
                                       ? Constants.moePink : (subHover.hovered ? Theme.bg : Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.5))
                                border.width: 1
                                border.color: root.currentSubtitleIndex === index ? Constants.moePink : Theme.textMuted
                                AppText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left
                                    anchors.leftMargin: 14
                                    text: root.streamLabel(modelData)
                                    color: root.currentSubtitleIndex === index ? "white" : Theme.textPrimary
                                    font.pixelSize: 13
                                }
                                MouseArea {
                                    id: subHover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: {
                                        root.setSubtitleStream(index)
                                        root.showSettings = false
                                    }
                                }
                            }
                        }
                    }
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
            else if (key === Qt.Key_M) { mpv.toggleMute(); event.accepted = true }
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
