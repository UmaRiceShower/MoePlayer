import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import MoePlayer.Core

//! 内嵌播放窗:libmpv 视频表面 + QML 控制层(主题玻璃控制条)。
//! Main 在 embeddedPlaybackRequested 时 createObject 新建一个顶层窗口;
//! 每次播放 = 一个独立窗口,允许多窗并发(同集去重在 MpvClient 会话键)。
//! 关窗 = 停播(回传 Stopped);播完自动关窗。Esc 仅时间编辑态取消输入。
Window {
    id: root

    // Main 建窗时注入(含 itemId/serverUrl/seriesId/displayName/seriesName)。
    property var meta: ({})

    visible: true
    width: 1280
    // 最小尺寸:控制层(进度条+按钮行)的可用下限
    minimumWidth: 480
    minimumHeight: 360
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
    // 右侧面板:"" | "episodes" | "audio" | "sub"(互斥,开新收旧)。
    property string panel: ""
    // 轨道列表(MpvClient.tracksChanged 喂;file-loaded 后 refreshTracks)。
    property var tracks: []
    // 章节表(MpvClient.chaptersChanged 喂;[{time,title}],进度条刻度)。
    property var chapters: []
    // 时长显示形态:false = 总时长,true = 剩余(负号),点击切换。
    property bool showRemaining: false
    // 唤出侧面板的按钮(面板右缘对齐其右缘);关面板清空。
    property var panelAnchor: null

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
    // closeSelf 幂等:未起播/协商失败时 stop 不发信号,补自关防窗口泄漏。
    onClosing: {
        MpvClient.stop(root.sessionKey)
        closeSelf()
    }

    function togglePause() {
        MpvClient.command(["osd-auto", "cycle", "pause"], root.sessionKey)
    }
    function seekBy(delta) {
        MpvClient.command(["osd-msg", "seek", delta, "relative"], root.sessionKey)
    }
    function adjustVolume(delta) {
        const v = Math.max(0, Math.min(100, Math.round(video.volume + delta)))
        MpvClient.command(["osd-auto", "set", "volume", String(v)], root.sessionKey)
    }
    function toggleFullscreen() {
        // 本窗独立全屏(主窗不受影响)。
        root.visibility = root.visibility === Window.FullScreen
                          ? Window.Windowed : Window.FullScreen
    }
    // 倍速档位循环(常用档,mpv 侧持久到换集)。
    property real _prevSpeed: 1.0
    function cycleSpeed() {
        const speeds = [1.0, 1.25, 1.5, 2.0, 0.5]
        let i = speeds.findIndex(s => Math.abs(s - video.speed) < 0.01)
        const next = speeds[(i + 1) % speeds.length]
        _prevSpeed = video.speed
        MpvClient.command(["osd-auto", "set", "speed", String(next)], root.sessionKey)
    }
    function episodeJump(delta) {
        // 播放列表跳集:占位条目经 on_load hook 协商真实地址(连播链路)。
        // 会话键必须带账号前缀(与所有控制调用一致),裸 itemId 查无会话。
        MpvClient.command([delta > 0 ? "playlist-next" : "playlist-prev"],
                          root.sessionKey)
    }

    // 章节磁吸:距章节点阈值内即吸附(返回章节时间;无 = -1)。
    function snapChapter(t, barW) {
        if (!barW || video.duration <= 0)
            return -1
        const th = 10 / barW * video.duration
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

    // 解析 "ss" / "m:ss" / "h:mm:ss"(允许小数秒);非法返回 -1。
    function parseTime(str) {
        const parts = (str || "").trim().split(":")
        if (parts.length < 1 || parts.length > 3)
            return -1
        let t = 0
        for (const p of parts) {
            const n = parseFloat(p)
            if (isNaN(n) || n < 0 || (t > 0 && n >= 60) || (t === 0 && parts.length > 1 && n >= 60 && parts.length < 3))
                return -1
            t = t * 60 + n
        }
        return t
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

    // 输入层:单击=播放/暂停,双击=全屏,滚轮=音量,移动=唤醒。
    MouseArea {
        id: inputArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.BackButton | Qt.ForwardButton
        cursorShape: root.chromeVisible ? Qt.ArrowCursor : Qt.BlankCursor
        onPositionChanged: root.wake()
        onPressed: (mouse) => {
            if (mouse.button === Qt.BackButton)
                root.episodeJump(-1)
            else if (mouse.button === Qt.ForwardButton)
                root.episodeJump(1)
        }
        onWheel: (wheel) => {
            root.wake()
            root.adjustVolume(wheel.angleDelta.y > 0 ? 5 : -5)
        }
        property bool _clickToggled: false
        onClicked: {
            // 面板开着:点视频区 = 收面板(不换暂停态),符合"点空白处关闭"。
            if (root.panel !== "") {
                root.panel = ""
                _clickToggled = false
                return
            }
            root.togglePause()
            _clickToggled = true
        }
        onDoubleClicked: {
            if (_clickToggled)
                root.togglePause() // 撤销单击的切换,暂停态净不变
            _clickToggled = false
            root.toggleFullscreen()
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

    // ---- 控制层(自动隐藏)----
    Item {
        id: chrome
        anchors.fill: parent
        opacity: root.chromeVisible ? 1 : 0
        // 隐藏时不挡输入(鼠标事件穿透到 inputArea)。
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 250 } }

        // 底部控制条:渐变压暗罩(下深上透),控件直接坐在罩上,
        // 无硬边分割;罩略高于内容留出渐变过渡带。
        Item {
            id: bottomBar
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: barCol.implicitHeight + 34

            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 0.35; color: Qt.rgba(0, 0, 0, 0.28) }
                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.60) }
                }
            }

            // 悬停钉住控制层用 HoverHandler 采集。
            HoverHandler { id: barHover }
            // 吞掉落在条上的点击与滚轮(防穿透到下层 inputArea 触发
            // 暂停/全屏/音量;面板内列表的滚动由 ListView 自身优先处理)。
            MouseArea { anchors.fill: parent; onWheel: (w) => w.accepted = true }

            Column {
                id: barCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: 14
                anchors.rightMargin: 14
                anchors.bottomMargin: 10
                spacing: 8

                // 标题行:主标 · 副标
                AppText {
                    width: barCol.width
                    text: root.titleSub !== "" ? root.titleMain + "  ·  " + root.titleSub
                                               : root.titleMain
                    color: "white"
                    font.pixelSize: 15
                    font.weight: Font.Medium
                    elide: Text.ElideRight
                }

                // 进度条行:左侧「当前 / 总时长」,右侧进度条(拖动预览、
                // 松手 seek;hover 显示目标时间气泡)。
                RowLayout {
                    width: barCol.width
                    spacing: 10

                    Row {
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 4
                        Item {
                            anchors.verticalCenter: parent.verticalCenter
                            width: posEdit.visible ? posEdit.width : posLabel.implicitWidth
                            // 高度锁标签行高:编辑态输入框不顶高进度条行。
                            height: posLabel.implicitHeight
                            AppText {
                                id: posLabel
                                anchors.verticalCenter: parent.verticalCenter
                                visible: !posEdit.visible
                                text: root.fmtTime(video.position)
                                color: posHover.hovered ? "white" : Qt.rgba(1, 1, 1, 0.85)
                                font.pixelSize: 12
                                // 双击进入编辑:预填当前位置,Enter 确认跳转,
                                // Esc/失焦取消;超出总时长按取消处理。
                                TapHandler {
                                    onDoubleTapped: {
                                        posEdit.text = root.fmtTime(video.position)
                                        posEdit.visible = true
                                        posEdit.forceActiveFocus()
                                        posEdit.selectAll()
                                        root.wake()
                                    }
                                }
                                HoverHandler { id: posHover; cursorShape: Qt.PointingHandCursor }
                            }
                            TextField {
                                id: posEdit
                                anchors.verticalCenter: parent.verticalCenter
                                visible: false
                                width: 88
                                height: posLabel.implicitHeight + 6
                                padding: 0
                                horizontalAlignment: Text.AlignHCenter
                                color: "white"
                                font.pixelSize: 12
                                selectionColor: Qt.rgba(1, 1, 1, 0.3)
                                validator: RegularExpressionValidator { regularExpression: /[0-9:.]*/ }
                                onTextChanged: root.wake()
                                background: Rectangle {
                                    color: Qt.rgba(1, 1, 1, 0.12)
                                    radius: 4
                                }
                                onAccepted: {
                                    const t = root.parseTime(text)
                                    visible = false
                                    if (t >= 0 && t <= video.duration)
                                        MpvClient.seek(t, root.sessionKey)
                                    root.wake()
                                }
                                Keys.onShortcutOverride: (e) => e.accepted = true
                                Keys.onEscapePressed: (e) => {
                                    e.accepted = true
                                    visible = false
                                }
                                onActiveFocusChanged: if (!activeFocus)
                                    visible = false
                            }
                        }
                        AppText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "/"
                            color: Qt.rgba(1, 1, 1, 0.85)
                            font.pixelSize: 12
                        }
                        AppText {
                            anchors.verticalCenter: parent.verticalCenter
                            // 总时长 ⇄ 剩余(负号)两形态,点击切换。
                            text: root.showRemaining
                                  ? "-" + root.fmtTime(Math.max(0, video.duration - video.position))
                                  : root.fmtTime(video.duration)
                            color: durHover.hovered ? "white" : Qt.rgba(1, 1, 1, 0.85)
                            font.pixelSize: 12
                            TapHandler { onTapped: root.showRemaining = !root.showRemaining }
                            HoverHandler { id: durHover; cursorShape: Qt.PointingHandCursor }
                        }
                    }

                    Slider {
                        id: seekBar
                        Layout.fillWidth: true
                        from: 0
                        to: Math.max(1, video.duration)
                        // 拖动中显示拖动值;否则跟随播放位置(Binding 门控,
                        // 避免 value 自引用绑定环)。
                        property bool scrubbing: false
                        property real _pressPos: -1
                        property bool _dragSeen: false
                        Binding on value { when: !seekBar.scrubbing; value: video.position }
                        live: false
                        onPressedChanged: {
                            if (pressed) {
                                _pressPos = -1
                                _dragSeen = false
                                scrubbing = true
                            } else {
                                const target = _dragSeen ? root.snapChapter(value, width) : -1
                                MpvClient.seek(target >= 0 ? target : value, root.sessionKey)
                                scrubbing = false
                            }
                        }
                        onPositionChanged: {
                            if (!pressed)
                                return
                            if (_pressPos < 0)
                                _pressPos = position
                            else if (Math.abs(position - _pressPos) * width > 4)
                                _dragSeen = true
                            previewSeekTimer.restart()   // 拖动期预览帧跟随
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
                        property real rawTime: scrubbing ? position * to
                                            : (hoverFrac >= 0 ? hoverFrac * to : value)
                        property real snappedTime: root.snapChapter(rawTime, width)
                        // 气泡/预览时间 = 实际操作结果:悬停(点按将精确落点)
                        // 显示指针时间;拖动松手会磁吸,显示吸附后时间。
                        property real hoverTime: (scrubbing && snappedTime >= 0) ? snappedTime : rawTime
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
                                property bool _keep: false
                                property string _loadedUrl: ""
                                active: ((seekBar.hovered || seekBar.scrubbing) || previewLoader._keep)
                                        && (MpvClient.previewInfo(root.sessionKey).url || "") !== ""
                                sourceComponent: MpvVideoItem { id: previewVideo }
                                // 换集后实例保活但内容过期:hover 时换到新集地址。
                                function reloadIfStale() {
                                    if (!item)
                                        return
                                    const info = MpvClient.previewInfo(root.sessionKey)
                                    if (info.url && info.url !== _loadedUrl) {
                                        item.sendCommand(["loadfile", info.url, "replace"])
                                        _loadedUrl = info.url
                                    }
                                }
                                onLoaded: {
                                    const info = MpvClient.previewInfo(root.sessionKey)
                                    // 与主视频/外部模式同口径:显式下发代理。
                                    item.sendCommand(["set_property", "http-proxy", ConfigManager.proxy || ""])
                                    if (info.headers && info.headers.length > 0)
                                        item.sendCommand(["set_property", "http-header-fields", info.headers.join(",")])
                                    item.sendCommand(["set_property", "mute", true])
                                    item.sendCommand(["set_property", "pause", true])
                                    item.sendCommand(["loadfile", info.url, "replace"])
                                    previewLoader._loadedUrl = info.url
                                    previewLoader._keep = true
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
                                previewLoader.reloadIfStale()
                                const t = seekBar.scrubbing ? seekBar.position * seekBar.to
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
                }

                RowLayout {
                    width: barCol.width
                    spacing: 2

                    IconBtn {
                        icon.source: "qrc:/icons/prev.svg"
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
                    IconBtn {
                        icon.source: "qrc:/icons/next.svg"
                        icon.color: "white"
                        icon.width: 20
                        icon.height: 20
                        onClicked: root.episodeJump(1)
                        tip: "下一集"
                    }
                    // 音量:图标(静音切换)+ 滑条。
                    IconBtn {
                        id: volBtn
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
                    Item { Layout.fillWidth: true } // 弹性占位:右侧按钮推右
                    // 倍速:单击循环档位;双击手动输入(0.01~32,越界/非法取消)。
                    IconBtn {
                        id: speedBtn
                        property bool editing: false
                        text: (Math.round(video.speed * 100) / 100) + "x"
                        contentItem: Item {
                            AppText {
                                id: speedLabel
                                anchors.centerIn: parent
                                visible: !speedBtn.editing
                                text: speedBtn.text
                                color: "white"
                                font.pixelSize: 16
                                font.weight: Font.Medium
                                TapHandler {
                                    onSingleTapped: if (!speedBtn.editing) root.cycleSpeed()
                                    onDoubleTapped: {
                                        MpvClient.command(["set_property", "speed", root._prevSpeed],
                                                          root.sessionKey)
                                        speedEdit.text = String(Math.round(root._prevSpeed * 100) / 100)
                                        speedBtn.editing = true
                                        speedEdit.forceActiveFocus()
                                        speedEdit.selectAll()
                                        root.wake()
                                    }
                                }
                            }
                            TextField {
                                id: speedEdit
                                anchors.centerIn: parent
                                visible: speedBtn.editing
                                width: 56
                                height: speedLabel.implicitHeight + 6
                                padding: 0
                                horizontalAlignment: Text.AlignHCenter
                                color: "white"
                                font.pixelSize: 14
                                selectionColor: Qt.rgba(1, 1, 1, 0.3)
                                validator: RegularExpressionValidator { regularExpression: /[0-9.]*/ }
                                onTextChanged: root.wake()
                                background: Rectangle {
                                    color: Qt.rgba(1, 1, 1, 0.12)
                                    radius: 4
                                }
                                onAccepted: {
                                    const v = parseFloat(text)
                                    speedBtn.editing = false
                                    if (!isNaN(v) && v >= 0.01 && v <= 32) {
                                        MpvClient.command(["osd-auto", "set", "speed", String(v)], root.sessionKey)
                                    }
                                    root.wake()
                                }
                                Keys.onShortcutOverride: (e) => e.accepted = true
                                Keys.onEscapePressed: (e) => {
                                    e.accepted = true
                                    speedBtn.editing = false
                                }
                                onActiveFocusChanged: if (!activeFocus)
                                    speedBtn.editing = false
                            }
                        }
                        tip: "倍速(单击循环,双击输入)"
                    }
                    IconBtn {
                        id: audioBtn
                        icon.source: "qrc:/icons/audio.svg"
                        tip: "音轨"
                        onClicked: {
                            root.panel = root.panel === "audio" ? "" : "audio"
                            root.panelAnchor = root.panel === "audio" ? audioBtn : null
                            if (root.panel === "audio")
                                MpvClient.refreshTracks(root.sessionKey)
                            root.wake()
                        }
                    }
                    IconBtn {
                        id: subBtn
                        icon.source: "qrc:/icons/subtitle.svg"
                        tip: "字幕"
                        onClicked: {
                            root.panel = root.panel === "sub" ? "" : "sub"
                            root.panelAnchor = root.panel === "sub" ? subBtn : null
                            if (root.panel === "sub")
                                MpvClient.refreshTracks(root.sessionKey)
                            root.wake()
                        }
                    }
                    IconBtn {
                        id: wandBtn
                        icon.source: "qrc:/icons/wand.svg"
                        tip: "超分(Anime4K)"
                        onClicked: {
                            root.panel = root.panel === "superres" ? "" : "superres"
                            root.panelAnchor = root.panel === "superres" ? wandBtn : null
                            root.wake()
                        }
                    }
                    // 选集仅剧集(有播放列表)可见;右簇功能钮面板互斥。
                    IconBtn {
                        id: epBtn
                        visible: (root.meta.seriesId || "") !== ""
                        icon.source: "qrc:/icons/episodes.svg"
                        tip: "选集"
                        onClicked: {
                            root.panel = root.panel === "episodes" ? "" : "episodes"
                            root.panelAnchor = root.panel === "episodes" ? epBtn : null
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

    // ---- 侧面板(选集 / 轨道 / 超分;玻璃,压在控制层上)----
    FrostedGlass {
        id: sidePanel
        anchors.bottom: parent.bottom
        anchors.bottomMargin: barCol.height - 15
        width: 320
        property int _rows: root.panel === "episodes" ? (epList.model ? epList.model.count : 0)
                : (root.panel === "superres" ? MpvClient.superResOptions().length
                   : ((root.panel === "audio" || root.panel === "sub") ? trackList.model.length : 0))
        property int _rowH: root.panel === "episodes" ? 40 : 36
        height: Math.min(root.height * 0.6, 420,
                22 + 8 + _rows * _rowH + (root.panel === "superres" ? 44 : 0) + 24)
        x: {
            const a = root.panelAnchor
            if (!a)
                return root.width - width - 16
            void (a.x + a.width)
            return Math.max(8, Math.min(root.width - width - 8,
                    a.mapToItem(null, a.width, 0).x - width))
        }
        radius: 14
        blurSource: video
        visible: root.panel !== "" && root.chromeVisible

        // 吞点击与滚轮防穿透。
        MouseArea { anchors.fill: parent; onWheel: (w) => w.accepted = true }

        Column {
            id: panelCol
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8

            AppText {
                text: root.panel === "episodes" ? "选集"
                      : (root.panel === "audio" ? "音轨"
                         : (root.panel === "sub" ? "字幕" : "超分(Anime4K)"))
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

            // 超分面板:Anime4K 档位(与设置页同一配置键,选中即全会话实时
            // 应用并持久化;mpv 内 CTRL+0..8 同键位见右列提示)。
            ListView {
                id: srList
                visible: root.panel === "superres"
                width: parent.width
                height: (parent.height - 30) - (srHint.visible ? 44 : 0)
                clip: true
                model: MpvClient.superResOptions()
                delegate: Rectangle {
                    required property var modelData
                    width: srList.width
                    height: 36
                    radius: 8
                    color: srMa.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
                    property bool current: ConfigManager.superRes === modelData.key
                    AppText {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        text: modelData.label
                        color: current ? "white" : Qt.rgba(1, 1, 1, 0.85)
                        font.pixelSize: 13
                        font.weight: current ? Font.Medium : Font.Normal
                    }
                    AppText {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        text: current ? "✓" : modelData.hotkey
                        color: current ? "white" : Qt.rgba(1, 1, 1, 0.4)
                        font.pixelSize: 12
                    }
                    MouseArea {
                        id: srMa
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            ConfigManager.superRes = modelData.key
                            root.wake()
                        }
                    }
                }
            }
            AppText {
                id: srHint
                visible: root.panel === "superres"
                width: parent.width
                text: "放大档需窗口大于片源 1.2 倍才生效"
                color: Qt.rgba(1, 1, 1, 0.5)
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }
        }
    }

    Timer {
        id: hideTimer
        interval: 3000
        // 控制条 hover / 拖动进度 / 面板打开 / 暂停 / 时间与倍速编辑中
        onTriggered: {
            if (barHover.hovered || seekBar.scrubbing || root.panel !== "" || video.paused || posEdit.visible || speedBtn.editing)
                restart()
            else
                root.chromeVisible = false
        }
    }
    Component.onDestruction: hideTimer.stop()

    // ---- 键盘 ----
    Shortcut { sequences: ["Space", "K", "P"]; onActivated: root.togglePause() }
    Shortcut { sequences: ["Left"]; onActivated: { root.wake(); root.seekBy(-5) } }
    Shortcut { sequences: ["Right"]; onActivated: { root.wake(); root.seekBy(5) } }
    Shortcut { sequences: ["Shift+Left"]; onActivated: { root.wake(); MpvClient.command(["no-osd", "seek", -1, "exact"], root.sessionKey) } }
    Shortcut { sequences: ["Shift+Right"]; onActivated: { root.wake(); MpvClient.command(["no-osd", "seek", 1, "exact"], root.sessionKey) } }
    Shortcut { sequences: ["Up"]; onActivated: root.adjustVolume(5) }
    Shortcut { sequences: ["Down"]; onActivated: root.adjustVolume(-5) }
    Shortcut { sequences: ["0", "Shift+*", "Shift+8"]; onActivated: root.adjustVolume(2) }
    Shortcut { sequences: ["9", "/"]; onActivated: root.adjustVolume(-2) }
    Shortcut { sequences: ["M"]; onActivated: MpvClient.command(["osd-auto", "cycle", "mute"], root.sessionKey) }
    Shortcut { sequences: ["F"]; onActivated: root.toggleFullscreen() }
    Shortcut { sequences: [">", "Return", "Shift+>", "Shift+."]; onActivated: root.episodeJump(1) }
    Shortcut { sequences: ["<", "Shift+<", "Shift+,"]; onActivated: root.episodeJump(-1) }
    Shortcut { sequences: ["Esc"]; onActivated: {
        if (root.visibility === Window.FullScreen)
            root.toggleFullscreen()
        } 
    }
    // 媒体键
    Shortcut { sequences: ["Media Play"]; onActivated: MpvClient.setPause(false, root.sessionKey) }
    Shortcut { sequences: ["Media Pause"]; onActivated: MpvClient.setPause(true, root.sessionKey) }
    Shortcut { sequences: ["Media Next"]; onActivated: root.episodeJump(1) }
    Shortcut { sequences: ["Media Previous"]; onActivated: root.episodeJump(-1) }
    Shortcut { sequences: ["Volume Up"]; onActivated: root.adjustVolume(2) }
    Shortcut { sequences: ["Volume Down"]; onActivated: root.adjustVolume(-2) }
    Shortcut { sequences: ["Volume Mute"]; onActivated: MpvClient.command(["osd-auto", "cycle", "mute"], root.sessionKey) }
    // 超分档位热键
    Instantiator {
        model: MpvClient.superResOptions()
        delegate: Shortcut {
            required property var modelData
            sequence: modelData.hotkey
            onActivated: ConfigManager.setValue("superRes", modelData.key)
        }
    }
    // 其余 mpv 默认键位:[键序列数组] → mpv 命令数组,批量注册。
    // 移位标点(!@#?{}_*<>等)绑两种带 Shift 的形态:"Shift+符号" 与
    // "Shift+基础键"——按键事件给哪种(移位后符号键码+Shift,或基础键
    // +Shift)随平台/布局不定;裸符号序列不可达(该符号本就须按 Shift
    // 才能输入,事件恒带 Shift 修饰)。
    readonly property var mpvKeys: [
        // 帧步进 / 倍速(mpv: [ ] { } BS)
        [["."], ["frame-step"]], [[","], ["frame-back-step"]],
        [["["], ["multiply", "speed", 0.9091]], [["]"], ["multiply", "speed", 1.1]],
        [["Shift+{", "Shift+["], ["multiply", "speed", 0.5]],
        [["Shift+}", "Shift+]"], ["multiply", "speed", 2.0]],
        [["Backspace"], ["set", "speed", "1.0"]],
        [["Shift+Backspace"], ["osd-msg", "revert-seek"]],
        [["Ctrl+Shift+Backspace"], ["osd-msg", "revert-seek", "mark"]],
        // 章节 / 长跳 / 回开头
        [["PgUp"], ["add", "chapter", 1]], [["PgDown"], ["add", "chapter", -1]],
        [["Shift+!", "Shift+1"], ["add", "chapter", -1]],
        [["Shift+@", "Shift+2"], ["add", "chapter", 1]],
        [["Shift+Up"], ["no-osd", "seek", 5, "exact"]],
        [["Shift+Down"], ["no-osd", "seek", -5, "exact"]],
        [["Ctrl+Left"], ["no-osd", "sub-seek", -1]],
        [["Ctrl+Right"], ["no-osd", "sub-seek", 1]],
        [["Ctrl+Shift+Left"], ["sub-step", -1]],
        [["Ctrl+Shift+Right"], ["sub-step", 1]],
        [["Shift+PgUp"], ["osd-msg", "seek", 600, "relative"]],
        [["Shift+PgDown"], ["osd-msg", "seek", -600, "relative"]],
        [["Home"], ["osd-msg", "seek", 0, "absolute"]],
        // 进度 OSD / 统计 / 控制台
        [["O"], ["show-progress"]], [["Shift+P"], ["show-progress"]],
        [["Shift+O"], ["cycle-values", "osd-level", "3", "1"]],
        [["I"], ["script-binding", "stats/display-stats"]],
        [["Shift+I"], ["script-binding", "stats/display-stats-toggle"]],
        [["Shift+?", "Shift+/"], ["script-binding", "stats/display-page-4-toggle"]],
        // 字幕:延迟 / 字号 / 位置 / 可见性 / 切轨
        [["Z"], ["add", "sub-delay", -0.1]], [["X"], ["add", "sub-delay", 0.1]],
        [["Shift+Z"], ["add", "sub-delay", 0.1]],
        [["Ctrl++", "Ctrl+Shift++", "Ctrl+Shift+="], ["add", "audio-delay", 0.1]],
        [["Ctrl+-"], ["add", "audio-delay", -0.1]],
        [["Shift+G"], ["add", "sub-scale", 0.1]], [["Shift+F"], ["add", "sub-scale", -0.1]],
        [["R"], ["add", "sub-pos", -1]], [["Shift+R"], ["add", "sub-pos", 1]],
        [["T"], ["add", "sub-pos", 1]],
        [["V"], ["cycle", "sub-visibility"]],
        [["Alt+V"], ["cycle", "secondary-sub-visibility"]],
        [["Shift+V"], ["cycle", "sub-ass-use-video-data"]],
        [["U"], ["cycle-values", "sub-ass-override", "force", "scale"]],
        [["J"], ["cycle", "sub"]], [["Shift+J"], ["cycle", "sub", "down"]],
        // 轨道切换(mpv: # = 音轨,_ = 视频轨)
        [["Shift+#", "Shift+3"], ["cycle", "audio"]],
        [["Shift+_", "Shift+-"], ["cycle", "video"]],
        // 画面微调(mpv: 1-8 对比/亮度/伽马/饱和)
        [["1"], ["add", "contrast", -1]], [["2"], ["add", "contrast", 1]],
        [["3"], ["add", "brightness", -1]], [["4"], ["add", "brightness", 1]],
        [["5"], ["add", "gamma", -1]], [["6"], ["add", "gamma", 1]],
        [["7"], ["add", "saturation", -1]], [["8"], ["add", "saturation", 1]],
        // 去带 / 反交错 / 硬解切换 / panscan / 宽高比 / edition
        [["B"], ["cycle", "deband"]], [["D"], ["cycle", "deinterlace"]],
        [["Ctrl+H"], ["cycle-values", "hwdec", "no", "auto"]],
        [["W"], ["add", "panscan", -0.1]], [["Shift+W"], ["add", "panscan", 0.1]],
        [["E"], ["add", "panscan", 0.1]],
        [["Shift+A"], ["cycle-values", "video-aspect-override", "16:9", "4:3", "2.35:1", "no"]],
        [["Shift+E"], ["cycle", "edition"]],
        // 截图(mpv: s 全画面 / S 仅视频 / Ctrl+s 含窗口 / Alt+s 逐帧开关)
        [["S"], ["screenshot"]], [["Shift+S"], ["screenshot", "video"]],
        [["Ctrl+S"], ["screenshot", "window"]], [["Alt+S"], ["screenshot", "each-frame"]],
        // AB 循环 / 单集循环 / 窗口置顶
        [["L"], ["ab-loop"]], [["Shift+L"], ["cycle-values", "loop-file", "inf", "no"]],
        [["Shift+T"], ["cycle", "ontop"]],
        // 播放列表 / 轨道列表 OSD(show-text 自带属性展开)
        [["F8"], ["show-text", "${playlist}"]], [["F9"], ["show-text", "${track-list}"]]
    ]
    // 命令前缀表:IPC/脚本 API 默认 no-osd(input.conf 键位默认 osd-auto,
    // 见 mpv input.rst 命令前缀节)——转发时统一补 osd-auto 还原键位行为的
    // OSD 提示(速度/音量/延迟等以 mpv 原生格式画进视频帧);表里已带前缀的
    // (no-osd/show-text 等)原样放行。get_property/set_property 是内嵌侧
    // 特判命令、不认识前缀,故不前置(osd-auto 对它们本就只影响应答)。
    readonly property var cmdPrefixes: ["osd-auto", "no-osd", "osd-msg", "osd-bar",
        "osd-msg-bar", "raw", "expand-properties", "repeatable", "nonrepeatable",
        "nonscalable", "async", "sync"]
    Instantiator {
        model: root.mpvKeys
        delegate: Shortcut {
            required property var modelData
            sequences: modelData[0]
            onActivated: {
                root.wake()
                let c = modelData[1].slice()
                if (root.cmdPrefixes.indexOf(c[0]) < 0 && c[0] !== "set_property" && c[0] !== "get_property")
                    c.unshift("osd-auto")
                MpvClient.command(c, root.sessionKey)
            }
        }
    }
}
