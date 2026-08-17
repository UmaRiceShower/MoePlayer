import QtQuick
import MoePlayer.Core

//! 萌系动态极光背景:全屏 ShaderEffect,深色底 + 缓慢流动的粉紫光斑。
//! 作为 ApplicationWindow.background 使用,位于 StackView 之后。
Item {
    id: root

    // 动画时间,驱动 shader 内光斑漂移;周期约 200 秒,肉眼几乎无感。
    property real u_time: 0.0

    // 循环动画:数值很大时精度足够,周期结束自然衔接。
    NumberAnimation on u_time {
        loops: Animation.Infinite
        from: 0
        to: 10000
        duration: 2000000
    }

    ShaderEffect {
        anchors.fill: parent
        property real u_time: root.u_time
        fragmentShader: "qrc:/qt/qml/MoePlayer/Core/shaders/aurora.frag.qsb"
    }

    // 柔焦光斑:低透明度、缓慢漂移 + 呼吸缩放,营造梦幻氛围。
    // 位置按父级尺寸百分比分布,不随窗口 resize 跑偏。
    BokehOrb {
        x: parent.width * 0.12 - width / 2
        y: parent.height * 0.25 - height / 2
        orbSize: 280
        baseOpacity: 0.12
        driftX: 80
        driftY: 50
        driftDuration: 24000
        breatheDuration: 7000
        orbColor: Constants.moePink
    }
    BokehOrb {
        x: parent.width * 0.78 - width / 2
        y: parent.height * 0.15 - height / 2
        orbSize: 360
        baseOpacity: 0.10
        driftX: 60
        driftY: 70
        driftDuration: 30000
        breatheDuration: 9000
        orbColor: Constants.moePinkLight
    }
    BokehOrb {
        x: parent.width * 0.65 - width / 2
        y: parent.height * 0.70 - height / 2
        orbSize: 320
        baseOpacity: 0.10
        driftX: 70
        driftY: 40
        driftDuration: 26000
        breatheDuration: 8000
        orbColor: Qt.rgba(0.78, 0.55, 0.85, 1.0)
    }
    BokehOrb {
        x: parent.width * 0.25 - width / 2
        y: parent.height * 0.80 - height / 2
        orbSize: 220
        baseOpacity: 0.08
        driftX: 50
        driftY: 60
        driftDuration: 22000
        breatheDuration: 6000
        orbColor: Constants.moePink
    }
}
