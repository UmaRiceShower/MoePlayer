import QtQuick
import QtQuick.Window
import QtQuick.Effects
import MoePlayer.Core

//! 玻璃拟态面板:对背景内容做高斯模糊,再叠加半透明底色与粉色描边。
//! - 用作浮层/弹窗背景;SearchOverlay 用 fullSource,弹窗用 blurRect。
//! - blurSource 传入要模糊的背景 Item(如 StackView / window.contentItem);
//!   不传入时默认取当前窗口 contentItem。
Rectangle {
    id: root

    property var blurSource: Window.window ? Window.window.contentItem : null
    property rect blurRect: Qt.rect(0, 0, 0, 0)
    property real blurRadius: 32
    property color glassColor: Qt.rgba(0.08, 0.09, 0.12, 0.55)
    property color borderColor: Qt.rgba(Constants.moePink.r, Constants.moePink.g, Constants.moePink.b, 0.35)
    property bool fullSource: true

    color: "transparent"
    border.width: 0
    clip: true

    ShaderEffectSource {
        id: bgSource
        sourceItem: root.blurSource
        sourceRect: root.fullSource
                      ? Qt.rect(0, 0,
                                root.blurSource ? root.blurSource.width : 0,
                                root.blurSource ? root.blurSource.height : 0)
                      : root.blurRect
        live: true
        hideSource: false
    }

    MultiEffect {
        anchors.fill: parent
        source: bgSource
        blurEnabled: true
        blur: 1.0
        blurMax: root.blurRadius
    }

    Rectangle {
        anchors.fill: parent
        color: root.glassColor
        radius: parent.radius
        border.width: 1
        border.color: root.borderColor
    }
}
