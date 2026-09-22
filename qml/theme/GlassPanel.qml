import QtQuick
import QtQuick.Window
import QtQuick.Effects
import MoePlayer.Core

//! 玻璃拟态面板:对整个背景源做高斯模糊,再叠加半透明底色与描边。
//! - 用作浮层/弹窗背景。
//! - blurSource 传入要模糊的背景 Item(如 StackView / window.contentItem);
//!   不传入时默认取当前窗口 contentItem。
Rectangle {
    id: root

    property var blurSource: Window.window ? Window.window.contentItem : null
    property real blurRadius: 32
    property color glassColor: Qt.rgba(Theme.scrimSoft.r, Theme.scrimSoft.g, Theme.scrimSoft.b, 0.55)
    property color borderColor: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.35)

    color: "transparent"
    border.width: 0
    clip: true

    ShaderEffectSource {
        id: bgSource
        sourceItem: root.blurSource
        sourceRect: Qt.rect(0, 0,
                            root.blurSource ? root.blurSource.width : 0,
                            root.blurSource ? root.blurSource.height : 0)
        // 降低采样分辨率,让高斯模糊更明显、性能更好。
        textureSize: Qt.size(
            root.blurSource ? Math.max(1, root.blurSource.width / 2) : 1,
            root.blurSource ? Math.max(1, root.blurSource.height / 2) : 1)
        live: true
        hideSource: false
    }

    MultiEffect {
        anchors.fill: parent
        source: bgSource
        autoPaddingEnabled: false
        blurEnabled: true
        blur: 1.0
        blurMax: root.blurRadius
        layer.enabled: true
        layer.effect: ShaderEffect {
            property real u_radius: root.radius
            property size u_size: Qt.size(width, height)
            fragmentShader: "qrc:/qt/qml/MoePlayer/Core/shaders/round-rect.frag.qsb"
        }
    }

    Rectangle {
        anchors.fill: parent
        color: root.glassColor
        radius: parent.radius
        border.width: 1
        border.color: root.borderColor
    }

    // 顶部微光(玻璃感的高光层):随自身 radius 裁切,亮色系掺黑。
    Rectangle {
        anchors.fill: parent
        radius: root.radius
        gradient: Gradient {
            GradientStop { position: 0.0; color: ThemeStore.isLight ? Qt.rgba(0, 0, 0, 0.035)
                                                                    : Qt.rgba(1, 1, 1, 0.08) }
            GradientStop { position: 0.5; color: "transparent" }
        }
    }
}
