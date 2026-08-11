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

    // 行缩放:中间 1.0,向两端线性递减(mid 实时计算,避免属性绑定不刷新)。
    function rowScale(i) {
        const len = root.rows.length
        if (len <= 1)
            return 1.0
        const mid = Math.floor(len / 2)
        const maxDist = Math.max(mid, len - 1 - mid)
        return 1.0 - 0.16 * Math.abs(i - mid) / maxDist
    }
    // 行透明度:随缩放递减(最小 0.35)。
    function rowOpacity(i) {
        return 0.35 + 0.65 * root.rowScale(i)
    }

    Component.onCompleted: EmbyClient.fetchHomeRows(7)
    Connections {
        target: EmbyClient
        // 登录成功即拉视图(Home 为首页时 Library 未必实例化,流程在此闭环)。
        function onLoginSucceeded() { EmbyClient.fetchViews() }
        // 视图就绪 → 重建首页行。
        function onViewsReceived() { EmbyClient.fetchHomeRows(7) }
        function onHomeRowsReceived() { root.rows = EmbyClient.homeRows }
    }

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

    Flickable {
        anchors.fill: parent
        clip: true
        contentHeight: homeColumn.height

        Column {
            id: homeColumn
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 10
            padding: 16

            Repeater {
                model: root.rows
                delegate: Column {
                    // 行级缩放/透明度:index 即行号,整行(标题+卡片)一并缩放。
                    scale: root.rowScale(index)
                    opacity: root.rowOpacity(index)
                    transformOrigin: Item.Top
                    // 行标题
                    Text {
                        text: modelData.viewName
                        color: Theme.textPrimary
                        font.pixelSize: 14
                        font.bold: true
                    }
                    Row {
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
    }
}
