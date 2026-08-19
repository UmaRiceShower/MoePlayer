pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import MoePlayer.Core

// 通用单选列表弹窗,用于复刻 mpv 官方 OSC 的右键 select 菜单
// (audio track / subtitle track / audio device / chapter 等)。
Rectangle {
    id: root
    width: 320
    height: Math.min(parent.height * 0.7, listView.contentHeight + 64)
    radius: 12
    color: Theme.surface
    border.width: 1
    border.color: Qt.rgba(Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 0.35)
    visible: false
    z: 30

    onHeightChanged: {
        if (visible && anchorItem)
            Qt.callLater(function() { root.reposition() })
    }

    // 菜单标题。
    property string title: ""
    // 列表数据,每项 {id, title, selected}。
    property var model: []
    // 当前选中项的 id(可选,用于高亮)。
    property var currentId
    // 选中回调,signature: function(id) {}
    property var onSelect: null
    // 触发该菜单的按钮,菜单会出现在按钮正上方。
    property Item anchorItem: null

    signal itemSelected(var id)

    function reposition() {
        if (!anchorItem || !parent)
            return
        const centerX = anchorItem.x + anchorItem.width / 2
        root.x = Math.max(8, Math.min(parent.width - root.width - 8, centerX - root.width / 2))
        const itemPos = anchorItem.mapToItem(root.parent, 0, 0)
        root.y = Math.max(8, itemPos.y - root.height - 8)
    }

    function open() {
        root.visible = true
        listView.positionViewAtBeginning()
        // 等 ListView 高度/布局稳定后再定位,避免高度尚未算出。
        Qt.callLater(function() { root.reposition() })
    }
    function close() { root.visible = false }

    Column {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        AppText {
            visible: root.title !== ""
            text: root.title
            color: Theme.textPrimary
            font.pixelSize: 16
            font.bold: true
        }

        ListView {
            id: listView
            width: parent.width
            height: parent.height - (root.title !== "" ? 28 : 0)
            model: root.model
            spacing: 4
            clip: true
            delegate: Rectangle {
                id: delegate
                required property var modelData
                required property int index
                width: listView.width
                height: 34
                radius: 17
                color: root.currentId !== undefined && modelData.id === root.currentId
                       ? Constants.moePink
                       : (hover.hovered ? Theme.bg : Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.5))
                border.width: 1
                border.color: root.currentId !== undefined && modelData.id === root.currentId
                               ? Constants.moePink
                               : Theme.textMuted

                AppText {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    text: modelData.title || "未知"
                    color: root.currentId !== undefined && modelData.id === root.currentId ? "white" : Theme.textPrimary
                    font.pixelSize: 13
                    elide: Text.ElideRight
                }

                MouseArea {
                    id: hover
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        if (root.onSelect)
                            root.onSelect(modelData.id)
                        root.itemSelected(modelData.id)
                        root.close()
                    }
                }
            }
        }
    }

    // 点击外部关闭。
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: root.close()
    }
}
