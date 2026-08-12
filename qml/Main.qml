import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import "qrc:/qml/player"
import "qrc:/qml/views"
import "qrc:/qml/theme"

ApplicationWindow {
    id: root
    width: 1280
    height: 720
    visible: true
    title: Qt.application.name

    background: Rectangle {
        color: Theme.bg
    }

    // 打开的播放窗口:主窗口关闭时一并关闭。
    // niri/常规窗口管理器下关闭快捷键作用于焦点窗口,焦点常在主窗口,
    // 若不处理则播放窗口会残留继续播放、应用也不退出。
    property var playerWindows: []

    // 剧集详情跳转防抖(同集 500ms 内只 push 一次)。
    property string lastEpisodePush: ""
    property int lastEpisodePushTime: 0
    // 媒体库页离开时的状态(viewId/排序/滚动位置),再次进入时恢复。
    property var libraryState: null
    // 最近浏览的服务器(全局搜索按它路由;打开任意库/详情页时更新)。
    property string currentServerUrl: ""

    // 在独立顶层窗口中播放,可多次调用实现多窗口并发。
    // meta 为播放元数据({itemId, mediaSourceId, playSessionId, playMethod}),驱动回传。
    function openPlayerWindow(url, headers, meta) {
        const w = playerWindowComponent.createObject(null, {
            source: url,
            headers: headers || [],
            meta: meta || {},
            visible: true
        })
        root.playerWindows.push(w)
        // 播放结束(播完或关窗):重拉当前页面已看/进度——等效替代 WS
        // UserDataChanged 推送(该事件唯一真实触发点即本客户端播放,
        // 主动拉取延迟等效而无需每服长连接)。
        const refreshCur = function () { root.refreshCurrentAfterPlayback() }
        w.playbackFinished.connect(refreshCur)
        w.windowClosed.connect(function () {
            root.playerWindows = root.playerWindows.filter(function (x) { return x !== w })
            refreshCur()
        })
        return w
    }
    // 通知当前页面重拉(Detail/Library 各自实现 refreshAfterPlayback)。
    function refreshCurrentAfterPlayback() {
        const cur = stackView.currentItem
        if (cur && typeof cur.refreshAfterPlayback === "function")
            cur.refreshAfterPlayback()
    }

    // 主窗口关闭 → 关闭全部播放窗口,应用随之退出。
    // 两阶段:第一次关闭播放窗口并暂缓退出(等播放窗口的 Stopped 异步回传
    // 发出),随后真正关闭;立即退出会中断网络请求导致服务器收不到回传。
    property bool pendingQuit: false
    onClosing: function (close) {
        if (!root.playerWindows.length || root.pendingQuit) {
            close.accepted = true
            return
        }
        close.accepted = false
        root.pendingQuit = true
        for (const w of root.playerWindows)
            w.close()
        quitTimer.start()
    }
    Timer {
        id: quitTimer
        interval: 400
        running: false
        onTriggered: root.close()
    }

    StackView {
        id: stackView
        anchors.fill: parent
        initialItem: homePage
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
    function pushLibrary(viewId, serverUrl) {
        if (serverUrl)
            root.currentServerUrl = serverUrl
        stackView.push(libraryPage, {
            initialViewId: viewId || "",
            serverUrl: serverUrl || root.currentServerUrl,
            restore: root.libraryState || null
        })
    }

    // 全局搜索浮层(Ctrl+K):按最近浏览的服务器搜索,结果点击进详情。
    SearchOverlay {
        id: searchOverlay
        anchors.fill: parent
        visible: false
        serverUrl: root.currentServerUrl
        onShowDetail: function (itemId, posterId, title, serverUrl) {
            searchOverlay.close()
            root.pushDetail(itemId, posterId, title, serverUrl)
        }
    }

    // 功能入口:媒体库经首页库海报进入,设置 Ctrl+S、服务器管理 Ctrl+O、
    // 搜索 Ctrl+K(见下方快捷键),右下角临时入口已随首页布局完善移除。

    // 首页:每行一库聚合(库海报进媒体库,条目进详情)。
    Component {
        id: homePage
        Home {
            onShowDetail: function (itemId, posterId, title, serverUrl) {
                root.pushDetail(itemId, posterId, title, serverUrl)
            }
            onOpenLibrary: function (viewId, serverUrl) {
                root.pushLibrary(viewId, serverUrl)
            }
            onOpenServerManager: stackView.push(serverManagerPage)
        }
    }

    Component {
        id: libraryPage
        Library {
            onPlayRequested: function (url, headers, meta) {
                root.openPlayerWindow(url, headers, meta)
            }
            // 离开媒体库页(返回首页等)时保存浏览状态供下次恢复。
            onLibraryStateSaved: function (state) {
                root.libraryState = state
            }
            onShowDetail: function (itemId, posterId, title, serverUrl) {
                // 双击卡片会连发两次 showDetail,已打开详情页时忽略,避免叠出双实例。
                if (stackView.currentItem && stackView.currentItem.isDetailPage)
                    return
                root.pushDetail(itemId, posterId, title, serverUrl)
            }
        }
    }

    Component {
        id: detailPage
        Detail {
            onPlayRequested: function (url, headers, meta) {
                root.openPlayerWindow(url, headers, meta)
            }
            onBackRequested: stackView.pop()
            // 剧集导航:点某集 → 压入该集详情页。
            // 注意不能用"当前页是详情页"判断防重复:点击某集时当前页本就是
            // 详情页(季浏览模式),会拦截全部点击;改用同集短时间防抖
            // (StackView 切换动画窗口期内双击会命中旧页面两次)。
            onShowEpisodeDetail: function (itemId, posterId, title, serverUrl) {
                const now = Date.now()
                if (itemId === root.lastEpisodePush && now - root.lastEpisodePushTime < Constants.episodePushDebounceMs)
                    return
                root.lastEpisodePush = itemId
                root.lastEpisodePushTime = now
                root.pushDetail(itemId, posterId, title, serverUrl)
            }
        }
    }

    Component {
        id: settingsPage
        Settings {}
    }

    // 服务器管理页(Ctrl+O):添加/删除/修改要连接的 Emby 服务器。
    Component {
        id: serverManagerPage
        ServerManager {
            onBackRequested: stackView.pop()
        }
    }

    // 快捷键:返回首页 Ctrl+F,服务器管理 Ctrl+O,设置 Ctrl+S,搜索 Ctrl+K。
    Shortcut {
        sequence: "Ctrl+F"
        // pop 到根即返回首页(initialItem);已在首页时无操作。
        onActivated: stackView.pop(null)
    }
    Shortcut {
        sequence: "Ctrl+O"
        onActivated: stackView.push(serverManagerPage)
    }
    Shortcut {
        sequence: "Ctrl+S"
        onActivated: stackView.push(settingsPage)
    }
    Shortcut {
        sequence: "Ctrl+K"
        onActivated: searchOverlay.visible ? searchOverlay.close() : searchOverlay.open()
    }

    Component {
        id: playerWindowComponent
        PlayerWindow {}
    }
}
