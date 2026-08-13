import QtQuick
import MoePlayer.Core
import "qrc:/qml/theme"

//! 服务器图标:自定义图标(图片 URL)→ 服务器默认 Emby 图标 → 名称首字。
//! Emby 官方 API(openapi)无服务器图标端点;浏览器连接看到的图标是
//! web 静态资源,路径随部署不同(本地 4.9 为 /web/images/icon-192x192.png,
//! 部分部署 404)。故默认链为:web PWA 图标 → favicon → 首字回退,
//! 任一候选加载失败自动进入下一档;serverUrl 为空时不发起加载。
//! 回退由命令式 updateSource() 驱动(避免状态属性参与 source 绑定引发
//! QML binding-loop 误报)。
Item {
    id: root

    // 服务器地址(空则不加载,避免拼出无效资源路径)。
    property string serverUrl: ""
    // 用户自定义图标 URL(空 = 用服务器默认链)。
    property string customIcon: ""
    // 全部加载失败时显示的文字(名称首字等)。
    property string fallbackText: ""
    // 默认链进度:false = 尝试 PWA 图标,true = 已失败,换 favicon。
    property bool triedFavicon: false
    // 当前加载源(命令式更新,不参与绑定依赖链)。
    property string currentSource: ""

    function updateSource() {
        if (root.customIcon !== "")
            root.currentSource = root.customIcon
        else if (root.serverUrl === "")
            root.currentSource = ""
        else if (!root.triedFavicon)
            root.currentSource = root.serverUrl + "/web/images/icon-192x192.png"
        else
            root.currentSource = root.serverUrl + "/web/favicon.ico"
    }
    onServerUrlChanged: {
        root.triedFavicon = false
        root.updateSource()
    }
    onCustomIconChanged: {
        root.triedFavicon = false
        root.updateSource()
    }
    Component.onCompleted: root.updateSource()

    Image {
        id: iconImg
        anchors.fill: parent
        source: root.currentSource
        fillMode: Image.PreserveAspectCrop
        visible: status === Image.Ready
        onStatusChanged: {
            if (status !== Image.Error || root.customIcon !== "" || root.triedFavicon)
                return // 自定义图失败:保持失败态显示首字;favicon 失败:停止
            root.triedFavicon = true
            root.updateSource()
        }
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
