import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import "qrc:/qml/theme"

//! 首页:每行一个媒体库,行首为库海报,后面是该库按加入时间倒序的最近条目。
//! 中间一行最大,上下行尺寸与透明度逐级递减(透视感)。
//! 点击条目进详情;库海报点击进媒体库页(暂推默认库,后续调整)。
Item {
    id: root

    signal showDetail(string itemId, string posterId, string title)
    signal openLibrary()

    property var rows: EmbyClient.homeRows
    // 循环模型:rows 复制 3 份,始终在中间副本内滚动,边界时跳回中间副本,
    // 实现无限循环(网上通用做法:首尾复制模型作缓冲)。
    property var loopRows: []

    function rebuildLoop() {
        root.loopRows = root.rows.concat(root.rows).concat(root.rows)
        // 中间副本第 1 行初始居中(第一个媒体库即可在中间)。
        if (root.rows.length > 0)
            list.positionViewAtIndex(root.rows.length, ListView.Center)
    }

    Component.onCompleted: EmbyClient.fetchHomeRows(7)
    Connections {
        target: EmbyClient
        // 登录成功即拉视图(Home 为首页时 Library 未必实例化,流程在此闭环)。
        function onLoginSucceeded() { EmbyClient.fetchViews() }
        // 视图就绪 → 重建首页行。
        function onViewsReceived() { EmbyClient.fetchHomeRows(7) }
        function onHomeRowsReceived() {
            root.rows = EmbyClient.homeRows
            root.rebuildLoop()
        }
    }
    onRowsChanged: if (root.rows.length > 0) root.rebuildLoop()

    // 每行条目卡片(库海报或媒体条目)。
    component RowCard: Rectangle {
        property string cardImage: ""
        property string cardText: ""
        property bool isLibrary: false
        property alias cardArea: cardArea
        width: isLibrary ? 92 : 88
        height: isLibrary ? 128 : 122
        color: Theme.surface
        radius: 8
        border.width: cardArea.hovered ? 2 : 0
        border.color: Theme.accent
        Image {
            anchors.fill: parent
            anchors.margins: 4
            source: cardImage !== "" ? "image://emby/" + cardImage : ""
            fillMode: Image.PreserveAspectCrop
            cache: true
        }
        Text {
            visible: cardImage === ""
            anchors.centerIn: parent
            text: cardText
            color: Theme.textPrimary
            font.pixelSize: isLibrary ? 15 : 11
            font.bold: isLibrary
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            width: parent.width - 8
            wrapMode: Text.Wrap
        }
        MouseArea {
            id: cardArea
            anchors.fill: parent
            hoverEnabled: true
        }
    }

    // 轮盘选择:ListView 垂直滚动,当前项(highlight)强制居中;
    // 每行缩放/透明度由"行中心到视口中心的距离"动态决定(中间最大,
    // 两端逐级缩小变暗),滚轮/拖拽滚动,任意行(含第一个媒体库)可滚到中间。
    ListView {
        id: list
        anchors.fill: parent
        clip: true
        model: root.loopRows
        spacing: 12
        // 选中项(highlight)固定在视口中心,滚动时 currentIndex 随之更新。
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: 0.5
        preferredHighlightEnd: 0.5
        snapMode: ListView.SnapToItem

        // 无限循环:滚出中间副本边界时瞬间跳回对应项(前后内容相同,视觉无缝)。
        onCurrentIndexChanged: {
            const n = root.rows.length
            if (n === 0)
                return
            const idx = list.currentIndex
            if (idx < n)
                list.positionViewAtIndex(idx + n, ListView.Center)
            else if (idx >= n * 2)
                list.positionViewAtIndex(idx - n, ListView.Center)
        }

        delegate: Column {
            id: rowDelegate
            width: list.width
            transformOrigin: Item.Top

            // 行中心到视口中心的距离(随滚动变化)驱动缩放与透明度。
            function centerDist() {
                const centerY = rowDelegate.y + rowDelegate.height / 2 - list.contentY
                return Math.abs(centerY - list.height / 2)
            }
            scale: {
                const maxDist = Math.max(1, list.height / 2 - 60)
                return Math.max(0.5, 1 - 0.16 * rowDelegate.centerDist() / maxDist)
            }
            opacity: {
                const maxDist = Math.max(1, list.height / 2 - 60)
                return Math.max(0.25, 1 - 0.75 * rowDelegate.centerDist() / maxDist)
            }

            // 行标题
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: modelData.viewName
                color: Theme.textPrimary
                font.pixelSize: 14
                font.bold: true
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 10
                // 库海报(行首)
                RowCard {
                    cardImage: modelData.posterId || ""
                    cardText: modelData.viewName
                    isLibrary: true
                    cardArea.onClicked: root.openLibrary()
                }
                // 该库最近条目
                Repeater {
                    model: modelData.items
                    delegate: RowCard {
                        cardImage: modelData.posterId || ""
                        cardText: modelData.name
                        cardArea.onClicked: root.showDetail(modelData.id, modelData.posterId || "", modelData.name)
                    }
                }
            }
        }
    }
}
