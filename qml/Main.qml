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

    // 在独立顶层窗口中播放,可多次调用实现多窗口并发。
    // meta 为播放元数据({itemId, mediaSourceId, playSessionId, playMethod}),驱动回传。
    function openPlayerWindow(url, headers, meta) {
        return playerWindowComponent.createObject(null, {
            source: url,
            headers: headers || [],
            meta: meta || {},
            visible: true
        })
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
