import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import "qrc:/qml/theme"

//! 媒体库主界面:专注展示当前选中的媒体库条目(分页网格)。
//! 顶部一行选择媒体库(下拉),主体为条目网格;未连接时显示连接表单兜底登录。
//! 播放/详情请求经信号交给主窗口处理。
Item {
    id: root

    signal playRequested(string url, var headers, var meta)
    // 点击条目进入详情页。
    signal showDetail(string itemId, string posterId, string title)

    // 进入页面时选中的媒体库 id(首页点某库海报时传入;空则默认第一个)。
    property string initialViewId: ""
    // 当前浏览的视图 id(分页加载用)。
    property string currentViewId: ""
    property bool busy: false

    // 选中媒体库并加载条目:优先匹配 preferredId,未匹配(视图未就绪/不存在)
    // 回退第一个;视图未就绪时保持待选,onViewsReceived 到达后再应用。
    function applyView(preferredId) {
        const vm = EmbyClient.viewsModel
        if (vm.count === 0)
            return
        let idx = 0
        for (let i = 0; i < vm.count; ++i) {
            if (vm.idAt(i) === preferredId) {
                idx = i
                break
            }
        }
        viewSelector.currentIndex = idx
        root.currentViewId = vm.idAt(idx)
        EmbyClient.fetchItems(root.currentViewId, 0, 200)
    }

    function connectServer() {
        EmbyClient.serverUrl = serverField.text
        root.busy = true
        statusText.text = "正在连接…"
        if (userField.text.length > 0 || passField.text.length > 0)
            EmbyClient.login(userField.text, passField.text)
        else
            EmbyClient.fetchPublicInfo()
    }

    // 进入页面:会话已在(自动登录/切换账号)则载入目标库;未登录则用当前
    // 账号信息预填连接表单(密码仅已保存时填入),便于重登。
    Component.onCompleted: {
        if (EmbyClient.connected)
            root.applyView(root.initialViewId)
        else if (AccountManager.activeAccountId !== "") {
            serverField.text = EmbyClient.serverUrl
            const acc = AccountManager.accounts
            for (const a of acc) {
                if (a.id === AccountManager.activeAccountId) {
                    userField.text = a.userName
                    passField.text = AccountManager.passwordFor(a.id)
                    break
                }
            }
        }
    }

    // 头部:标题 + 连接表单(未连接)/ 媒体库选择(已连接)。
    Column {
        id: headerCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 12
        padding: 24

        Text {
            text: "媒体库"
            color: Theme.textPrimary
            font.pixelSize: 28
            font.bold: true
        }

        // --- 连接表单(未连接时) ---
        Row {
            visible: !EmbyClient.connected
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
                text: "连接"
                enabled: !root.busy
                onClicked: root.connectServer()
            }
        }

        // --- 媒体库选择(已连接时) ---
        Row {
            visible: EmbyClient.connected
            spacing: 12
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: EmbyClient.serverName + " · " + EmbyClient.userName
                color: Theme.textMuted
                font.pixelSize: 13
            }
            ComboBox {
                id: viewSelector
                width: 320
                model: EmbyClient.viewsModel
                textRole: "name"
                onActivated: function (index) {
                    root.currentViewId = EmbyClient.viewsModel.idAt(index)
                    EmbyClient.fetchItems(root.currentViewId, 0, 200)
                }
            }
            Button {
                text: "断开"
                onClicked: EmbyClient.disconnectServer()
            }
        }

        Text {
            id: statusText
            text: ""
            color: statusText.text.indexOf("失败") >= 0 ? "#e5534b" : Theme.textMuted
        }
    }

    // 主体:选中媒体库的条目网格(填充头部以下空间)。
    GridView {
        id: grid
        visible: EmbyClient.connected
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: headerCol.bottom
        anchors.bottom: parent.bottom
        anchors.leftMargin: 24
        anchors.rightMargin: 24
        anchors.bottomMargin: 24
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
        // 空库提示。
        Text {
            visible: EmbyClient.itemsModel.count === 0 && !root.busy
            anchors.centerIn: parent
            text: "该媒体库暂无条目"
            color: Theme.textMuted
            font.pixelSize: 16
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
        // 视图就绪(登录/切换账号后异步到达):应用目标库,未指定则第一个。
        function onViewsReceived() {
            if (EmbyClient.viewsModel.count > 0)
                root.applyView(root.initialViewId)
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
