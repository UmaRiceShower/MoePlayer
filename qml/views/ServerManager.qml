import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import "qrc:/qml/theme"

//! 服务器管理页:枚举已保存的 Emby 服务器(账号)。
//! 卡片网格展示:名称/用户名/地址/凭据状态;排序按钮决定首页聚合顺序;
//! 删除按钮移除账号。第一张为"添加服务器"占位卡(添加 UI 后续设计)。
//! 打开方式 Ctrl+O(Main 注册快捷键)。
Item {
    id: root

    signal backRequested()

    // 卡片尺寸(与 PosterCard 同风格:圆角 + surface 底)。
    readonly property int cardW: 280
    readonly property int cardH: 150
    readonly property int iconSize: 52

    // 顶栏:返回 + 标题 + 计数。
    Row {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 24
        spacing: 12
        Button {
            text: "← 返回"
            onClicked: root.backRequested()
        }
        AppText {
            anchors.verticalCenter: parent.verticalCenter
            text: "服务器管理（Ctrl+O）"
            color: Theme.textPrimary
            font.pixelSize: 24
            font.bold: true
        }
        AppText {
            anchors.verticalCenter: parent.verticalCenter
            text: "· " + AccountManager.accounts.length
            color: Theme.textMuted
            font.pixelSize: 16
        }
    }

    // 卡片网格:第一张为加号占位卡,其后每账号一张。
    Flow {
        anchors.top: header.bottom
        anchors.topMargin: 20
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 24
        anchors.rightMargin: 24
        anchors.bottomMargin: 24
        spacing: 16

            // 添加服务器占位卡(具体添加 UI 后续设计,先占位)。
            Rectangle {
                width: root.cardW
                height: root.cardH
                radius: 12
                color: "transparent"
                border.width: 2
                border.color: plusHover.containsMouse
                              ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.8)
                              : Qt.rgba(Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 0.35)

                Column {
                    anchors.centerIn: parent
                    spacing: 8
                    Canvas {
                        id: plusHover
                        property bool containsMouse: false
                        width: 44
                        height: 44
                        property color lineColor: plusHover.containsMouse ? Theme.accent : Theme.textMuted
                        onLineColorChanged: requestPaint()
                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            ctx.strokeStyle = lineColor
                            ctx.lineWidth = 3
                            ctx.lineCap = "round"
                            ctx.beginPath()
                            ctx.moveTo(8, height / 2)
                            ctx.lineTo(width - 8, height / 2)
                            ctx.stroke()
                            ctx.beginPath()
                            ctx.moveTo(width / 2, 8)
                            ctx.lineTo(width / 2, height - 8)
                            ctx.stroke()
                        }
                    }
                    AppText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "添加服务器"
                        color: plusHover.containsMouse ? Theme.accent : Theme.textMuted
                        font.pixelSize: 14
                    }
                }

                // 占位:添加 UI 后续设计,点击暂不响应。
                MouseArea {
                    id: plusHoverArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: plusHover.containsMouse = true
                    onExited: plusHover.containsMouse = false
                }
            }

            // 账号卡。
            Repeater {
                model: AccountManager.accounts

                Rectangle {
                    width: root.cardW
                    height: root.cardH
                    radius: 12
                    color: cardHover.containsMouse ? Qt.rgba(Theme.surface.r, Theme.surface.g,
                                                             Theme.surface.b, 1) : Theme.surface
                    // 凭据失效(重登失败)标红边。
                    border.width: modelData.tokenValid === false ? 2 : 1
                    border.color: modelData.tokenValid === false ? Theme.danger
                                  : (cardHover.containsMouse ? Qt.rgba(Theme.accent.r, Theme.accent.g,
                                                                        Theme.accent.b, 0.5)
                                                              : Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 1))

                    // 图标区:Emby 风格方块,显示名称首字。
                    Rectangle {
                        width: root.iconSize
                        height: root.iconSize
                        radius: 10
                        anchors.top: parent.top
                        anchors.topMargin: 14
                        anchors.left: parent.left
                        anchors.leftMargin: 14
                        color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                        AppText {
                            anchors.centerIn: parent
                            text: (modelData.name !== "" ? modelData.name : modelData.userName).charAt(0)
                            color: Theme.accent
                            font.pixelSize: 26
                            font.bold: true
                        }
                    }

                    // 名称 + 用户名 · 地址。
                    Column {
                        anchors.top: parent.top
                        anchors.topMargin: 18
                        anchors.left: parent.left
                        anchors.leftMargin: 14 + root.iconSize + 12
                        anchors.right: parent.right
                        anchors.rightMargin: 14
                        spacing: 4
                        Row {
                            width: parent.width
                            spacing: 6
                            AppText {
                                text: modelData.name !== "" ? modelData.name : modelData.userName
                                color: Theme.textPrimary
                                font.pixelSize: 15
                                font.bold: true
                                elide: Text.ElideRight
                                width: parent.width - (modelData.tokenValid === false ? 78 : 0)
                            }
                            AppText {
                                visible: modelData.tokenValid === false
                                text: "[凭据失效]"
                                color: Theme.danger
                                font.pixelSize: 12
                            }
                        }
                        AppText {
                            width: parent.width
                            text: modelData.userName + " · " + modelData.serverUrl
                            color: Theme.textMuted
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }
                    }

                    // 底部操作:上移/下移(决定首页聚合顺序)+ 删除。
                    Row {
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 10
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        spacing: 6
                        Button {
                            width: 30
                            height: 26
                            text: "↑"
                            padding: 0
                            onClicked: AccountManager.moveAccountUp(modelData.id)
                        }
                        Button {
                            width: 30
                            height: 26
                            text: "↓"
                            padding: 0
                            onClicked: AccountManager.moveAccountDown(modelData.id)
                        }
                        Button {
                            width: 30
                            height: 26
                            text: "×"
                            padding: 0
                            onClicked: AccountManager.removeAccount(modelData.id)
                        }
                    }

                    MouseArea {
                        id: cardHover
                        anchors.fill: parent
                        hoverEnabled: true
                    }
                }
            }
    }
}
