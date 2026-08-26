pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import MoePlayer.Core

ApplicationWindow {
    id: root
    width: 1280
    height: 720
    visible: true
    title: Qt.application.name

    property var libraryState: null
    // 最近浏览的服务器(全局搜索按它路由;打开任意库/详情页时更新)。
    property string currentServerUrl: ""

    // 主窗口关闭:外部 mpv 子进程随 MpvClient 析构一并终止,应用直接退出。
    onClosing: function (close) {
        close.accepted = true
    }

    // 通知当前页面重拉(Detail/Library 各自实现 refreshAfterPlayback)。
    // qmllint disable missing-property
    // stackView.currentItem 静态类型为 Item,压入页面的自定义成员
    // (refreshAfterPlayback/isDetailPage)无法静态推导;typeof 守卫与
    // 短路判空下运行时安全,屏蔽该误报。
    function refreshCurrentAfterPlayback() {
        const cur = stackView.currentItem
        if (cur && typeof cur.refreshAfterPlayback === "function")
            cur.refreshAfterPlayback()
    }
    // qmllint enable missing-property

    // 外部 mpv 播放结束(播完/出错/用户关窗):重拉当前页面已看/进度。
    // MpvClient 是外部 mpv 进程后端(main.cpp 注册的单例)。
    Connections {
        target: MpvClient
        function onPlaybackFinished(itemId, error) {
            root.refreshCurrentAfterPlayback()
        }
    }

    // 打开详情页:记录浏览服务器(全局搜索路由),防抖在调用方。
    function pushDetail(itemId, posterId, title, serverUrl) {
        if (serverUrl)
            root.currentServerUrl = serverUrl
        stackView.push(detailPage, {
            itemId: itemId,
            posterId: posterId,
            title: title,
            serverUrl: serverUrl || root.currentServerUrl
        })
    }
    // 打开媒体库页:记录浏览服务器。
    function pushLibrary(viewId, serverUrl, viewName) {
        if (serverUrl)
            root.currentServerUrl = serverUrl
        stackView.push(libraryPage, {
            initialViewId: viewId || "",
            initialViewName: viewName || "",
            serverUrl: serverUrl || root.currentServerUrl,
            restore: root.libraryState || null
        })
    }

    background: MoeBackground {}

    StackView {
        id: stackView
        anchors.fill: parent
        initialItem: homePage
    }

    // 全局搜索浮层(Ctrl+K):按最近浏览的服务器搜索,结果点击进详情。
    SearchOverlay {
        id: searchOverlay
        anchors.fill: parent
        visible: false
        serverUrl: root.currentServerUrl
        backgroundSource: stackView
        onShowDetail: function (itemId, posterId, title, serverUrl) {
            searchOverlay.close()
            root.pushDetail(itemId, posterId, title, serverUrl)
        }
    }

    // 首页:每行一库聚合(库海报进媒体库,条目进详情)。
    Component {
        id: homePage
        Home {
            onShowDetail: function (itemId, posterId, title, serverUrl) {
                root.pushDetail(itemId, posterId, title, serverUrl)
            }
            onOpenLibrary: function (viewId, serverUrl, viewName) {
                root.pushLibrary(viewId, serverUrl, viewName)
            }
            onOpenServerManager: stackView.push(serverManagerPage)
            onOpenSettings: stackView.push(settingsPage)
            onOpenSearch: searchOverlay.visible ? searchOverlay.close() : searchOverlay.open()
        }
    }

    Component {
        id: libraryPage
        Library {
            onPlayRequested: function (url, headers, meta) {
                MpvClient.start(url, headers, meta)
            }
            // 离开媒体库页(返回首页等)时保存浏览状态供下次恢复。
            onLibraryStateSaved: function (state) {
                root.libraryState = state
            }
            onShowDetail: function (itemId, posterId, title, serverUrl) {
                // 双击卡片会连发两次 showDetail,已打开详情页时忽略,避免叠出双实例。
                // 同 refreshCurrentAfterPlayback:currentItem 动态类型,短路判空下安全。
                // qmllint disable missing-property
                if (stackView.currentItem && stackView.currentItem.isDetailPage)
                    return
                // qmllint enable missing-property
                root.pushDetail(itemId, posterId, title, serverUrl)
            }
        }
    }
    Component {
        id: detailPage
        Detail {
            onPlayWindowRequested: function (meta) {
                MpvClient.startPending(meta)
            }
            onPlaybackDelivered: function (url, headers, meta) {
                MpvClient.deliver(url, headers, meta)
            }
            onPlaybackFailed: function (itemId, message) {
                MpvClient.fail(itemId, message)
            }
            // 返回键:详情内导航(相似推荐/换集/历史)已在 Detail 内原地完成,
            // 仅历史空时 pop 回上层页。
            onBackRequested: stackView.pop()
        }
    }

    Component {
        id: settingsPage
        Settings {}
    }

    // 服务器管理页(Ctrl+O):展示已保存的 Emby 服务器,拖动排序。
    Component {
        id: serverManagerPage
        ServerManager {
            onBackRequested: stackView.pop()
        }
    }

    // 快捷键:返回首页 Ctrl+F,服务器管理 Ctrl+O,设置 Ctrl+S,搜索 Ctrl+K。
    Shortcut {
        sequences: ["Ctrl+F"]
        // pop 到根即返回首页(initialItem);已在首页时无操作。
        onActivated: stackView.pop(null)
    }
    Shortcut {
        sequences: ["Ctrl+O"]
        onActivated: stackView.push(serverManagerPage)
    }
    Shortcut {
        sequences: ["Ctrl+S"]
        onActivated: stackView.push(settingsPage)
    }
    Shortcut {
        sequences: ["Ctrl+K"]
        onActivated: searchOverlay.visible ? searchOverlay.close() : searchOverlay.open()
    }
}
