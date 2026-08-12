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
    // 当前服务端排序(DateLastMediaAdded 在 4.9.5 条目级查询报错,不在档位内)。
    property string currentSortBy: "DateModified"
    property string currentSortOrder: "Descending"
    property bool busy: false

    // 排序档位:label 展示,key 为 Emby SortBy 值(服务端排序,切了即重查)。
    property var sortOptions: [
        { label: "加入时间", key: "DateCreated" },
        { label: "修改时间", key: "DateModified" },
        { label: "上映日期", key: "PremiereDate" },
        { label: "年份", key: "ProductionYear" },
        { label: "评分", key: "CommunityRating" },
        { label: "名称", key: "SortName" }
    ]

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
        EmbyClient.fetchItems(root.currentViewId, 0, 200, root.currentSortBy, root.currentSortOrder)
    }

    // 切换排序:服务端重查第一页。
    function changeSort(sortBy) {
        root.currentSortBy = sortBy
        EmbyClient.fetchItems(root.currentViewId, 0, 200, root.currentSortBy, root.currentSortOrder)
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
                    EmbyClient.fetchItems(root.currentViewId, 0, 200,
                                          root.currentSortBy, root.currentSortOrder)
                }
            }
            ComboBox {
                id: sortSelector
                width: 130
                model: root.sortOptions
                textRole: "label"
                // 默认修改时间(与 fetchItems 默认一致),切换即服务端重查。
                currentIndex: 1
                onActivated: function (index) {
                    root.changeSort(root.sortOptions[index].key)
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
                EmbyClient.fetchItems(root.currentViewId, m.count, 200,
                                      root.currentSortBy, root.currentSortOrder)
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
        // 加载骨架:首屏数据未到前铺占位卡,避免转圈引起布局跳动。
        Flow {
            visible: root.busy && EmbyClient.itemsModel.count === 0
            anchors.fill: parent
            spacing: 16
            Repeater {
                model: 24
                Rectangle {
                    width: 168
                    height: 252
                    radius: 8
                    color: Theme.surface
                }
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
                clip: true
                Image {
                    anchors.fill: parent
                    anchors.margins: 4
                    source: model.posterId ? "image://emby/" + model.posterId : ""
                    fillMode: Image.PreserveAspectCrop
                    cache: true
                    asynchronous: true
                }
                // 底部渐变遮罩,提升标题可读性。
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 46
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.72) }
                    }
                }
                // 标题 + 年份(第二行小字,避免长标题截断年份)。
                Column {
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottomMargin: 6
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    spacing: 1
                    Text {
                        width: parent.width
                        text: model.name
                        color: Theme.textPrimary
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }
                    Text {
                        visible: model.year > 0
                        width: parent.width
                        text: model.year
                        color: Theme.textMuted
                        font.pixelSize: 11
                    }
                }
                // 观看进度条(位置/时长随列表 UserData 返回,零额外请求)。
                Rectangle {
                    visible: model.positionTicks > 0 && model.runtimeTicks > 0
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 3
                    color: Qt.rgba(1, 1, 1, 0.25)
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.width * Math.min(1, model.positionTicks / model.runtimeTicks)
                        color: Theme.accent
                    }
                }
                // 左上:评分角标(Emby 评分 0-10)。
                Rectangle {
                    visible: model.rating >= 0.5
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.margins: 8
                    height: 22
                    width: ratingRow.implicitWidth + 12
                    radius: 4
                    color: Qt.rgba(0, 0, 0, 0.6)
                    Row {
                        id: ratingRow
                        anchors.centerIn: parent
                        spacing: 3
                        Text {
                            text: "★"
                            color: "#ffd33d"
                            font.pixelSize: 12
                        }
                        Text {
                            text: model.rating.toFixed(1)
                            color: Theme.textPrimary
                            font.pixelSize: 12
                        }
                    }
                }
                // 右上:已看绿勾 / 剧集未看集数蓝标。
                Rectangle {
                    visible: model.played || (model.type === "Series" && model.unplayedCount > 0)
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 8
                    height: 22
                    width: stateRow.implicitWidth + 12
                    radius: 4
                    color: model.played ? "#2ea043" : "#1f6feb"
                    Row {
                        id: stateRow
                        anchors.centerIn: parent
                        spacing: 3
                        Text {
                            text: model.played ? "✓ 已看"
                                 : (model.unplayedCount >= 100 ? "99+ 未看"
                                    : model.unplayedCount + " 未看")
                            color: "#ffffff"
                            font.pixelSize: 12
                        }
                    }
                }
            }
            HoverHandler {
                id: cardHover
            }
            MouseArea {
                anchors.fill: parent
                onClicked: root.showDetail(model.id, model.posterId, model.name)
            }
            // 悬停操作按钮置于最上层(MouseArea 之后声明),可点击。
            Row {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: 36
                anchors.rightMargin: 8
                visible: cardHover.hovered
                spacing: 6
                Button {
                    width: 30
                    height: 30
                    padding: 0
                    background: Rectangle { radius: 15; color: "#000000aa" }
                    contentItem: Text {
                        text: model.favorite ? "♥" : "♡"
                        color: model.favorite ? "#f778ba" : "#ffffff"
                        font.pixelSize: 16
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    onClicked: {
                        EmbyClient.setFavorite(model.id, !model.favorite)
                        EmbyClient.itemsModel.setFavoriteAt(index, !model.favorite)
                    }
                }
                Button {
                    width: 30
                    height: 30
                    padding: 0
                    background: Rectangle { radius: 15; color: model.played ? "#2ea043" : "#000000aa" }
                    contentItem: Text {
                        text: "✓"
                        color: "#ffffff"
                        font.pixelSize: 15
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    onClicked: {
                        EmbyClient.setWatched(model.id, !model.played)
                        EmbyClient.itemsModel.setPlayedAt(index, !model.played)
                    }
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
