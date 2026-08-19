import QtQuick
import QtQuick.Controls

// 官方 OSC 风格图标按钮:白图标,悬停微亮;可选图标右侧内联文本
// (官方 audio/sub 按钮的 "1/2" 轨道编号);右键触发 secondaryClicked
// (官方 select/* 菜单,本项目映射到设置弹窗)。
Button {
    id: btn

    property string oscIcon: ""
    property string inlineText: ""
    property color iconColor: "white"
    property real iconScale: 0.72
    // 悬停微亮(官方无 hover 高亮,仅 active 变色;此处保留轻反馈)。
    property color hoverColor: Qt.rgba(1, 1, 1, 0.15)

    signal secondaryClicked()

    implicitWidth: 27
    implicitHeight: 29

    background: Rectangle {
        color: btn.hovered ? btn.hoverColor : "transparent"
    }

    contentItem: Row {
        spacing: 4
        OscIcon {
            id: oscIco
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(btn.width, btn.height) * btn.iconScale
            height: width
            icon: btn.oscIcon
            color: btn.iconColor
        }
        AppText {
            anchors.verticalCenter: parent.verticalCenter
            visible: btn.inlineText !== ""
            text: btn.inlineText
            color: btn.iconColor
            font.pixelSize: 12
            horizontalAlignment: Text.AlignLeft
        }
    }

    // 右键:Button 无右键信号,补一个只接收右键的 MouseArea。
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onPressed: function (mouse) {
            if (mouse.button === Qt.RightButton)
                btn.secondaryClicked()
        }
    }
}
