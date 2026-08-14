import QtQuick
import QtQuick.Controls
import MoePlayer.Core

Item {
    id: root

    Column {
        anchors.centerIn: parent
        spacing: 28
        width: 480

        AppText {
            text: "设置"
            color: Theme.textPrimary
            font.pixelSize: 28
            font.bold: true
        }

        Column {
            spacing: 8

            AppText {
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

        AppText {
            text: Qt.application.name + " " + Qt.application.version
            color: Theme.textMuted
            font.pixelSize: 12
        }
    }
}
