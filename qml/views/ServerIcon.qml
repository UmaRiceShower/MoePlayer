import QtQuick
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

    Image {
        id: iconImg
        anchors.fill: parent
        source: root.currentSource
        // 网络图异步解码,避免阻塞 UI。
        asynchronous: true
        fillMode: Image.PreserveAspectCrop
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
