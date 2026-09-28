pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import MoePlayer.Core

FrostedGlass {
    id: menuBtn
    width: 32
    height: 32
    radius: 16
    blurSource: ApplicationWindow.window ? ApplicationWindow.window.background : null
    blurRadius: 4
    thickness: 12
    hoverGlow: menuArea.hovered ? 0.35 : 0.0
    Behavior on hoverGlow { NumberAnimation { duration: 150 } }

    Column {
        anchors.centerIn: parent
        spacing: 3
        Repeater {
            model: 3
            Rectangle {
                width: 3.5
                height: 3.5
                radius: 1.75
                color: Theme.textPrimary
            }
        }
    }
    MouseArea {
        id: menuArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: ApplicationWindow.window.openMainMenu(menuBtn)
    }
}
