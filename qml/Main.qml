import QtQuick
import QtQuick.Controls
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
    function openPlayerWindow(url, headers) {
        return playerWindowComponent.createObject(null, {
            source: url,
            headers: headers || [],
            visible: true
        })
    }

    Component.onCompleted: {
        if (startupUrl !== "")
            openPlayerWindow(startupUrl)
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
            onPlayRequested: root.openPlayerWindow(url, headers)
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
