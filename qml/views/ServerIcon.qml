import QtQuick
import MoePlayer.Core

//! 服务器图标:自定义图标(图片 URL)→ 服务器默认图标 → 名称首字。
//! 服务器默认图标在添加服务器时浏览器式解析一次(见
//! EmbyClient.fetchServerIcon,结果存账号 serverIcon 字段),此后不再
//! 拉取;解析失败或加载失败静默回退首字,不重试。
//! 加载由命令式 updateSource() 驱动(避免状态属性参与 Image.source
//! 绑定引发 QML binding-loop 误报)。
Item {
    id: root

    // 用户自定义图标 URL(空 = 用服务器默认图标)。
    property string customIcon: ""
    // 服务器默认图标(添加服务器时解析,账号 serverIcon 字段)。
    property string defaultIcon: ""
    // 全部加载失败时显示的文字(名称首字等)。
    property string fallbackText: ""
    // 当前加载源(命令式更新,不参与绑定依赖链)。
    property string currentSource: ""
    onCustomIconChanged: root.updateSource()
    onDefaultIconChanged: root.updateSource()
    Component.onCompleted: root.updateSource()

    function updateSource() {
        root.currentSource = root.customIcon !== "" ? root.customIcon : root.defaultIcon
    }

    Image {
        id: iconImg
        anchors.fill: parent
        source: root.currentSource
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
