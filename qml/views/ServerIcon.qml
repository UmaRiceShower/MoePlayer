import QtQuick
import MoePlayer.Core
import "qrc:/qml/theme"

//! 服务器图标:自定义图标(图片 URL)→ 服务器默认图标 → 名称首字。
//! 服务器默认图标按浏览器 favicon 获取逻辑(HTML Living Standard)解析:
//! C++ 侧拉取 web 首页 HTML、解析 <link rel="icon"> 标签并回退
//! /favicon.ico(见 EmbyClient.fetchServerIcon/AccountManager.serverIconFor),
//! 结果缓存持久化,经 serverIconsChanged 通知本组件刷新。
//! 加载由命令式 updateSource() 驱动(避免状态属性参与 Image.source 绑定
//! 引发 QML binding-loop 误报);serverUrl 为空时不发起加载。
Item {
    id: root

    // 服务器地址(空则不加载,避免拼出无效资源路径)。
    property string serverUrl: ""
    // 用户自定义图标 URL(空 = 用服务器默认图标)。
    property string customIcon: ""
    // 全部加载失败时显示的文字(名称首字等)。
    property string fallbackText: ""
    // 服务器默认图标(浏览器式解析结果,内部维护)。
    property string defaultIcon: ""
    // 当前加载源(命令式更新,不参与绑定依赖链)。
    property string currentSource: ""

    function refreshDefault() {
        root.defaultIcon = AccountManager.serverIconFor(root.serverUrl)
        root.updateSource()
    }
    function updateSource() {
        root.currentSource = root.customIcon !== "" ? root.customIcon : root.defaultIcon
    }
    onServerUrlChanged: {
        root.defaultIcon = ""
        root.refreshDefault()
    }
    onCustomIconChanged: root.updateSource()
    onDefaultIconChanged: root.updateSource()
    Component.onCompleted: {
        root.refreshDefault()
        root.updateSource()
    }

    // 服务器图标解析完成(启动/添加账号后台拉取):刷新默认图标。
    Connections {
        target: AccountManager
        function onServerIconsChanged() {
            root.refreshDefault()
        }
    }

    Image {
        id: iconImg
        anchors.fill: parent
        source: root.currentSource
        fillMode: Image.PreserveAspectCrop
        visible: status === Image.Ready
        onStatusChanged: {
            // 服务器默认图标加载失败(404/网络错误):记入失败记忆,
            // 之后 serverIconFor 返回空,本会话与后续启动都不再加载;
            // 用户自定义图标失败不记录(重新设置即可重试)。
            if (status === Image.Error
                && root.currentSource !== ""
                && root.currentSource === root.defaultIcon)
                AccountManager.markServerIconFailed(root.serverUrl, root.defaultIcon)
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
