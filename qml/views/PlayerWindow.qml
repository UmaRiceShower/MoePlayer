import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import MoePlayer.Core

//! 内嵌播放窗:libmpv 视频表面 + QML 控制层(主题玻璃控制条)。
//! Main 在 embeddedPlaybackRequested 时 createObject 新建一个顶层窗口;
//! 每次播放 = 一个独立窗口,允许多窗并发(同集去重在 MpvClient 会话键)。
//! 关窗/Esc = 停播(回传 Stopped);播完自动关窗。
Window {
    id: root

    // Main 建窗时注入(含 itemId/serverUrl/seriesId/displayName/seriesName)。
    property var meta: ({})

    visible: true
    width: 1280
    height: 720
    color: "black"
    // 父链归属主窗(防 QML GC 回收),但不是瞬态对话框:独立顶层窗,
    // niri 平铺不浮动。
    transientParent: null
    title: titleMain

    // ---- 控制层显隐(自动隐藏状态机)----
    // 显示条件:鼠标活动后 3s 无操作即隐;控制条 hover/拖动进度时钉住。
    property bool chromeVisible: true
    // 连播换集时标题跟随(播放上下文变化由 MpvClient 广播)。
    // 第一行 = 集标题;第二行 = 剧名 · S*E*(电影/无集信息时单行剧名)。
    property string titleMain: meta.displayName || meta.seriesName || ""
    property string titleSub: ""
    // 当前集信息(选集模型按 currentItemId 查;驱动标题双行与高亮)。
    // 会话键(起始集定死):账号|起始集 itemId;MpvClient 会话路由恒用它,
    // currentItemId(换集后变)只做展示与选集定位。
    readonly property string sessionKey: (meta.accountId ? meta.accountId + "|" : "")
                                         + (meta.itemId || "")
    function episodeInfo() {
        const sid = meta.serverUrl || ""
        if (sid === "")
            return null
        const m = EmbyClient.allEpisodesModelFor(sid, meta.accountId || "", meta.seriesId || "")
        for (let i = 0; i < m.count; i++) {
            const it = m.itemAt(i)
            if (it.id === root.currentItemId)
                return it
        }
        return null
    }
    function refreshTitle() {
        const ep = episodeInfo()
        if (ep && (ep.name || "") !== "") {
            root.titleMain = ep.name
            const se = "S" + (ep.seasonNo || 0) + "E" + (ep.episodeNo || 0)
            root.titleSub = (root.meta.seriesName || "") + " · " + se
        } else {
            root.titleMain = root.meta.displayName || root.meta.seriesName || ""
            root.titleSub = ""
        }
    }
    onCurrentItemIdChanged: refreshTitle()
    // 正在播放的集(连播高亮;playbackContextChanged 更新)。
    property string currentItemId: meta.itemId || ""
    // 右侧面板:"" | "episodes" | "tracks"(互斥,开新收旧)。
    property string panel: ""
    // 轨道列表(MpvClient.tracksChanged 喂;file-loaded 后 refreshTracks)。
    property var tracks: []
    // 章节表(MpvClient.chaptersChanged 喂;[{time,title}],进度条刻度)。
    property var chapters: []

    function wake() {
        chromeVisible = true
        hideTimer.restart()
    }

    // 关窗幂等:stop 同步触发 onPlaybackFinished→closeSelf,与 goBack 兜底
    // 不双关;隐藏后自毁(createObject 的对象须显式 destroy;Window 无
    // closed 信号,用 visible 下落沿)。
    property bool _closed: false
    function closeSelf() {
        if (_closed)
            return
        _closed = true
        root.close()
    }
    onVisibleChanged: if (!visible && _closed) destroy()

    function goBack() {
        // 面板开着先收面板(一层层退,不直接关窗)。
        if (root.panel !== "") {
            root.panel = ""
            return true
        }
        MpvClient.stop(root.sessionKey)
        closeSelf() // 未起播时 stop 不发信号,直接自关
        return true
    }

    // 系统点窗框 X:等同 goBack(停播回传 Stopped)。
    onClosing: MpvClient.stop(root.sessionKey)

    function togglePause() {
        MpvClient.setPause(!video.paused, root.sessionKey)
    }
    function seekBy(delta) {
        MpvClient.command(["seek", delta, "relative"], root.sessionKey)
    }
    function adjustVolume(delta) {
        const v = Math.max(0, Math.min(100, Math.round(video.volume + delta)))
        MpvClient.setVolume(v, root.sessionKey)
        osd.showVolume(v)
    }
    function toggleFullscreen() {
        // 本窗独立全屏(主窗不受影响)。
        root.visibility = root.visibility === Window.FullScreen
                          ? Window.Windowed : Window.FullScreen
    }
    // 倍速档位循环(常用档,mpv 侧持久到换集)。
    function cycleSpeed() {
        const speeds = [1.0, 1.25, 1.5, 2.0, 0.5]
        let i = speeds.findIndex(s => Math.abs(s - video.speed) < 0.01)
        const next = speeds[(i + 1) % speeds.length]
        MpvClient.command(["set_property", "speed", next], root.sessionKey)
        osd.showText("倍速 " + next + "x")
    }
    function episodeJump(delta) {
        // 播放列表跳集:占位条目经 on_load hook 协商真实地址(连播链路)。
        MpvClient.command([delta > 0 ? "playlist-next" : "playlist-prev"],
                          root.meta.itemId || "")
    }

    // 章节磁吸:距章节点阈值内即吸附(返回章节时间;无 = -1)。
    // 阈值 = max(5s, 时长 1.2%),长片不会一吸一大片。
    function snapChapter(t) {
        const th = Math.max(5, video.duration * 0.012)
        for (const c of chapters)
            if (Math.abs(c.time - t) <= th)
                return c.time
        return -1
    }

    function fmtTime(s) {
        s = Math.max(0, Math.floor(s))
        const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), sec = s % 60
        const p = (n) => (n < 10 ? "0" + n : "" + n)
        return (h > 0 ? h + ":" : "") + p(m) + ":" + p(sec)
    }

    onWidthChanged: MpvClient.setEmbeddedOutputSize(root.sessionKey, video.width, video.height)
    onHeightChanged: MpvClient.setEmbeddedOutputSize(root.sessionKey, video.width, video.height)
    // 图标按钮(带自绘悬停气泡;QQC2 ToolTip 原生白底与播放器暗色不搭)。
    component IconBtn: ToolButton {
        property string tip: ""
        // 统一可点区(文本钮与图标钮同高同行高;底栏 RowLayout 垂直居中)。
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: 36
        implicitHeight: 36
        icon.color: "white"
        icon.width: 20
        icon.height: 20
        background: Item {}
        Rectangle {
            visible: parent.hovered && parent.tip !== ""
            anchors.bottom: parent.top
            anchors.bottomMargin: 8
            anchors.horizontalCenter: parent.horizontalCenter
            width: tipText.implicitWidth + 14
            height: tipText.implicitHeight + 8
            radius: 6
            color: Qt.rgba(0, 0, 0, 0.78)
            AppText {
                id: tipText
                anchors.centerIn: parent
                text: parent.parent.tip
                color: "white"
                font.pixelSize: 12
            }
        }
    }

    Component.onCompleted: {
        // 播放流代理与外部 spawn 对齐(libmpv 默认读 http_proxy 环境变量,
        // 显式下发配置值/显式置空,行为才与外部模式一致)。
        const proxy = ConfigManager.proxy || ""
        video.sendCommand(["set_property", "http-proxy", proxy])
        // 绑定 MpvClient 会话(startPending 已按 meta.itemId 预建);attach 即
        // flush 起播(observe/超分键位/待播 loadfile 在 flush 内发出)。
        MpvClient.setEmbeddedOutputSize(root.sessionKey, video.width, video.height)
        MpvClient.attachEmbedded(video.core, root.sessionKey)
        refreshTitle()
        root.requestActivate()
    }

    Connections {
        target: EmbyClient
        // 全集模型异步后于开窗:到达后重算双行标题(开窗时查空模型会
        // 落单行兜底,这里补刷新)。
        function onAllEpisodesReady(serverUrl, accountId, seriesId) {
            if (serverUrl === (root.meta.serverUrl || "")
                && seriesId === (root.meta.seriesId || ""))
                root.refreshTitle()
        }
    }

    Connections {
        target: MpvClient
        function onPlaybackFinished(sessionKey, itemId, error) {
            if (sessionKey === root.sessionKey)
                root.closeSelf()
        }
        // 连播换集:标题跟随实际播放集;轨道表按新集重拉。
        function onPlaybackContextChanged(m) {
            if (!m)
                return
            if (m.itemId) {
                root.currentItemId = m.itemId
                MpvClient.refreshTracks(root.sessionKey)
            }
        }
        function onTracksChanged(key, list) {
            if (key === root.sessionKey)
                root.tracks = list
        }
        function onChaptersChanged(key, list) {
            if (key === root.sessionKey)
                root.chapters = list
        }
        function onPlaybackStarted(sessionKey, itemId) {
            // 每集就绪即拉轨道(选轨已在 file-loaded 应用,这里是面板数据)。
            if (sessionKey === root.sessionKey)
                MpvClient.refreshTracks(root.sessionKey)
        }
    }

    MpvVideoItem {
        id: video
        anchors.fill: parent
    }

    // 输入层:单击=播放/暂停(300ms 内双击=全屏),滚轮=音量,移动=唤醒。
    MouseArea {
        id: inputArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        cursorShape: root.chromeVisible ? Qt.ArrowCursor : Qt.BlankCursor
        onPositionChanged: root.wake()
        onWheel: (wheel) => {
            root.wake()
            root.adjustVolume(wheel.angleDelta.y > 0 ? 5 : -5)
        }
        onClicked: {
            // 面板开着:点视频区 = 收面板(不换暂停态),符合"点空白处关闭"。
            if (root.panel !== "") {
                root.panel = ""
                return
            }
            clickTimer.start() // 双击优先:延迟判定
        }
        onDoubleClicked: {
            clickTimer.stop()
            root.toggleFullscreen()
        }
        Timer {
            id: clickTimer
            interval: 300
            onTriggered: root.togglePause()
        }
    }

    // 缓冲/加载转圈:起播前(尚无时长)或播放中等缓存(paused-for-cache)。
    property bool _everStarted: false
    BusyIndicator {
        anchors.centerIn: parent
        running: !root._everStarted || video.buffering
        palette.dark: "white"
        Connections {
            target: video
            function onDurationChanged() { if (video.duration > 0) root._everStarted = true }
        }
    }

    // 暂停时的中央大播放键(播放中不出现;控制层显隐独立)。
    ToolButton {
        anchors.centerIn: parent
        width: 88
        height: 88
        visible: video.paused && !video.buffering && root._everStarted
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }
        icon.source: "qrc:/icons/play.svg"
        icon.width: 64
        icon.height: 64
        icon.color: "white"
        onClicked: root.togglePause()
        background: Rectangle {
            radius: width / 2
            color: Qt.rgba(0, 0, 0, 0.45)
        }
    }

    // ---- 控制层(自动隐藏)----
    Item {
        id: chrome
        anchors.fill: parent
        opacity: root.chromeVisible ? 1 : 0
        // 隐藏时不挡输入(鼠标事件穿透到 inputArea)。
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 250 } }

        // 顶部:返回 + 标题。
        FrostedGlass {
            id: topBar
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            // 与底栏同款贴边全宽(胶囊全宽读作横幅,直角更收敛)。
            radius: 0
            height: 52
            blurSource: video
            rimMask: Qt.vector4d(0, 0, 1, 0) // 只留下沿(上/左/右顶窗框不发光)

            // 吞点击与滚轮防穿透(同底栏)。
            MouseArea { anchors.fill: parent; onWheel: (w) => w.accepted = true }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 14
                spacing: 4

                IconBtn {
                    Layout.alignment: Qt.AlignVCenter
                    icon.source: "qrc:/icons/chevron-left.svg"
                    icon.width: 22
                    icon.height: 22
                    tip: "返回"
                    onClicked: root.goBack()
                }
                Column {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.fillWidth: true   // 吃满剩余宽,左贴返回钮(不定宽居中假象)
                    spacing: 1
                    AppText {
                        text: root.titleMain
                        color: "white"
                        font.pixelSize: 15
                        font.weight: Font.Medium
                        elide: Text.ElideRight
                        width: parent.width
                    }
                    AppText {
                        text: root.titleSub
                        color: Qt.rgba(1, 1, 1, 0.65)
                        font.pixelSize: 12
                        elide: Text.ElideRight
                        width: parent.width
                        visible: text !== ""
                    }
                }
            }
        }

        // 底部控制条:PC 惯例 = 贴边全宽,不浮空。左右下零边距,
        // 直角(非胶囊),顶部 1px 发丝线收形。
        FrostedGlass {
            id: bottomBar
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            radius: 0
            height: barCol.implicitHeight + 20
            blurSource: video
            rimMask: Qt.vector4d(1, 0, 0, 0) // 只留上沿
            // FrostedGlass 是 Item 系(无 hovered);悬停钉住控制层用
            // HoverHandler 采集。
            HoverHandler { id: barHover }
            // 吞掉落在条上的点击与滚轮(防穿透到下层 inputArea 触发
            // 暂停/全屏/音量;面板内列表的滚动由 ListView 自身优先处理)。
            MouseArea { anchors.fill: parent; onWheel: (w) => w.accepted = true }

            Column {
                id: barCol
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 14
                // 进度条上方留白(全屏贴边时不再顶着视频)+ 行距拉开。
                anchors.topMargin: 14
                anchors.bottomMargin: 10
                spacing: 8

                // 进度条:拖动预览、松手 seek;hover 显示目标时间气泡。
                Slider {
                    id: seekBar
                    width: barCol.width
                    from: 0
                    to: Math.max(1, video.duration)
                    // 拖动中显示拖动值;否则跟随播放位置(Binding 门控,
                    // 避免 value 自引用绑定环)。
                    property bool scrubbing: false
                    Binding on value { when: !seekBar.scrubbing; value: video.position }
                    live: false
                    onPressedChanged: {
                        if (pressed) {
                            scrubbing = true
                        } else {
                            // 松手落点过磁吸(与 hover 预览一致)。
                            const target = root.snapChapter(value)
                            MpvClient.seek(target >= 0 ? target : value, root.sessionKey)
                            scrubbing = false
                        }
                    }
                    onValueChanged: if (scrubbing) root.wake()
                    // hover 位置(0..1)与对应时间:预览气泡与提示共用。
                    property real hoverFrac: -1
                    HoverHandler {
                        id: seekHover
                        onPointChanged: seekBar.hoverFrac = Math.max(0, Math.min(1, point.position.x / seekBar.width))
                        onHoveredChanged: if (!hovered) seekBar.hoverFrac = -1
                    }
                    // hover/拖动目标时间(气泡与预览共用;章节磁吸)。
                    property real rawTime: scrubbing ? value
                                           : (hoverFrac >= 0 ? hoverFrac * to : value)
                    property real snappedTime: root.snapChapter(rawTime)
                    property real hoverTime: snappedTime >= 0 ? snappedTime : rawTime
                    background: Rectangle {
                        implicitHeight: 4
                        radius: 2
                        color: Qt.rgba(1, 1, 1, 0.22)
                        // 缓存带(demuxer-cache-state;进度条下层)。
                        Rectangle {
                            width: seekBar.to > 0
                                   ? Math.min(1, video.buffered / seekBar.to) * parent.width : 0
                            height: parent.height
                            radius: 2
                            color: Qt.rgba(1, 1, 1, 0.38)
                        }
                        Rectangle {
                            width: seekBar.visualPosition * parent.width
                            height: parent.height
                            radius: 2
                            color: "white"
                        }
                        // 章节刻度(mpv chapter-list;白点压槽)。
                        Repeater {
                            model: root.chapters
                            Rectangle {
                                required property var modelData
                                // 吸附该章节时点亮(放大提亮)。
                                property bool snapped: seekBar.snappedTime === modelData.time
                                width: snapped ? 5 : 3
                                height: snapped ? 5 : 3
                                radius: 3
                                color: snapped ? "white" : Qt.rgba(1, 1, 1, 0.65)
                                // 销毁期 parent 可能先走(Repeater 拆委托),
                                // 用 y 绑定容忍 null,不用 anchors(垂直居中)。
                                y: parent ? Math.round((parent.height - height) / 2) : 0
                                x: seekBar.to > 0 ? (modelData.time / seekBar.to) * seekBar.width - width / 2 : 0
                                visible: seekBar.to > 0
                            }
                        }
                    }
                    handle: Rectangle {
                        x: seekBar.visualPosition * (seekBar.availableWidth - width)
                        anchors.verticalCenter: parent.verticalCenter
                        width: seekBar.hovered || seekBar.scrubbing ? 14 : 10
                        height: width
                        radius: width / 2
                        color: "white"
                        Behavior on width { NumberAnimation { duration: 120 } }
                    }

                    // hover 气泡:预览实例可用 = 大泡(画面+时间),否则 =
                    // 小时间泡;x 跟随鼠标位置并钳制在条内。
                    Rectangle {
                        id: previewBubble
                        width: previewLoader.active ? 176 : timeText.implicitWidth + 20
                        height: previewLoader.active ? 112 : timeText.implicitHeight + 12
                        radius: 8
                        color: previewLoader.active ? "black" : Qt.rgba(0, 0, 0, 0.75)
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.25)
                        visible: seekBar.hovered || seekBar.scrubbing
                        anchors.bottom: parent.top
                        anchors.bottomMargin: 8
                        x: Math.max(0, Math.min(seekBar.width - width,
                                (seekBar.hoverTime / seekBar.to) * seekBar.width - width / 2))
                        clip: true
                        Behavior on width { NumberAnimation { duration: 120 } }
                        Behavior on height { NumberAnimation { duration: 120 } }

                        Loader {
                            id: previewLoader
                            anchors.fill: parent
                            anchors.margins: 3
                            // 仅 hover 且有播放地址时建立预览实例。
                            active: (seekBar.hovered || seekBar.scrubbing)
                                    && (MpvClient.previewInfo(root.sessionKey).url || "") !== ""
                            sourceComponent: MpvVideoItem { id: previewVideo }
                            onLoaded: {
                                const info = MpvClient.previewInfo(root.sessionKey)
                                if (info.headers && info.headers.length > 0)
                                    item.sendCommand(["set_property", "http-header-fields", info.headers.join(",")])
                                item.sendCommand(["set_property", "mute", true])
                                item.sendCommand(["set_property", "pause", true])
                                item.sendCommand(["loadfile", info.url, "replace"])
                            }
                        }
                        AppText {
                            id: timeText
                            anchors.horizontalCenter: parent.horizontalCenter
                            // 大泡压底、小泡垂直居中(纯 y,不与 anchors 混用)。
                            y: previewLoader.active
                               ? parent.height - height - 4
                               : Math.round((parent.height - height) / 2)
                            text: root.fmtTime(seekBar.hoverTime)
                            color: "white"
                            font.pixelSize: 12
                            style: previewLoader.active ? Text.Outline : Text.Normal
                            styleColor: "black"
                        }
                    }
                    // hover/拖动位置变化 → 预览实例跟随 seek(节流 120ms)。
                    property real lastPreviewSeek: -1
                    Timer {
                        id: previewSeekTimer
                        interval: 120
                        onTriggered: {
                            if (!previewLoader.item)
                                return
                            const t = seekBar.scrubbing ? seekBar.value
                                      : (seekBar.hoverFrac >= 0 ? seekBar.hoverFrac * seekBar.to : -1)
                            if (t >= 0 && Math.abs(t - seekBar.lastPreviewSeek) > 0.5) {
                                seekBar.lastPreviewSeek = t
                                previewLoader.item.sendCommand(["seek", t, "absolute"])
                            }
                        }
                    }
                    onHoverFracChanged: if (hoverFrac >= 0) previewSeekTimer.restart()
                    onScrubbingChanged: if (scrubbing) previewSeekTimer.restart()
                }

                RowLayout {
                    width: barCol.width
                    spacing: 2

                    IconBtn {                        icon.source: "qrc:/icons/prev.svg"
                        icon.color: "white"
                        icon.width: 20
                        icon.height: 20
                        onClicked: root.episodeJump(-1)
 tip: "上一集"
                    }
                    IconBtn {
                        icon.source: video.paused ? "qrc:/icons/play.svg" : "qrc:/icons/pause.svg"
                        icon.width: 22
                        icon.height: 22
                        tip: video.paused ? "播放" : "暂停"
                        onClicked: root.togglePause()
                    }
                    IconBtn {                        icon.source: "qrc:/icons/next.svg"
                        icon.color: "white"
                        icon.width: 20
                        icon.height: 20
                        onClicked: root.episodeJump(1)
 tip: "下一集"
                    }
                    // 音量:图标(静音切换)+ 滑条。
                    IconBtn {                        id: volBtn
                        icon.source: video.volume <= 0 ? "qrc:/icons/mute.svg" : "qrc:/icons/volume.svg"
                        icon.color: "white"
                        icon.width: 20
                        icon.height: 20
                        onClicked: MpvClient.command(["cycle", "mute"], root.sessionKey)
 tip: "静音"
                    }
                    Slider {
                        id: volSlider
                        Layout.alignment: Qt.AlignVCenter
                        width: 80
                        from: 0
                        to: 100
                        property bool held: false
                        Binding on value { when: !volSlider.held; value: video.volume }
                        onPressedChanged: held = pressed
                        onMoved: MpvClient.setVolume(Math.round(value), root.sessionKey)
                        background: Rectangle {
                            implicitHeight: 3
                            radius: 2
                            color: Qt.rgba(1, 1, 1, 0.22)
                            Rectangle {
                                width: volSlider.visualPosition * parent.width
                                height: parent.height
                                radius: 2
                                color: "white"
                            }
                        }
                        handle: Rectangle {
                            x: volSlider.visualPosition * (volSlider.availableWidth - width)
                            anchors.verticalCenter: parent.verticalCenter
                            width: 10
                            height: 10
                            radius: 5
                            color: "white"
                        }
                    }
                    AppText {
                        Layout.alignment: Qt.AlignVCenter
                        text: root.fmtTime(video.position) + " / " + root.fmtTime(video.duration)
                        color: Qt.rgba(1, 1, 1, 0.85)
                        font.pixelSize: 12
                        leftPadding: 8
                    }
                    Item { Layout.fillWidth: true } // 弹性占位:右侧按钮推右
                    // 倍速(循环档位)。
                    IconBtn {
                        id: speedBtn
                        text: (Math.round(video.speed * 100) / 100) + "x"
                        contentItem: AppText {
                            text: speedBtn.text
                            color: "white"
                            font.pixelSize: 16
                            font.weight: Font.Medium
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        onClicked: root.cycleSpeed()
                        tip: "倍速(点击循环)"
                    }
                    IconBtn {
                        icon.source: "qrc:/icons/audio.svg"
                        tip: "音轨"
                        onClicked: {
                            root.panel = root.panel === "audio" ? "" : "audio"
                            if (root.panel === "audio")
                                MpvClient.refreshTracks(root.sessionKey)
                            root.wake()
                        }
                    }
                    IconBtn {
                        icon.source: "qrc:/icons/subtitle.svg"
                        tip: "字幕"
                        onClicked: {
                            root.panel = root.panel === "sub" ? "" : "sub"
                            if (root.panel === "sub")
                                MpvClient.refreshTracks(root.sessionKey)
                            root.wake()
                        }
                    }
                    // 选集(仅剧集有播放列表)/ 音轨 / 字幕:三个图标钮,
                    // 面板互斥。
                    IconBtn {
                        visible: (root.meta.seriesId || "") !== ""
                        icon.source: "qrc:/icons/episodes.svg"
                        tip: "选集"
                        onClicked: {
                            root.panel = root.panel === "episodes" ? "" : "episodes"
                            root.wake()
                        }
                    }
                    IconBtn {
                        icon.source: "qrc:/icons/fullscreen.svg"
                        tip: "全屏"
                        onClicked: root.toggleFullscreen()
                    }
                }
            }
        }
    }

    // 弹性占位:把右侧按钮推到底栏右缘(Row 布局占位)。
    // (Row 内用 Item{Layout} 需 Layouts;此处用空白 Item 加宽即推挤。)

    // ---- 右侧面板(选集 / 轨道;玻璃,压在控制层上)----
    FrostedGlass {
        id: sidePanel
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: bottomBar.height + 8
        anchors.rightMargin: 16
        width: 320
        height: Math.min(parent.height * 0.6, 420)
        radius: 14
        blurSource: video
        visible: root.panel !== "" && root.chromeVisible

        // 吞点击与滚轮防穿透。
        MouseArea { anchors.fill: parent; onWheel: (w) => w.accepted = true }

        Column {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8

            AppText {
                text: root.panel === "episodes" ? "选集"
                      : (root.panel === "audio" ? "音轨" : "字幕")
                color: "white"
                font.pixelSize: 14
                font.weight: Font.Medium
            }

            // 选集:全集列表(allEpisodes 模型;旋转序直跳经 MpvClient)。
            ListView {
                id: epList
                visible: root.panel === "episodes"
                width: parent.width
                height: parent.height - 30
                clip: true
                model: root.panel === "episodes" && (root.meta.serverUrl || "") !== ""
                       ? EmbyClient.allEpisodesModelFor(root.meta.serverUrl, root.meta.accountId || "", root.meta.seriesId || "") : null
                delegate: Rectangle {
                    required property int index
                    width: epList.width
                    height: 40
                    radius: 8
                    color: delMa.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
                    property var ep: epList.model ? epList.model.itemAt(index) : null
                    property bool playing: ep && ep.id === root.currentItemId
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 8
                        AppText {
                            Layout.alignment: Qt.AlignVCenter
                            text: ep ? ("S" + (ep.seasonNo || 0) + "E" + (ep.episodeNo || 0)) : ""
                            color: playing ? "white" : Qt.rgba(1, 1, 1, 0.55)
                            font.pixelSize: 12
                        }
                        AppText {
                            Layout.alignment: Qt.AlignVCenter
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: ep ? (ep.name || "") : ""
                            color: "white"
                            font.pixelSize: 13
                            font.weight: playing ? Font.Medium : Font.Normal
                        }
                    }
                    Rectangle {
                        anchors.fill: parent
                        radius: 8
                        color: "transparent"
                        border.width: playing ? 1 : 0
                        border.color: "white"
                        opacity: 0.8
                    }
                    MouseArea {
                        id: delMa
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            if (ep && ep.id)
                                MpvClient.playEpisode(root.sessionKey, ep.id)
                        }
                    }
                }
            }

            // 轨道面板(音轨/字幕各自独立面板,同一份 tracks 按类过滤;
            // 首行恒为「关」)。
            ListView {
                id: trackList
                visible: root.panel === "audio" || root.panel === "sub"
                width: parent.width
                height: parent.height - 30
                clip: true
                model: {
                    const type = root.panel === "audio" ? "audio"
                                 : (root.panel === "sub" ? "sub" : "")
                    if (type === "")
                        return []
                    const rows = [{ "kind": "track", "label": "关闭", "id": -1, "type": type,
                                    "selected": !root.tracks.some(t => t.type === type && t.selected) }]
                    let n = 0
                    for (const t of root.tracks) {
                        if (t.type !== type)
                            continue
                        rows.push({ "kind": "track", "label": t.label || ("轨道 " + (++n)),
                                    "id": t.id, "type": type, "selected": t.selected })
                    }
                    return rows
                }
                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: trackList.width
                    height: modelData.kind === "head" ? 30 : 36
                    radius: 8
                    color: modelData.kind !== "head" && trkMa.containsMouse
                           ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
                    AppText {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        text: modelData.label
                        color: modelData.kind === "head"
                               ? Qt.rgba(1, 1, 1, 0.55)
                               : (modelData.selected ? "white" : Qt.rgba(1, 1, 1, 0.85))
                        font.pixelSize: modelData.kind === "head" ? 11 : 13
                        font.weight: modelData.selected ? Font.Medium : Font.Normal
                    }
                    AppText {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        visible: modelData.kind !== "head" && modelData.selected
                        text: "✓"
                        color: "white"
                        font.pixelSize: 13
                    }
                    MouseArea {
                        id: trkMa
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: modelData.kind !== "head"
                        onClicked: MpvClient.selectTrack(root.sessionKey, modelData.type, modelData.id)
                    }
                }
            }
        }
    }

    Timer {
        id: hideTimer
        interval: 3000
        // 控制条 hover / 拖动进度 / 面板打开 / 暂停时钉住不隐。
        onTriggered: {
            if (barHover.hovered || seekBar.scrubbing || root.panel !== "" || video.paused)
                restart()
            else
                root.chromeVisible = false
        }
    }
    Component.onDestruction: hideTimer.stop()

    // ---- OSD(轻量文本,顶部左上;mpv show-text 画进画面,此处只补
    // 音量/倍速这类 QML 侧发起的反馈)----
    Rectangle {
        id: osd
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: 24
        anchors.topMargin: 84
        visible: false
        radius: 8
        color: Qt.rgba(0, 0, 0, 0.55)
        width: osdText.implicitWidth + 16
        height: osdText.implicitHeight + 12
        property alias text: osdText.text
        function showText(t) {
            text = t
            visible = true
            osdTimer.restart()
        }
        function showVolume(v) {
            showText("音量 " + v + "%")
        }
        AppText {
            id: osdText
            anchors.centerIn: parent
            color: "white"
            font.pixelSize: 14
        }
        Timer {
            id: osdTimer
            interval: 1200
            onTriggered: osd.visible = false
        }
    }

    // ---- 键盘(mpv/通用播放器约定)----
    Shortcut { sequences: ["Space", "K"]; onActivated: root.togglePause() }
    Shortcut { sequences: ["Esc"]; onActivated: root.goBack() }
    Shortcut { sequences: ["Left"]; onActivated: { root.wake(); root.seekBy(-5) } }
    Shortcut { sequences: ["Right"]; onActivated: { root.wake(); root.seekBy(5) } }
    Shortcut { sequences: ["Shift+Left"]; onActivated: { root.wake(); root.seekBy(-30) } }
    Shortcut { sequences: ["Shift+Right"]; onActivated: { root.wake(); root.seekBy(30) } }
    Shortcut { sequences: ["Up"]; onActivated: root.adjustVolume(5) }
    Shortcut { sequences: ["Down"]; onActivated: root.adjustVolume(-5) }
    Shortcut { sequences: ["M"]; onActivated: MpvClient.command(["cycle", "mute"], root.sessionKey) }
    Shortcut { sequences: ["F"]; onActivated: root.toggleFullscreen() }
    Shortcut { sequences: ["N"]; onActivated: root.episodeJump(1) }
    Shortcut { sequences: ["P"]; onActivated: root.episodeJump(-1) }
}
