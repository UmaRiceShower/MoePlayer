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
    // 离开页面时保存浏览状态(由主窗口存下,再次进入经 restore 恢复)。
    signal libraryStateSaved(var state)

    // 进入页面时选中的媒体库 id(首页点某库海报时传入;空则默认第一个)。
    property string initialViewId: ""
    // 上次离开时的浏览状态(viewId/排序/滚动位置),恢复用。
    property var restore: null
    // 首屏数据就绪后要恢复的滚动位置(恢复时 onItemsReceived 消费一次)。
    property real pendingRestoreY: 0
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
        EmbyClient.fetchItems(root.currentViewId, 0, Constants.pageSize, root.currentSortBy, root.currentSortOrder)
    }

    // 切换排序:服务端重查第一页。
    function changeSort(sortBy) {
        root.currentSortBy = sortBy
        EmbyClient.fetchItems(root.currentViewId, 0, Constants.pageSize, root.currentSortBy, root.currentSortOrder)
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
        if (EmbyClient.connected) {
            if (root.restore && root.restore.viewId !== "") {
                // 恢复上次浏览状态:视图/排序/滚动位置,重拉后定位。
                root.currentSortBy = root.restore.sortBy
                root.currentSortOrder = root.restore.sortOrder
                for (let i = 0; i < root.sortOptions.length; ++i) {
                    if (root.sortOptions[i].key === root.restore.sortBy) {
                        sortSelector.currentIndex = i
                        break
                    }
                }
                root.pendingRestoreY = root.restore.contentY || 0
                root.applyView(root.restore.viewId)
            } else {
                root.applyView(root.initialViewId)
            }
        } else if (AccountManager.activeAccountId !== "") {
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

    // 离开页面(pop 销毁)前保存浏览状态:视图/排序/滚动位置。
    Component.onDestruction: {
        if (root.currentViewId !== "")
            root.libraryStateSaved({
                viewId: root.currentViewId,
                sortBy: root.currentSortBy,
                sortOrder: root.currentSortOrder,
                contentY: grid.contentY
            })
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
                    EmbyClient.fetchItems(root.currentViewId, 0, Constants.pageSize,
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
            color: statusText.text.indexOf("失败") >= 0 ? Theme.danger : Theme.textMuted
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
        cellWidth: Constants.cellW
        cellHeight: Constants.cellH
        clip: true
        model: EmbyClient.itemsModel
        // 滚动到底部且还有未加载条目时,加载下一页(Emby 单页上限 200)。
        onAtYEndChanged: {
            if (!atYEnd)
                return
            const m = EmbyClient.itemsModel
            if (root.currentViewId !== "" && m.count < m.totalCount && !root.busy) {
                root.busy = true
                EmbyClient.fetchItems(root.currentViewId, m.count, Constants.pageSize,
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
                    width: Constants.cardW
                    height: Constants.cardH
                    radius: 8
                    color: Theme.surface
                }
            }
        }
        BusyIndicator {
            anchors.centerIn: parent
            running: root.busy && grid.visible
        }
        delegate: PosterCard {
            width: Constants.cardW
            height: Constants.cardH
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
            onClicked: root.showDetail(model.id, model.posterId, model.name)
            onFavoriteRequested: function (id, fav) {
                EmbyClient.setFavorite(id, fav)
                EmbyClient.itemsModel.setFavoriteById(id, fav)
            }
            onWatchedRequested: function (id, played) {
                EmbyClient.setWatched(id, played)
                EmbyClient.itemsModel.setPlayedById(id, played)
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
            // 恢复浏览位置:重拉完成后定位到上次离开处(clamp 到可滚范围),
            // 后续触底自动补页。仅消费一次。
            if (root.pendingRestoreY > 0) {
                const y = Math.min(root.pendingRestoreY, grid.contentHeight - grid.height)
                if (y > 0)
                    grid.contentY = y
                root.pendingRestoreY = 0
            }
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
