import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import "qrc:/qml/theme"

Item {
    id: root

    Column {
        anchors.centerIn: parent
        spacing: 28
        width: 480

        Text {
            text: "设置"
            color: Theme.textPrimary
            font.pixelSize: 28
            font.bold: true
        }

        Column {
            spacing: 8

            Text {
                text: "Emby 服务器（默认地址）"
                color: Theme.textMuted
                font.pixelSize: 13
            }
            TextField {
                width: 480
                text: SettingsStore.serverUrl
                onEditingFinished: SettingsStore.serverUrl = text
            }
        }

        Text {
            text: "MoePlayer " + Qt.application.version
            color: Theme.textMuted
            font.pixelSize: 12
        }
    }
}
