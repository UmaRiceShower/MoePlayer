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

    signal playRequested(string url, var headers, var meta)
    signal backRequested()

    // 标识本页为详情页(Main 据此防止双击卡片重复 push)。
    readonly property bool isDetailPage: true

    property var detail: ({})

    // 本次播放是否续播(起播位置由 playbackReady 的 meta.resumePositionTicks 携带)。
    property var resumeTicks: 0

    // 发起播放:resume 为 true 时从上次位置续播。
    function startPlayback(resume) {
        root.resumeTicks = resume ? root.detail.positionTicks : 0
        EmbyClient.fetchPlaybackInfo(root.itemId)
    }
    // 已看标记文案:有进度且未看完 → 继续播放;否则从头播放。
    function playButtonText() {
        if (root.detail.positionTicks > 0 && !root.detail.played)
            return "从 " + formatTime(root.detail.positionTicks / 1e7) + " 继续播放"
        return "播放"
    }

    Component.onCompleted: {
        if (root.itemId !== "")
            EmbyClient.fetchItemDetail(root.itemId)
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.bg

        Column {
            anchors.fill: parent
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
                                EmbyClient.setWatched(root.itemId, played, 0,
                                                      played ? 100 : 0)
                            }
                        }
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
        function onItemDetailReady(d) {
            if (d.id === root.itemId)
                root.detail = d
        }
        function onPlaybackReady(url, headers, meta) {
            if (meta.itemId === root.itemId) {
                const m = Object.assign({}, meta)
                m.resumePositionTicks = root.resumeTicks || 0
                root.playRequested(url, headers, m)
            }
        }
        // 已看/进度被其他客户端修改(或本客户端播完自动标记)时实时刷新。
        function onServerEventReceived(type, data) {
            if (type !== "UserDataChanged")
                return
            const list = data.UserDataList || []
            for (const e of list) {
                if (String(e.ItemId) === root.itemId) {
                    root.detail = Object.assign({}, root.detail, {
                        positionTicks: e.PlaybackPositionTicks || 0,
                        played: !!e.Played
                    })
                }
            }
        }
    }
}
