import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import "qrc:/qml/theme"

//! 媒体库主界面:连接 Emby 服务器(公开信息/登录)、浏览视图与影片、发起播放;
//! 播放请求经 playRequested 信号交给主窗口,在独立播放窗口中执行。
Item {
    id: root

    signal playRequested(string url, var headers, var meta)
    // 点击条目进入详情页。
    signal showDetail(string itemId, string posterId, string title)

    property bool busy: false
    // 当前浏览的视图 id(分页加载用)。
    property string currentViewId: ""

    function connectServer() {
        EmbyClient.serverUrl = serverField.text
        root.busy = true
        statusText.text = "正在连接…"
        if (userField.text.length > 0 || passField.text.length > 0)
            EmbyClient.login(userField.text, passField.text)
        else
            EmbyClient.fetchPublicInfo()
    }

    Column {
        anchors.fill: parent
        spacing: 16
        padding: 24

        Text {
            text: "媒体库"
            color: Theme.textPrimary
            font.pixelSize: 28
            font.bold: true
        }

        // --- connection ---
        Row {
            spacing: 10
            TextField {
                id: serverField
                width: 340
                placeholderText: "服务器地址 (http://host:8096)"
                text: EmbyClient.serverUrl
                onEditingFinished: EmbyClient.serverUrl = text
            }
            TextField {
                id: userField
                width: 150
                placeholderText: "用户名"
            }
            TextField {
                id: passField
                width: 150
                placeholderText: "密码"
                echoMode: TextInput.Password
            }
            Button {
                text: EmbyClient.connected ? "断开" : "连接"
                enabled: !root.busy
                onClicked: {
                    if (EmbyClient.connected) {
                        EmbyClient.disconnectServer()
                        statusText.text = ""
                        return
                    }
                    root.connectServer()
                }
            }
        }

        Text {
            id: statusText
            text: ""
            color: statusText.text.indexOf("失败") >= 0 ? "#e5534b" : Theme.textMuted
        }

        // --- views (visible when connected) ---
        Row {
            visible: EmbyClient.connected
            spacing: 8
            Repeater {
                model: EmbyClient.viewsModel
                Button {
                    text: model.name
                    onClicked: {
                        root.currentViewId = model.id
                        EmbyClient.fetchItems(model.id, 0, 200)
                    }
                }
            }
        }

        // --- movie grid (visible when connected) ---
        GridView {
            id: grid
            visible: EmbyClient.connected
            width: parent.width
            height: 360
            cellWidth: 176
            cellHeight: 260
            clip: true
            model: EmbyClient.itemsModel
            // 滚动到底部且还有未加载条目时,加载下一页(Emby 单页上限 200)。
            onAtYEndChanged: {
                if (!atYEnd)
                    return
                const m = EmbyClient.itemsModel
                if (root.currentViewId !== "" && m.count < m.totalCount && !root.busy) {
                    root.busy = true
                    EmbyClient.fetchItems(root.currentViewId, m.count, 200)
                }
            }
            BusyIndicator {
                anchors.centerIn: parent
                running: root.busy && grid.visible
            }
            delegate: Item {
                width: 168
                height: 252
                Rectangle {
                    anchors.fill: parent
                    color: Theme.surface
                    radius: 8
                    Image {
                        anchors.fill: parent
                        anchors.margins: 4
                        source: model.posterId ? "image://emby/" + model.posterId : ""
                        fillMode: Image.PreserveAspectCrop
                        cache: true
                    }
                    Text {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: 8
                        text: model.name
                        color: Theme.textPrimary
                        elide: Text.ElideRight
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.showDetail(model.id, model.posterId, model.name)
                }
            }
        }
    }

    // EmbyClient 异步结果:按信号推进连接状态并更新界面。
    Connections {
        target: EmbyClient
        function onPublicInfoReceived() {
            if (!EmbyClient.connected)
                statusText.text = "服务器：" + EmbyClient.serverName + " v" + EmbyClient.serverVersion
                                   + "（未登录，仅显示公开信息）"
            root.busy = false
        }
        function onLoginSucceeded() {
            statusText.text = "已连接：" + EmbyClient.serverName + " v" + EmbyClient.serverVersion
                              + " · " + EmbyClient.userName
            EmbyClient.fetchViews()
        }
        function onViewsReceived() {
            if (EmbyClient.viewsModel.count > 0) {
                root.currentViewId = EmbyClient.viewsModel.idAt(0)
                EmbyClient.fetchItems(root.currentViewId, 0, 200)
            }
            root.busy = false
        }
        function onItemsReceived() {
            statusText.text = "已加载 " + EmbyClient.itemsModel.count + " / "
                              + EmbyClient.itemsModel.totalCount + " 个条目"
            root.busy = false
        }
        function onErrorOccurred(message) {
            root.busy = false
            statusText.text = "失败：" + message
        }
        // 实时通道状态(连接成功后建立)。
        function onWsConnectedChanged() {
            if (EmbyClient.wsConnected)
                statusText.text = "实时通道已连接"
        }
    }
}
