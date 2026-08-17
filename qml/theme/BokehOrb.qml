import QtQuick
import QtQuick.Shapes
import MoePlayer.Core

//! 柔焦光斑粒子:径向渐变圆 + 缓慢漂移/呼吸缩放,用作背景装饰。
//! 本身没有绝对位置,由父级(MoeBackground)设定 x/y;漂移是相对于初始
//! 位置的偏移,避免与父级布局冲突。
Item {
    id: root

    property real orbSize: 240
    property real baseOpacity: 0.14
    property real minScale: 0.85
    property real maxScale: 1.15
    property real driftX: 60
    property real driftY: 40
    property real breatheDuration: 6000
    property real driftDuration: 20000
    property color orbColor: Constants.moePink

    width: orbSize
    height: orbSize

    Rectangle {
        anchors.centerIn: parent
        width: root.orbSize
        height: root.orbSize
        radius: width / 2
        color: "transparent"
        opacity: root.baseOpacity
        transformOrigin: Item.Center

        gradient: RadialGradient {
            centerX: 0.5
            centerY: 0.5
            centerRadius: 0.5
            GradientStop { position: 0.0; color: root.orbColor }
            GradientStop { position: 1.0; color: "transparent" }
        }

        SequentialAnimation on scale {
            loops: Animation.Infinite
            NumberAnimation { from: root.minScale; to: root.maxScale; duration: root.breatheDuration / 2; easing.type: Easing.InOutSine }
            NumberAnimation { from: root.maxScale; to: root.minScale; duration: root.breatheDuration / 2; easing.type: Easing.InOutSine }
        }

        SequentialAnimation on x {
            loops: Animation.Infinite
            NumberAnimation { from: -root.driftX / 2; to: root.driftX / 2; duration: root.driftDuration / 2; easing.type: Easing.InOutSine }
            NumberAnimation { from: root.driftX / 2; to: -root.driftX / 2; duration: root.driftDuration / 2; easing.type: Easing.InOutSine }
        }

        SequentialAnimation on y {
            loops: Animation.Infinite
            NumberAnimation { from: -root.driftY / 2; to: root.driftY / 2; duration: root.driftDuration / 2; easing.type: Easing.InOutSine }
            NumberAnimation { from: root.driftY / 2; to: -root.driftY / 2; duration: root.driftDuration / 2; easing.type: Easing.InOutSine }
        }
    }
}
