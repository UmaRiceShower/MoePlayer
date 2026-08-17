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
}
