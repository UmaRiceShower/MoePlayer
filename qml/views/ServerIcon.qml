import QtQuick
import QtQuick.Effects
import MoePlayer.Core

//! 服务器图标:统一图标(本地缓存 file:// URL,自定义或服务器默认)→
//! 名称首字。加载失败或为空时静默回退首字,不重试。
//! 加载由命令式 updateSource() 驱动(避免状态属性参与 Image.source
//! 绑定引发 QML binding-loop 误报)。
Item {
    id: root

    // 统一图标:本地缓存 file:// URL(自定义或服务器默认;空 = 名称首字)。
    property string icon: ""
    // 全部加载失败时显示的文字(名称首字等)。
    property string fallbackText: ""
    // 当前加载源(命令式更新,不参与绑定依赖链)。
    property string currentSource: ""
    onIconChanged: root.updateSource()
    Component.onCompleted: root.updateSource()

    function updateSource() {
        root.currentSource = root.icon
    }

    property int radius: 0
    Component {
        id: iconMaskEffect
        MultiEffect {
            maskEnabled: true
            maskSource: iconMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
        }
    }
    Image {
        id: iconImg
        anchors.fill: parent
        source: root.currentSource
        // 网络图异步解码,避免阻塞 UI。
        asynchronous: true
        fillMode: Image.PreserveAspectCrop
        // PreserveAspectCrop 会画到范围外(文档提示 clip 默认 false),裁掉。
        clip: true
        // 图标源通常是远大于显示尺寸的方图,只靠默认的 smooth(双线性)降采样会有
        // 明显锯齿;文档:mipmap 的降采样质量优于 smooth。
        mipmap: true
        Rectangle {
            id: iconMask
            visible: false
            anchors.fill: parent
            radius: root.radius
            layer.enabled: true
        }
        layer.enabled: root.radius > 0
        layer.smooth: true
        layer.effect: root.radius > 0 ? iconMaskEffect : null
        visible: status === Image.Ready
    }

    // 首字回退:图片未就绪(加载中/失败)时显示,就绪后被图片覆盖。
    AppText {
        anchors.centerIn: parent
        visible: iconImg.status !== Image.Ready
        text: root.fallbackText
        color: Theme.accent
        font.pixelSize: 26
        font.bold: true
    }
}
