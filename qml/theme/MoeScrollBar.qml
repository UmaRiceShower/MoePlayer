import QtQuick
import QtQuick.Controls

ScrollBar {
    id: bar
    policy: ScrollBar.AsNeeded
    width: 10
    leftPadding: 3
    rightPadding: 3
    minimumSize: width / height
    hoverEnabled: true

    background: null
    contentItem: Rectangle {
        radius: 2
        color: (bar.pressed || bar.hovered) ? Theme.accent : Theme.accentMuted
        opacity: bar.pressed ? 0.75
               : (bar.hovered || bar.active) ? 0.55
               : 0.30
        Behavior on opacity { NumberAnimation { duration: 160 } }
        Behavior on color { ColorAnimation { duration: 160 } }
    }
}
