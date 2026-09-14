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
    property color glassColor: Qt.rgba(Theme.scrimSoft.r, Theme.scrimSoft.g, Theme.scrimSoft.b, 0.55)
    property color borderColor: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.35)
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
        // 只裁圆角:MultiEffect 的 source 铺满矩形,若不遮罩会露出方角;
        // maskSource 用白底圆角矩形的 alpha 通道,把模糊裁到 root.radius。
        maskEnabled: true
        maskSource: bgMask
    }

    // 圆角遮罩采样:ShaderEffectSource 采样白底圆角矩形,用其 alpha 通道作 mask;
    // hideSource 让该矩形从场景隐藏,避免显示成一块白色。
    ShaderEffectSource {
        id: bgMask
        sourceItem: maskRect
        hideSource: true
        visible: false
    }
    Rectangle {
        id: maskRect
        anchors.fill: parent
        radius: root.radius
        color: "white"
    }

    Rectangle {
        anchors.fill: parent
        color: root.glassColor
        radius: parent.radius
        border.width: 1
        border.color: root.borderColor
    }
}
