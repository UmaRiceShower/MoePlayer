import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import "qrc:/qml/theme"

//! 条目详情页(Hero + 左栏正文 + 右侧竖向选集条)。
//! 无状态浏览:详情/播放协商/已看/收藏/相似推荐均按 serverUrl 凭据路由。
//! 选集条替代原"分季→全屏分集网格":剧集页与集详情页共用右侧竖向列表,
//! 滚轮/上下键滚动,hover 放大;点集原地替换(集详情页内切集,不叠栈)。
Item {
    id: root

    property string itemId: ""
    property string posterId: ""
    property string title: ""
    // 条目所在服务器:所有请求按该服务器凭据路由(无状态)。
    property string serverUrl: ""

    signal playRequested(string url, var headers, var meta)
    signal backRequested()
    // 打开另一条目详情(相似推荐点击):主窗口压栈。
    signal openItem(string itemId, string posterId, string title, string serverUrl)

    // 该服务器凭据(账号缺失返回空 map)。
    function creds() {
        return AccountManager.credsForServer(root.serverUrl)
    }

    // 标识本页为详情页(Main 据此防止双击卡片重复 push)。
    readonly property bool isDetailPage: true

    property var detail: ({})
    property bool isFavorite: false
    // detail 是否已加载完成(首次进入/切集前为 false → 显示加载动画,
    // 到达后一次性渲染完整结构,避免介绍/演员逐块出现推动按钮位置)。
    property bool loaded: false
    // 选集条当前季(Season id);空=尚未选择。
    property string currentSeasonId: ""

    // ---- 播放:Series/Episode/Movie 统一走 playItem,按目标条目 id 协商。 ----
    property string pendingPlayItemId: ""
    property double resumeTicks: 0
    property bool playbackPending: false

    function playItem(itemId, resume) {
        if (root.playbackPending || !itemId)
            return
        root.playbackPending = true
        root.pendingPlayItemId = itemId
        root.resumeTicks = resume
        const c = root.creds()
        EmbyClient.fetchPlaybackInfo(root.serverUrl, c.token, c.userId, itemId)
    }
    // 播放当前详情条目:resume 为 true 时从上次位置续播。
    function startPlayback(resume) {
        const t = resume && root.detail.positionTicks > 0 && !root.detail.played
                ? root.detail.positionTicks : 0
        root.playItem(root.itemId, t)
    }
    // 剧集页播放:跨季续播(全部集里第一条有进度的),否则第一集。
    function playSeries() {
        const model = EmbyClient.allEpisodesModelFor(root.serverUrl)
        let target = null
        for (let i = 0; i < model.count; i++) {
            const it = model.itemAt(i)
            if (it.positionTicks > 0 && !it.played) { target = it; break }
        }
        if (!target && model.count > 0)
            target = model.itemAt(0)
        if (!target)
            return
        root.playItem(target.id, target.positionTicks > 0 && !target.played ? target.positionTicks : 0)
    }
    function playButtonText() {
        if (root.detail.positionTicks > 0 && !root.detail.played)
            return "从 " + formatTime(root.detail.positionTicks / Constants.ticksPerSecond) + " 继续播放"
        return "播放"
    }
    function seriesPlayText() {
        const model = EmbyClient.allEpisodesModelFor(root.serverUrl)
        for (let i = 0; i < model.count; i++) {
            const it = model.itemAt(i)
            if (it.positionTicks > 0 && !it.played)
                return "继续观看" + (it.seasonNo > 0 && it.episodeNo > 0 ? " S" + it.seasonNo + "E" + it.episodeNo : "")
        }
        return "播放"
    }

    function toggleFavorite() {
        root.isFavorite = !root.isFavorite
        const c = root.creds()
        EmbyClient.setFavorite(root.serverUrl, c.token, c.userId, root.itemId, root.isFavorite)
    }
    function toggleWatched() {
        const played = !root.detail.played
        const c = root.creds()
        EmbyClient.setWatched(root.serverUrl, c.token, c.userId,
                              root.itemId, played, 0, played ? 100 : 0)
    }

    // ---- 原地替换(选集条切集):更新自身 id 触发 onItemIdChanged 重拉,不压栈。 ----
    function replaceItem(newItemId, newPosterId, newTitle) {
        root.itemId = newItemId
        root.posterId = newPosterId
        root.title = newTitle
        // 切集:重置季与收藏(新集 detail 到达前不显示旧集状态)。
        root.currentSeasonId = ""
        root.isFavorite = false
    }
    // 返回键:集详情先原地回父剧详情,否则 pop。
    function back() {
        if (root.detail.type === "Episode" && root.detail.seriesId) {
            root.replaceItem(root.detail.seriesId, "", root.detail.seriesName)
            return
        }
        root.backRequested()
    }
    // 首次进入/切集共用:置 loaded=false 显示加载动画,detail 到达后
    // 经 onItemDetailReady 置 loaded=true 并一次性渲染完整结构。
    function reload() {
        root.loaded = false
        root.playbackPending = false
        const c = root.creds()
        if (root.itemId !== "")
            EmbyClient.fetchItemDetail(root.serverUrl, c.token, c.userId, root.itemId)
    }
    // 播放后刷新:保留当前结构与旧数据,静默重拉(不闪加载动画)。
    function refreshAfterPlayback() {
        const c = root.creds()
        if (root.itemId !== "")
            EmbyClient.fetchItemDetail(root.serverUrl, c.token, c.userId, root.itemId)
    }
    // 选集条选季:拉该季分集并回顶部。
    function selectSeason(seasonId) {
        root.currentSeasonId = seasonId
        const seriesId = root.detail.type === "Series" ? root.detail.id : root.detail.seriesId
        if (seriesId && seasonId) {
            const c = root.creds()
            EmbyClient.fetchEpisodes(root.serverUrl, c.token, c.userId, seriesId, seasonId)
        }
        episodeList.contentY = 0
    }

    // pop 回来时共享模型(seasons/episodes/similar/allEpisodes 按 serverUrl
    // 字典化)可能已被栈内其他详情页覆盖(同服务器单模型),重拉本页数据;
    // episodes 经 onSeasonsReceived → selectSeason 链重拉,季保持 currentSeasonId。
    function resyncModels() {
        if (root.itemId === "")
            return
        const c = root.creds()
        const seriesId = root.detail.type === "Series" ? root.detail.id : root.detail.seriesId
        if (seriesId)
            EmbyClient.fetchSeasons(root.serverUrl, c.token, c.userId, seriesId)
        if (root.detail.type === "Series")
            EmbyClient.fetchAllEpisodes(root.serverUrl, c.token, c.userId, root.detail.id)
        EmbyClient.fetchSimilar(root.serverUrl, c.token, c.userId, root.itemId)
    }


    // ---- 显示辅助 ----
    function heroTitle() {
        if (root.detail.type === "Episode") {
            let t = root.detail.seriesName || root.title
            if (root.detail.seasonNo > 0 && root.detail.episodeNo > 0)
                t += " · S" + root.detail.seasonNo + "E" + root.detail.episodeNo
            if (root.detail.name)
                t += " · " + root.detail.name
            return t
        }
        return root.detail.name || root.title
    }
    function metaLine() {
        let parts = []
        if (root.detail.rating > 0)
            parts.push("★ " + root.detail.rating.toFixed(1))
        if (root.detail.year > 0)
            parts.push(String(root.detail.year))
        if (root.detail.genres && root.detail.genres.length > 0)
            parts.push(root.detail.genres.join("/"))
        if (root.detail.runtimeSecs > 0)
            parts.push(formatTime(root.detail.runtimeSecs))
        return parts.join(" · ")
    }
    function heroPosterSource() {
        if (root.detail.posterId)
            return "image://emby/" + root.detail.posterId
        if (root.posterId !== "")
            return "image://emby/" + root.posterId
        return ""
    }
    function backdropSource() {
        if (root.detail.backdropId)
            return "image://emby/" + root.detail.backdropId
        if (root.detail.parentBackdropId)
            return "image://emby/" + root.detail.parentBackdropId
        return ""
    }
    function formatTime(s) {
        if (s < 0)
            s = 0
        const h = Math.floor(s / 3600)
        const m = Math.floor((s % 3600) / 60)
        const sec = Math.floor(s % 60)
        const mm = m < 10 ? "0" + m : m
        const ss = sec < 10 ? "0" + sec : sec
        return h > 0 ? h + ":" + mm + ":" + ss : mm + ":" + ss
    }
    function formatSize(bytes) {
        if (!bytes || bytes <= 0)
            return ""
        const gb = bytes / (1024 * 1024 * 1024)
        if (gb >= 1)
            return gb.toFixed(1) + " GB"
        const mb = bytes / (1024 * 1024)
        return mb.toFixed(0) + " MB"
    }
    function streamLabel(s) {
        if (s.type === "Video")
            return "视频 · " + s.codec.toUpperCase()
                    + (s.width > 0 && s.height > 0 ? " " + s.width + "×" + s.height : "")
                    + (s.videoRange ? " " + s.videoRange : "")
        if (s.type === "Audio")
            return "音轨 · " + s.codec.toUpperCase()
                    + (s.channels > 0 ? " " + s.channels + "声道" : "")
                    + (s.language ? " " + s.language : "")
        if (s.type === "Subtitle")
            return "字幕 · " + s.codec.toUpperCase()
                    + (s.language ? " " + s.language : "")
        return s.type
    }

    property bool _ready: false
    onItemIdChanged: {
        // 首次进入由 onCompleted 处理;之后(itemId 原地替换)在此重拉。
        if (root._ready)
            root.reload()
    }
    Component.onCompleted: {
        root._ready = true
        root.reload()
    }

    onVisibleChanged: {
        // StackView pop 回来(visible false→true)时重拉被覆盖的共享模型。
        if (root.visible && root._ready)
            root.resyncModels()
    }


    Rectangle {
        anchors.fill: parent
        color: Theme.bg

        // 加载动画:detail 未到(首次进入/切集)时显示,到达后隐藏,
        // 保证首次渲染即完整结构,介绍/演员不逐块出现推动按钮位置。
        Item {
            anchors.fill: parent
            visible: !root.loaded
            Column {
                anchors.centerIn: parent
                spacing: 12
                BusyIndicator {
                    anchors.horizontalCenter: parent.horizontalCenter
                    running: true
                }
                Text {
                    text: "加载中…"
                    color: Theme.textMuted
                    font.pixelSize: 14
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }

        Row {
            anchors.fill: parent
            visible: root.loaded

            // ---- 左栏:正文(Hero + 演职人员 + 媒体信息 + 相似推荐) ----
            Flickable {
                id: overview
                width: parent.width - (sidebar.visible ? Constants.detailSidebarW : 0)
                height: parent.height
                clip: true
                contentHeight: overviewColumn.implicitHeight
                ScrollBar.vertical: ScrollBar {}

                Column {
                    id: overviewColumn
                    width: parent.width

                    // ================= Hero =================
                    Item {
                        width: parent.width
                        height: Constants.detailHeroH

                        // 背景:无 backdrop 时纯色纵向渐变(表面色→底色)。
                        Rectangle {
                            anchors.fill: parent
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: Theme.surface }
                                GradientStop { position: 1.0; color: Theme.bg }
                            }
                        }
                        Image {
                            anchors.fill: parent
                            source: root.backdropSource()
                            fillMode: Image.PreserveAspectCrop
                            opacity: status === Image.Ready && source !== "" ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 220 } }
                            cache: true
                        }
                        // 底部渐变遮罩:保证标题/按钮文字可读。
                        Rectangle {
                            anchors.fill: parent
                            gradient: Gradient {
                                GradientStop { position: 0.55; color: "transparent" }
                                GradientStop { position: 1.0; color: Theme.bg }
                            }
                        }

                        Button {
                            anchors.left: parent.left
                            anchors.leftMargin: 16
                            anchors.top: parent.top
                            anchors.topMargin: 12
                            text: "← 返回"
                            onClicked: root.back()
                        }
                        Button {
                            anchors.right: parent.right
                            anchors.rightMargin: 16
                            anchors.top: parent.top
                            anchors.topMargin: 12
                            text: root.isFavorite ? "♥ 已收藏" : "♡ 收藏"
                            onClicked: root.toggleFavorite()
                        }

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: 32
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 24
                            spacing: 24

                            // 海报(2:3 竖版,独立前景锚点)
                            Rectangle {
                                width: Constants.detailPosterW
                                height: Constants.detailPosterH
                                color: Theme.surface
                                radius: 6
                                Image {
                                    anchors.fill: parent
                                    anchors.margins: 3
                                    source: root.heroPosterSource()
                                    fillMode: Image.PreserveAspectCrop
                                    opacity: status === Image.Ready && source !== "" ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 180 } }
                                    cache: true
                                }
                            }

                            Column {
                                width: Math.max(280, overview.width - Constants.detailPosterW - 32 - 24 - 48)
                                spacing: 8

                                Text {
                                    text: root.heroTitle()
                                    color: Theme.textPrimary
                                    font.pixelSize: 30
                                    font.bold: true
                                    elide: Text.ElideRight
                                    width: parent.width
                                }
                                Text {
                                    text: root.metaLine()
                                    color: root.detail.rating > 0 ? Theme.rating : Theme.textMuted
                                    font.pixelSize: 14
                                    opacity: text !== "" ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 200 } }
                                }
                                Text {
                                    text: root.detail.overview || ""
                                    color: Theme.textMuted
                                    font.pixelSize: 13
                                    wrapMode: Text.Wrap
                                    elide: Text.ElideRight
                                    maximumLineCount: root.detail.overview && root.detail.overview.length > 0 ? 2 : 0
                                    width: parent.width
                                    opacity: text !== "" ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 200 } }
                                }
                                Row {
                                    spacing: 10
                                    Button {
                                        text: root.detail.type === "Series" ? root.seriesPlayText() : root.playButtonText()
                                        width: 220
                                        height: 44
                                        font.pixelSize: 16
                                        onClicked: root.detail.type === "Series" ? root.playSeries() : root.startPlayback(true)
                                        background: Rectangle {
                                            radius: 10
                                            color: Theme.accent
                                        }
                                        contentItem: Text {
                                            text: parent.text
                                            color: "white"
                                            font.pixelSize: 16
                                            horizontalAlignment: Text.AlignHCenter
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                    }
                                    Button {
                                        text: "从头播放"
                                        visible: root.detail.type !== "Series" && root.detail.positionTicks > 0 && !root.detail.played
                                        height: 44
                                        onClicked: root.startPlayback(false)
                                    }
                                    Button {
                                        text: root.detail.played ? "标记未看" : "标记已看"
                                        visible: root.detail.type !== "Series"
                                        height: 44
                                        onClicked: root.toggleWatched()
                                    }
                                    Button {
                                        text: root.detail.played ? "标记未看" : "标记已看"
                                        visible: root.detail.type === "Series"
                                        height: 44
                                        onClicked: root.toggleWatched()
                                    }
                                }
                            }
                        }
                    }

                    // ================= 演职人员 =================
                    Column {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.min(parent.width - 48, Constants.detailBodyMaxW)
                        spacing: 8
                        visible: !!root.detail.people && root.detail.people.length > 0
                        opacity: visible ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 200 } }

                        Text {
                            text: "演职人员"
                            color: Theme.textPrimary
                            font.pixelSize: 18
                            font.bold: true
                        }
                        Flickable {
                            width: parent.width
                            height: 110
                            clip: true
                            contentWidth: peopleRow.implicitWidth
                            Row {
                                id: peopleRow
                                spacing: 16
                                Repeater {
                                    model: root.detail.people
                                    delegate: Item {
                                        width: 72
                                        height: 100
                                        Column {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            spacing: 4
                                            Rectangle {
                                                width: 60
                                                height: 60
                                                radius: 30
                                                color: Theme.surface
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                Image {
                                                    anchors.fill: parent
                                                    source: modelData.posterId ? "image://emby/" + modelData.posterId : ""
                                                    fillMode: Image.PreserveAspectCrop
                                                    opacity: status === Image.Ready && source !== "" ? 1 : 0
                                                    Behavior on opacity { NumberAnimation { duration: 180 } }
                                                    cache: true
                                                }
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: modelData.name ? modelData.name.charAt(0) : ""
                                                    color: Theme.textMuted
                                                    font.pixelSize: 20
                                                    visible: !(modelData.posterId)
                                                }
                                            }
                                            Text {
                                                text: modelData.name || ""
                                                color: Theme.textPrimary
                                                font.pixelSize: 12
                                                elide: Text.ElideRight
                                                width: 72
                                                horizontalAlignment: Text.AlignHCenter
                                            }
                                            Text {
                                                text: modelData.role || modelData.type || ""
                                                color: Theme.textMuted
                                                font.pixelSize: 11
                                                elide: Text.ElideRight
                                                width: 72
                                                horizontalAlignment: Text.AlignHCenter
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ================= 媒体信息 =================
                    Column {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.min(parent.width - 48, Constants.detailBodyMaxW)
                        spacing: 8
                        visible: !!root.detail.mediaSources && root.detail.mediaSources.length > 0
                        opacity: visible ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 200 } }

                        Text {
                            text: "媒体信息"
                            color: Theme.textPrimary
                            font.pixelSize: 18
                            font.bold: true
                        }
                        Repeater {
                            model: root.detail.mediaSources
                            delegate: Column {
                                width: parent.width
                                spacing: 2
                                Text {
                                    text: (modelData.name || "") + " · "
                                            + (modelData.container ? modelData.container.toUpperCase() + " · " : "")
                                            + formatSize(modelData.sizeBytes)
                                    color: Theme.textPrimary
                                    font.pixelSize: 14
                                }
                                Repeater {
                                    model: modelData.streams
                                    delegate: Text {
                                        text: streamLabel(modelData)
                                        color: Theme.textMuted
                                        font.pixelSize: 13
                                    }
                                }
                            }
                        }
                    }

                    // ================= 相似推荐 =================
                    Column {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.min(parent.width - 48, Constants.detailBodyMaxW)
                        spacing: 8
                        visible: EmbyClient.similarModelFor(root.serverUrl).count > 0
                        opacity: visible ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 200 } }

                        Text {
                            text: "相似推荐"
                            color: Theme.textPrimary
                            font.pixelSize: 18
                            font.bold: true
                        }
                        ListView {
                            width: parent.width
                            height: Constants.detailCardH + 40
                            orientation: ListView.Horizontal
                            spacing: 12
                            clip: true
                            model: EmbyClient.similarModelFor(root.serverUrl)
                            delegate: Item {
                                width: Constants.detailCardW
                                height: Constants.detailCardH
                                Rectangle {
                                    width: Constants.detailCardW
                                    height: Constants.detailCardH
                                    color: Theme.surface
                                    radius: 6
                                    Image {
                                        anchors.fill: parent
                                        anchors.margins: 3
                                        source: model.posterId ? "image://emby/" + model.posterId : ""
                                        fillMode: Image.PreserveAspectCrop
                                        opacity: status === Image.Ready && source !== "" ? 1 : 0
                                        Behavior on opacity { NumberAnimation { duration: 180 } }
                                        cache: true
                                    }
                                    Text {
                                        anchors.bottom: parent.bottom
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.margins: 6
                                        text: model.name
                                        color: Theme.textPrimary
                                        font.pixelSize: 12
                                        elide: Text.ElideRight
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: root.openItem(model.id, model.posterId, model.name, root.serverUrl)
                                }
                            }
                        }
                    }

                    // 底部留白
                    Item { width: 1; height: 32 }
                }
            }

            // ---- 右栏:竖向选集条(剧集/集详情) ----
            Column {
                id: sidebar
                width: Constants.detailSidebarW
                height: parent.height
                visible: root.detail.type === "Series" || root.detail.type === "Episode"
                opacity: visible ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 220 } }

                // 季标签(季数>1 时显示;基础样式横向排列)
                Row {
                    id: seasonBar
                    width: parent.width
                    height: 44
                    spacing: 4
                    clip: true
                    visible: EmbyClient.seasonsModelFor(root.serverUrl).count > 1
                    Repeater {
                        model: EmbyClient.seasonsModelFor(root.serverUrl)
                        delegate: Button {
                            height: 32
                            text: model.name
                            checkable: true
                            checked: model.id === root.currentSeasonId
                            onClicked: root.selectSeason(model.id)
                        }
                    }
                }

                ListView {
                    id: episodeList
                    width: parent.width
                    height: parent.height - seasonBar.height
                    clip: true
                    focus: true
                    keyNavigationWraps: true
                    model: EmbyClient.episodesModelFor(root.serverUrl)
                    ScrollBar.vertical: ScrollBar {}
                    delegate: Item {
                        width: episodeList.width - 12
                        height: Constants.detailEpisodeRowH
                        x: 6
                        // hover 放大(基础样式)
                        scale: mouse.containsMouse ? Constants.detailEpisodeHoverScale : 1.0
                        Behavior on scale { NumberAnimation { duration: Constants.animMaxMs } }

                        Rectangle {
                            anchors.fill: parent
                            radius: 6
                            color: model.id === root.itemId ? Theme.accent
                                   : (mouse.containsMouse || ListView.isCurrentItem) ? Theme.surface
                                   : "transparent"
                        }
                        Row {
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 8
                            Text {
                                width: 26
                                anchors.verticalCenter: parent.verticalCenter
                                text: model.episodeNo > 0 ? String(model.episodeNo) : "—"
                                color: model.id === root.itemId ? "white" : Theme.textMuted
                                font.pixelSize: 14
                                font.bold: true
                            }
                            Column {
                                width: parent.width - 34
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 3
                                Text {
                                    width: parent.width
                                    text: model.name
                                    color: model.id === root.itemId ? "white" : Theme.textPrimary
                                    font.pixelSize: 14
                                    elide: Text.ElideRight
                                }
                                // 观看进度条
                                Item {
                                    width: parent.width
                                    height: 3
                                    visible: model.positionTicks > 0 && !model.played && model.runtimeTicks > 0
                                    Rectangle {
                                        anchors.fill: parent
                                        color: model.id === root.itemId ? Qt.rgba(1,1,1,0.4) : Theme.surface
                                    }
                                    Rectangle {
                                        width: parent.width * Math.min(1, model.positionTicks / model.runtimeTicks)
                                        height: parent.height
                                        color: model.id === root.itemId ? "white" : Theme.accent
                                    }
                                }
                                Text {
                                    text: "已看"
                                    color: model.id === root.itemId ? "white" : Theme.success
                                    font.pixelSize: 11
                                    visible: model.played
                                }
                            }
                        }
                        MouseArea {
                            id: mouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                // 选集条点集:原地替换(剧集页与集详情页一致,栈深恒为 1)。
                                root.replaceItem(model.id, model.posterId, model.name)
                            }
                        }
                    }
                }
            }
        }
    }

    Connections {
        target: EmbyClient
        function onItemDetailReady(serverUrl, d) {
            if (serverUrl !== root.serverUrl || d.id !== root.itemId)
                return
            root.detail = d
            root.isFavorite = d.isFavorite
            root.loaded = true
            const c = root.creds()
            // 选集条季列表:剧集自身 / 集详情的父剧。
            if (d.type === "Series") {
                EmbyClient.fetchSeasons(root.serverUrl, c.token, c.userId, d.id)
                // 全部集(跨季),供"继续观看"按进度定位目标集。
                EmbyClient.fetchAllEpisodes(root.serverUrl, c.token, c.userId, d.id)
            } else if (d.type === "Episode" && d.seriesId) {
                EmbyClient.fetchSeasons(root.serverUrl, c.token, c.userId, d.seriesId)
            }
            // 相似推荐(剧集/电影/分集都拉,空则整段隐藏)。
            EmbyClient.fetchSimilar(root.serverUrl, c.token, c.userId, d.id)
        }
        function onSeasonsReceived(serverUrl) {
            if (serverUrl !== root.serverUrl)
                return
            const model = EmbyClient.seasonsModelFor(root.serverUrl)
            let seasonId = ""
            // 优先保持当前季(重拉/pop 回来不丢失用户选择),其次集详情的季,再第一季。
            if (root.currentSeasonId) {
                for (let i = 0; i < model.count; i++) {
                    if (model.itemAt(i).id === root.currentSeasonId) { seasonId = root.currentSeasonId; break }
                }
            }
            if (!seasonId && root.detail.type === "Episode" && root.detail.seasonId) {
                for (let i = 0; i < model.count; i++) {
                    if (model.itemAt(i).id === root.detail.seasonId) { seasonId = root.detail.seasonId; break }
                }
            }
            if (!seasonId && model.count > 0)
                seasonId = model.itemAt(0).id
            if (seasonId)
                root.selectSeason(seasonId)
        }
        function onPlaybackReady(serverUrl, url, headers, meta) {
            root.playbackPending = false
            if (serverUrl === root.serverUrl && meta.itemId === root.pendingPlayItemId) {
                const m = Object.assign({}, meta)
                m.resumePositionTicks = root.resumeTicks || 0
                root.playRequested(url, headers, m)
            }
        }
        // 播放协商失败时复位防抖,允许重试。
        function onErrorOccurred(serverUrl, message) {
            if (serverUrl !== root.serverUrl)
                return
            root.playbackPending = false
        }
    }
}
