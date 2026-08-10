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

    property var detail: ({})

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

                    Button {
                        text: "播放"
                        width: 160
                        height: 44
                        font.pixelSize: 16
                        onClicked: EmbyClient.fetchPlaybackInfo(root.itemId)
                        background: Rectangle {
                            radius: 10
                            color: Theme.accent
                        }
                        contentItem: Text {
                            text: "播放"
                            color: "white"
                            font.pixelSize: 16
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
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
            if (meta.itemId === root.itemId)
                root.playRequested(url, headers, meta)
        }
    }
}
