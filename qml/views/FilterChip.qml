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
               ? (root.hovered ? Theme.accentHover : Theme.accent)
               : (root.hovered ? Theme.surface : Theme.bg)
        border.width: 1
        border.color: root.active
                       ? Theme.accentDeep
                       : (root.hovered ? Theme.accent : Theme.textMuted)
    }
    contentItem: AppText {
        text: root.label
        color: root.active ? Theme.accentInk : Theme.textPrimary
        font.pixelSize: 13
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
