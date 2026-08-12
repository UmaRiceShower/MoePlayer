import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import "qrc:/qml/theme"

//! 媒体库主界面:专注展示某服务器的指定媒体库条目(分页网格)。
//! 浏览无状态化:serverUrl 为目标服务器,所有请求经
//! AccountManager.credsForServer 取凭据按服务器路由,不依赖任何会话;
//! 无账号/凭据失效时显示连接表单(直连登录 = 添加账号)。
//! 顶部一行选择媒体库(下拉),主体为条目网格;播放/详情经信号交给主窗口。
Item {
    id: root

    signal playRequested(string url, var headers, var meta)
    // 点击条目进入详情页(携带所在服务器)。
    signal showDetail(string itemId, string posterId, string title, string serverUrl)
    // 离开页面时保存浏览状态(由主窗口存下,再次进入经 restore 恢复)。
    signal libraryStateSaved(var state)

    // 进入页面时选中的媒体库 id(首页点某库海报时传入;空则默认第一个)。
    property string initialViewId: ""
    // 浏览目标服务器(从首页/主窗口传入;空则默认第一个有效账号)。
    property string serverUrl: ""
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
    // 该服务器的视图/条目模型(浏览绑定,页面生命周期内一次性取引用)。
    property var vm: null
    property var im: null

    // 该服务器凭据(账号缺失/失效返回空 map → 显示连接表单)。
    function creds() {
        return AccountManager.credsForServer(root.serverUrl)
    }
    // 可浏览 = 有服务器且凭据有效。
    readonly property bool browseReady: root.serverUrl !== "" && root.creds().token !== ""
    readonly property bool showForm: !root.browseReady
    // 服务器显示名:账号名/用户名,未匹配回退地址。
    function serverLabel() {
        const accs = AccountManager.accounts
        for (const a of accs)
            if (a.serverUrl === root.serverUrl)
                return a.name !== "" ? a.name : a.userName
        return root.serverUrl
    }

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
        if (!root.vm || root.vm.count === 0)
            return
        let idx = 0
        for (let i = 0; i < root.vm.count; ++i) {
            if (root.vm.idAt(i) === preferredId) {
                idx = i
                break
            }
        }
        viewSelector.currentIndex = idx
        root.currentViewId = root.vm.idAt(idx)
        const c = root.creds()
        EmbyClient.fetchItems(root.serverUrl, c.token, c.userId, root.currentViewId,
                              0, Constants.pageSize, root.currentSortBy, root.currentSortOrder)
    }

    // 切换排序:服务端重查第一页。
    function changeSort(sortBy) {
        root.currentSortBy = sortBy
        const c = root.creds()
        EmbyClient.fetchItems(root.serverUrl, c.token, c.userId, root.currentViewId,
                              0, Constants.pageSize, root.currentSortBy, root.currentSortOrder)
    }

    // 表单直连:登录成功即由 AccountManager 保存为账号,此后按该服务器浏览。
    function connectServer() {
        const started = AccountManager.addAccount("", serverField.text, userField.text,
                                                  passField.text, true)
        root.busy = started
        if (started)
            statusText.text = "正在登录…"
    }

    // 进入页面:有服务器则拉取;未指定时默认第一个有效账号;无账号则表单。
    Component.onCompleted: {
        if (root.serverUrl === "") {
            const accs = AccountManager.accounts
            for (const a of accs) {
                if (AccountManager.credsForServer(a.serverUrl).token !== "") {
                    root.serverUrl = a.serverUrl
                    break
                }
            }
        }
        if (root.browseReady) {
            root.vm = EmbyClient.viewsModelFor(root.serverUrl)
            root.im = EmbyClient.itemsModelFor(root.serverUrl)
            // 无状态化后视图不会预载,主动拉取(onViewsReceived 后应用目标库)。
            const c = root.creds()
            EmbyClient.fetchViews(root.serverUrl, c.token, c.userId)
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
        } else {
            // 无账号/凭据失效:预填默认服务器地址,等待表单直连。
            serverField.text = SettingsStore.serverUrl
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

        // --- 连接表单(无有效凭据时) ---
        Row {
            visible: root.showForm
            spacing: 10
            TextField {
                id: serverField
                width: 340
                placeholderText: "服务器地址 (http://host:8096)"
                text: SettingsStore.serverUrl
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
            visible: root.browseReady
            spacing: 12
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.serverLabel()
                color: Theme.textMuted
                font.pixelSize: 13
            }
            ComboBox {
                id: viewSelector
                width: 320
                model: root.vm
                textRole: "name"
                onActivated: function (index) {
                    root.currentViewId = root.vm.idAt(index)
                    const c = root.creds()
                    EmbyClient.fetchItems(root.serverUrl, c.token, c.userId,
                                          root.currentViewId, 0, Constants.pageSize,
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
        visible: root.browseReady
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
        model: root.im
        // 滚动到底部且还有未加载条目时,加载下一页(Emby 单页上限 200)。
        onAtYEndChanged: {
            if (!atYEnd)
                return
            if (root.currentViewId !== "" && root.im.count < root.im.totalCount && !root.busy) {
                root.busy = true
                const c = root.creds()
                EmbyClient.fetchItems(root.serverUrl, c.token, c.userId, root.currentViewId,
                                      root.im.count, Constants.pageSize,
                                      root.currentSortBy, root.currentSortOrder)
            }
        }
        // 空库提示。
        Text {
            visible: root.im && root.im.count === 0 && !root.busy
            anchors.centerIn: parent
            text: "该媒体库暂无条目"
            color: Theme.textMuted
            font.pixelSize: 16
        }
        // 加载骨架:首屏数据未到前铺占位卡,避免转圈引起布局跳动。
        Flow {
            visible: root.busy && root.im && root.im.count === 0
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
            onClicked: root.showDetail(model.id, model.posterId, model.name, root.serverUrl)
            onFavoriteRequested: function (id, fav) {
                const c = root.creds()
                EmbyClient.setFavorite(root.serverUrl, c.token, c.userId, id, fav)
                root.im.setFavoriteById(id, fav)
            }
            onWatchedRequested: function (id, played) {
                const c = root.creds()
                EmbyClient.setWatched(root.serverUrl, c.token, c.userId, id, played)
                root.im.setPlayedById(id, played)
            }
        }
    }

    // 异步结果:按服务器路由(仅处理本页服务器的响应)。
    Connections {
        target: EmbyClient
        function onViewsReceived(serverUrl) {
            if (serverUrl !== root.serverUrl)
                return
            if (root.vm && root.vm.count > 0)
                root.applyView(root.initialViewId)
            root.busy = false
        }
        function onItemsReceived(serverUrl) {
            if (serverUrl !== root.serverUrl)
                return
            statusText.text = "已加载 " + root.im.count + " / "
                              + root.im.totalCount + " 个条目"
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
        function onErrorOccurred(serverUrl, message) {
            if (serverUrl !== root.serverUrl)
                return
            root.busy = false
            statusText.text = "失败：" + message
        }
    }

    // 表单直连(添加账号)结果:成功即切换到该服务器浏览。
    Connections {
        target: AccountManager
        function onAccountLoginFinished(ok, message) {
            if (ok) {
                if (root.serverUrl !== serverField.text.trimmed())
                    root.serverUrl = serverField.text.trimmed()
                if (root.browseReady && root.vm === null) {
                    root.vm = EmbyClient.viewsModelFor(root.serverUrl)
                    root.im = EmbyClient.itemsModelFor(root.serverUrl)
                    const c = root.creds()
                    EmbyClient.fetchViews(root.serverUrl, c.token, c.userId)
                }
                root.busy = false
            } else {
                root.busy = false
                statusText.text = "登录失败：" + message
            }
        }
    }
}
