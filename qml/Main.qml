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
    title: "MoePlayer"

    // startupUrl 由 main.cpp 注入(--url 参数,空串表示不自动播放);
    // 此处不可声明同名属性,否则会遮蔽注入值。
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
        w.windowClosed.connect(function () {
            root.playerWindows = root.playerWindows.filter(function (x) { return x !== w })
        })
        return w
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

    Component.onCompleted: {
        if (startupUrl !== "")
            openPlayerWindow(startupUrl, [], {})
    }

    StackView {
        id: stackView
        anchors.fill: parent
        initialItem: libraryPage
    }

    footer: Rectangle {
        height: 56
        color: Theme.surface

        Row {
            anchors.centerIn: parent
            spacing: 24

            Button {
                text: "媒体库"
                onClicked: stackView.pop(null)
            }
            Button {
                text: "设置"
                onClicked: stackView.push(settingsPage)
            }
        }
    }

    Component {
        id: libraryPage
        Library {
            onPlayRequested: function (url, headers, meta) {
                root.openPlayerWindow(url, headers, meta)
            }
            onShowDetail: function (itemId, posterId, title) {
                // 双击卡片会连发两次 showDetail,已打开详情页时忽略,避免叠出双实例。
                if (stackView.currentItem && stackView.currentItem.isDetailPage)
                    return
                stackView.push(detailPage, {
                    itemId: itemId,
                    posterId: posterId,
                    title: title
                })
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
            onShowEpisodeDetail: function (itemId, posterId, title) {
                const now = Date.now()
                if (itemId === root.lastEpisodePush && now - root.lastEpisodePushTime < 500)
                    return
                root.lastEpisodePush = itemId
                root.lastEpisodePushTime = now
                stackView.push(detailPage, {
                    itemId: itemId,
                    posterId: posterId,
                    title: title
                })
            }
        }
    }

    Component {
        id: settingsPage
        Settings {}
    }

    Component {
        id: playerWindowComponent
        PlayerWindow {}
    }
}
