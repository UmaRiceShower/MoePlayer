import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import "qrc:/qml/theme"

//! 条目详情页:大图、元数据与简介,提供播放入口。
//! 进入时经 EmbyClient.fetchItemDetail 拉取详情;播放按钮走 PlaybackInfo 协商后
//! 把 url/headers/meta 交给主窗口打开播放窗口。
Item {
    id: root

    property string itemId: ""
    property string posterId: ""
    property string title: ""
    // 条目所在服务器:浏览/播放协商/已看标记均按该服务器凭据路由(无状态)。
    property string serverUrl: ""

    signal playRequested(string url, var headers, var meta)
    signal backRequested()
    // 剧集条目点击 → 主窗口 push 该集详情页(携带所在服务器)。
    signal showEpisodeDetail(string itemId, string posterId, string title, string serverUrl)

    // 该服务器凭据(账号缺失返回空 map)。
    function creds() {
        return AccountManager.credsForServer(root.serverUrl)
    }

    // 标识本页为详情页(Main 据此防止双击卡片重复 push)。
    readonly property bool isDetailPage: true

    property var detail: ({})
    // 剧集导航:非空时处于"某季分集"浏览模式(显示该季 Episodes 网格)。
    property string browseSeasonId: ""
    property string browseSeasonName: ""

    // 进入某季的分集浏览。
    function openSeason(seasonId, seasonName) {
        root.browseSeasonId = seasonId
        root.browseSeasonName = seasonName
        const c = root.creds()
        EmbyClient.fetchEpisodes(root.serverUrl, c.token, c.userId, root.itemId, seasonId)
    }

    // 本次播放是否续播(起播位置由 playbackReady 的 meta.resumePositionTicks 携带)。
    property var resumeTicks: 0
    // 播放协商进行中(防连点重复发起 PlaybackInfo → 重复开窗)。
    property bool playbackPending: false

    // 发起播放:resume 为 true 时从上次位置续播。
    function startPlayback(resume) {
        if (root.playbackPending)
            return
        root.playbackPending = true
        root.resumeTicks = resume ? root.detail.positionTicks : 0
        const c = root.creds()
        EmbyClient.fetchPlaybackInfo(root.serverUrl, c.token, c.userId, root.itemId)
    }
    // 已看标记文案:有进度且未看完 → 继续播放;否则从头播放。
    function playButtonText() {
        if (root.detail.positionTicks > 0 && !root.detail.played)
            return "从 " + formatTime(root.detail.positionTicks / Constants.ticksPerSecond) + " 继续播放"
        return "播放"
    }

    // 播放结束(主窗口通知)后重拉详情:刷新已看/进度/继续观看位置。
    function refreshAfterPlayback() {
        if (root.itemId === "")
            return
        const c = root.creds()
        EmbyClient.fetchItemDetail(root.serverUrl, c.token, c.userId, root.itemId)
    }

    Component.onCompleted: {
        if (root.itemId !== "") {
            const c = root.creds()
            EmbyClient.fetchItemDetail(root.serverUrl, c.token, c.userId, root.itemId)
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.bg

        // ---- 概览模式:Movie/Episode 详情,Series 元数据 + Seasons 行 ----
        Flickable {
            visible: root.browseSeasonId === ""
            anchors.fill: parent
            clip: true
            contentHeight: overviewColumn.implicitHeight

            Column {
                id: overviewColumn
                width: parent.width
                spacing: 16
                padding: 24

            Row {
                spacing: 12
                Button {
                    text: "← 返回"
                    onClicked: root.backRequested()
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.title
                    color: Theme.textPrimary
                    font.pixelSize: 24
                    font.bold: true
                    elide: Text.ElideRight
                    width: 600
                }
            }

            Row {
                spacing: 24

                // 海报
                Rectangle {
                    width: 240
                    height: 360
                    color: Theme.surface
                    radius: 8
                    Image {
                        anchors.fill: parent
                        anchors.margins: 4
                        source: root.posterId !== "" ? "image://emby/" + root.posterId : ""
                        fillMode: Image.PreserveAspectCrop
                        cache: true
                    }
                }

                // 元数据与简介
                Column {
                    width: 520
                    spacing: 10

                    Text {
                        text: root.detail.year > 0 ? String(root.detail.year) : ""
                        color: Theme.textMuted
                        font.pixelSize: 14
                    }

                    Text {
                        text: root.detail.genres ? root.detail.genres.join(" · ") : ""
                        color: Theme.textMuted
                        font.pixelSize: 14
                        visible: text !== ""
                    }

                    Text {
                        text: root.detail.rating > 0 ? "★ " + root.detail.rating.toFixed(1) : ""
                        color: Theme.textMuted
                        font.pixelSize: 14
                        visible: text !== ""
                    }

                    Text {
                        text: root.detail.runtimeSecs > 0 ? formatTime(root.detail.runtimeSecs) : ""
                        color: Theme.textMuted
                        font.pixelSize: 14
                        visible: text !== ""
                    }

                    Text {
                        text: root.detail.overview || ""
                        color: Theme.textPrimary
                        font.pixelSize: 14
                        wrapMode: Text.Wrap
                        lineHeight: 1.5
                    }

                    Row {
                        spacing: 10
                        // 剧集(Series)不可直接播放,隐藏播放入口,保留整剧已看标记。
                        visible: root.detail.type !== "Series"
                        Button {
                            text: root.playButtonText()
                            width: 200
                            height: 44
                            font.pixelSize: 16
                            onClicked: root.startPlayback(true)
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
                            text: root.detail.positionTicks > 0 && !root.detail.played
                                  ? "从头播放" : ""
                            visible: text !== ""
                            width: 110
                            height: 44
                            font.pixelSize: 14
                            onClicked: root.startPlayback(false)
                        }
                        Button {
                            text: root.detail.played ? "标记未看" : "标记已看"
                            width: 110
                            height: 44
                            font.pixelSize: 14
                            onClicked: {
                                const played = !root.detail.played
                                // 手动标记:写入服务器(UserData),位置清零。
                                const c = root.creds()
                                EmbyClient.setWatched(root.serverUrl, c.token, c.userId,
                                                      root.itemId, played, 0, played ? 100 : 0)
                            }
                        }
                    }
                }
            }

            // ---- Series:分季横向列表 ----
            Text {
                text: "剧集"
                visible: root.detail.type === "Series"
                color: Theme.textPrimary
                font.pixelSize: 18
                font.bold: true
            }
            ListView {
                visible: root.detail.type === "Series"
                orientation: ListView.Horizontal
                spacing: 12
                width: parent.width
                height: 210
                clip: true
                model: EmbyClient.seasonsModelFor(root.serverUrl)
                delegate: Item {
                    width: 120
                    height: 200
                    Rectangle {
                        width: 110
                        height: 155
                        color: Theme.surface
                        radius: 6
                        border.width: hover.hovered ? 2 : 0
                        border.color: Theme.accent
                        Image {
                            anchors.fill: parent
                            anchors.margins: 3
                            source: model.posterId ? "image://emby/" + model.posterId : ""
                            fillMode: Image.PreserveAspectCrop
                            cache: true
                        }
                    }
                    Text {
                        anchors.top: parent.bottom
                        anchors.topMargin: -34
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 120
                        text: model.name
                        color: Theme.textPrimary
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignHCenter
                    }
                    Text {
                        anchors.top: parent.bottom
                        anchors.topMargin: -16
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "查看分集 ▸"
                        color: Theme.textMuted
                        font.pixelSize: 11
                    }
                    MouseArea {
                        id: hover
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.openSeason(model.id, model.name)
                    }
                }
            }
        }
        }

        // ---- 分集浏览模式:某季的 Episodes 网格 ----
        Column {
            visible: root.browseSeasonId !== ""
            anchors.fill: parent
            spacing: 16
            padding: 24

            Row {
                spacing: 12
                Button {
                    text: "← 返回"
                    onClicked: root.browseSeasonId = ""
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.browseSeasonName
                    color: Theme.textPrimary
                    font.pixelSize: 24
                    font.bold: true
                }
            }

            GridView {
                width: parent.width
                height: parent.height - 60
                cellWidth: Constants.cellW
                cellHeight: Constants.cellH
                clip: true
                model: EmbyClient.episodesModelFor(root.serverUrl)
                delegate: Item {
                    width: Constants.cardW
                    height: Constants.cardH
                    Rectangle {
                        anchors.fill: parent
                        color: Theme.surface
                        radius: 8
                        Image {
                            anchors.fill: parent
                            anchors.margins: 4
                            source: model.posterId ? "image://emby/" + model.posterId : ""
                            fillMode: Image.PreserveAspectCrop
                            cache: true
                        }
                        Text {
                            anchors.bottom: parent.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.margins: 8
                            text: model.name
                            color: Theme.textPrimary
                            elide: Text.ElideRight
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.showEpisodeDetail(model.id, model.posterId, model.name,
                                                          root.serverUrl)
                    }
                }
            }
        }
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

    Connections {
        target: EmbyClient
        function onItemDetailReady(serverUrl, d) {
            if (serverUrl !== root.serverUrl || d.id !== root.itemId)
                return
            root.detail = d
            // 剧集:加载分季列表,驱动 Seasons 横向行。
            if (d.type === "Series") {
                const c = root.creds()
                EmbyClient.fetchSeasons(root.serverUrl, c.token, c.userId, d.id)
            }
        }
        function onPlaybackReady(serverUrl, url, headers, meta) {
            root.playbackPending = false
            if (serverUrl === root.serverUrl && meta.itemId === root.itemId) {
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
