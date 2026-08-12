import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import "qrc:/qml/theme"

//! 全局搜索浮层(Ctrl+K 开关):服务端搜索跨库递归(影片/剧集/单集),
//! 输入 300ms 防抖后请求,结果网格点击进详情;Esc / 点击背景关闭。
Item {
    id: root

    // 点击结果进详情。
    signal showDetail(string itemId, string posterId, string title)

    // 打开:清空旧结果并聚焦输入框。
    function open() {
        root.visible = true
        searchField.text = ""
        EmbyClient.search("")
        searchField.forceActiveFocus()
    }
    function close() {
        root.visible = false
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }
    }

    Rectangle {
        anchors.top: parent.top
        anchors.topMargin: 48
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(760, parent.width - 64)
        height: parent.height - 96
        radius: 12
        color: Theme.surface

        Column {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 12

            TextField {
                id: searchField
                width: parent.width
                height: 40
                placeholderText: "搜索影片 / 剧集 / 单集(Esc 关闭)"
                font.pixelSize: 15
                // 输入防抖:停止输入 300ms 后才发服务端搜索。
                onTextChanged: searchDebounce.restart()
            }

            // 未输入提示。
            Text {
                visible: searchField.text.length === 0
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.topMargin: 32
                text: "输入关键词,搜索全部媒体库"
                color: Theme.textMuted
                font.pixelSize: 14
            }
            // 已搜索无结果。
            Text {
                visible: searchField.text.length > 0 && EmbyClient.searchModel.count === 0
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.topMargin: 32
                text: "无匹配结果"
                color: Theme.textMuted
                font.pixelSize: 14
            }

            GridView {
                id: resultGrid
                width: parent.width
                height: parent.height - 52
                clip: true
                cellWidth: 168
                cellHeight: 252
                model: EmbyClient.searchModel
                delegate: Item {
                    width: 152
                    height: 236
                    Rectangle {
                        anchors.fill: parent
                        color: Theme.surface
                        radius: 8
                        clip: true
                        Image {
                            anchors.fill: parent
                            anchors.margins: 4
                            source: model.posterId ? "image://emby/" + model.posterId : ""
                            fillMode: Image.PreserveAspectCrop
                            cache: true
                            asynchronous: true
                        }
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 40
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: "transparent" }
                                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.72) }
                            }
                        }
                        Text {
                            anchors.bottom: parent.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottomMargin: 6
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            text: model.year > 0 ? model.name + " (" + model.year + ")" : model.name
                            color: Theme.textPrimary
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.showDetail(model.id, model.posterId, model.name)
                    }
                }
            }
        }
    }

    // 输入防抖定时器。
    Timer {
        id: searchDebounce
        interval: 300
        onTriggered: EmbyClient.search(searchField.text)
    }

    // Esc 关闭。
    Shortcut {
        sequence: "Esc"
        onActivated: root.close()
    }
}
