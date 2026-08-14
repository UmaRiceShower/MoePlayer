import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import "qrc:/qml/theme"

//! 全局搜索浮层(Ctrl+K 开关):按最近浏览的服务器搜索(主窗口注入 serverUrl),
//! 服务端搜索跨库递归(影片/剧集/单集),输入 300ms 防抖后请求,
//! 结果网格点击进详情;Esc / 点击背景关闭。
Item {
    id: root

    // 搜索目标服务器(主窗口按最近浏览的页面注入;空则不可搜索)。
    property string serverUrl: ""
    // 该服务器的搜索结果模型(serverUrl 就绪后一次性取引用)。
    property var sm: null
    readonly property bool canSearch: root.serverUrl !== "" && root.creds().token !== ""

    // 点击结果进详情(携带所在服务器)。
    signal showDetail(string itemId, string posterId, string title, string serverUrl)

    onServerUrlChanged: {
        if (root.serverUrl !== "")
            root.sm = EmbyClient.searchModelFor(root.serverUrl)
    }

    function creds() {
        return AccountManager.credsForServer(root.serverUrl)
    }

    // 打开:清空旧结果并聚焦输入框。
    function open() {
        root.visible = true
        searchField.text = ""
        if (root.canSearch) {
            const c = root.creds()
            EmbyClient.search(root.serverUrl, c.token, c.userId, "")
        }
        searchField.forceActiveFocus()
    }
    function close() {
        root.visible = false
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }
    }

    Rectangle {
        anchors.top: parent.top
        anchors.topMargin: 48
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(760, parent.width - 64)
        height: parent.height - 96
        radius: 12
        color: Theme.surface

        Column {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 12

            TextField {
                id: searchField
                width: parent.width
                height: 40
                placeholderText: root.canSearch ? "搜索影片 / 剧集 / 单集(Esc 关闭)"
                                                : "先在首页打开一个媒体库再搜索(Esc 关闭)"
                enabled: root.canSearch
                font.pixelSize: 15
                // 输入防抖:停止输入 300ms 后才发服务端搜索。
                onTextChanged: searchDebounce.restart()
            }

            // 未输入提示。
            AppText {
                visible: root.canSearch && searchField.text.length === 0
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.topMargin: 32
                text: "输入关键词,搜索当前服务器的全部媒体库"
                color: Theme.textMuted
                font.pixelSize: 14
            }
            // 已搜索无结果。
            AppText {
                visible: root.canSearch && searchField.text.length > 0 && root.sm && root.sm.count === 0
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.topMargin: 32
                text: "无匹配结果"
                color: Theme.textMuted
                font.pixelSize: 14
            }

            GridView {
                id: resultGrid
                width: parent.width
                height: parent.height - 52
                clip: true
                cellWidth: Constants.cellW
                cellHeight: Constants.cellH
                model: root.sm
                // 搜索结果轻量卡片:无需悬停操作按钮,点击进详情。
                delegate: PosterCard {
                    width: 152
                    height: 236
                    showActions: false
                    itemId: model.id
                    posterId: model.posterId
                    title: model.name
                    year: model.year
                    rating: model.rating
                    played: model.played
                    favorite: model.favorite
                    positionTicks: model.positionTicks
                    runtimeTicks: model.runtimeTicks
                    unplayedCount: model.unplayedCount
                    itemType: model.type
                    onClicked: root.showDetail(model.id, model.posterId, model.name, root.serverUrl)
                }
            }
        }
    }

    // 输入防抖定时器。
    Timer {
        id: searchDebounce
        interval: Constants.searchDebounceMs
        onTriggered: {
            if (root.canSearch) {
                const c = root.creds()
                EmbyClient.search(root.serverUrl, c.token, c.userId, searchField.text)
            }
        }
    }

    // Esc 关闭。
    Shortcut {
        sequence: "Esc"
        onActivated: root.close()
    }
}
