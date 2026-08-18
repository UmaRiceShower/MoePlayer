pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import MoePlayer.Core

// 萌系筛选胶囊:选中时带小爱心前缀,hover 粉色高亮。
Button {
    id: root
    property string label: ""
    property bool active: false
    property bool showHeart: true

    height: 30
    topPadding: 6
    bottomPadding: 6
    leftPadding: 14
    rightPadding: 14
    background: Rectangle {
        radius: 16
        color: root.active
               ? (root.hovered ? Constants.moePinkLight : Constants.moePink)
               : (root.hovered ? Theme.surface : Theme.bg)
        border.width: 1
        border.color: root.active
                       ? Constants.moePinkDark
                       : (root.hovered ? Constants.moePink : Theme.textMuted)
        // 萌系小阴影,让胶囊浮起来。
        Rectangle {
            anchors.fill: parent
            anchors.margins: -2
            radius: 18
            color: "transparent"
            border.color: Constants.moePink
            border.width: root.active ? 2 : 0
            opacity: 0.25
        }
    }
    contentItem: AppText {
        text: (root.active && root.showHeart ? "♥ " : "") + root.label
        color: "white"
        font.pixelSize: 13
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
