import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import "qrc:/qml/theme"

//! 服务器管理页:枚举已保存的 Emby 服务器(账号)。
//! 卡片网格展示:名称/用户名/地址/凭据状态。第一张为"添加服务器"
//! 占位卡(添加/管理 UI 后续设计)。
//! 拖动排序:按住账号卡拖动(卡片跟手),拖动中半透明并置顶,落点
//! 卡片高亮,松手按位置重排(首页聚合顺序随之改变)。基于 Qt Quick
//! 官方 Drag/DropArea 拖放机制:MouseArea.drag 驱动 Drag.active,
//! 全页 DropArea 换算落点索引后调用 AccountManager.moveAccount;
//! 拖回原位(from==to)时模型不变化,强制重建卡片网格归位。
//! 打开方式 Ctrl+O(Main 注册快捷键)。
Item {
    id: root

    signal backRequested()

    // 卡片尺寸(与 PosterCard 同风格:圆角 + surface 底)。
    readonly property int cardW: 280
    readonly property int cardH: 150
    readonly property int iconSize: 52

    // 把落点坐标(相对 root,即 DropArea 原点)换算为账号索引。
    // 加号占位卡占内容区第一格,账号卡从第二格起;坐标 clamp 到有效范围,
    // 保证松手必落入某账号位置(全页 DropArea,任何位置都归位)。
    function dropIndex(dx, dy) {
        const n = AccountManager.accounts.length
        if (n <= 0)
            return 0
        const stepW = root.cardW + flow.spacing
        const stepH = root.cardH + flow.spacing
        // 内容区坐标系 = Flow 自身坐标系(drop 坐标减去 Flow 偏移)。
        const lx = dx - flow.x
        const ly = dy - flow.y
        const cols = Math.max(1, Math.floor((flow.width + flow.spacing) / stepW))
        const col = Math.max(0, Math.min(cols - 1, Math.floor((lx + flow.spacing / 2) / stepW)))
        const row = Math.max(0, Math.floor((ly + flow.spacing / 2) / stepH))
        const cell = row * cols + col
        return Math.max(0, Math.min(cell - 1, n - 1))
    }

    function clearDropTarget() {
        for (let i = 0; i < cardRepeater.count; ++i) {
            const c = cardRepeater.itemAt(i)
            if (c)
                c.dropTarget = false
        }
    }

    function updateDropTarget(drop) {
        root.clearDropTarget()
        const fromIdx = AccountManager.accounts.findIndex(a => a.id === drop.source.accountId)
        if (fromIdx < 0)
            return
        const idx = root.dropIndex(drop.x, drop.y)
        if (idx === fromIdx)
            return
        const c = cardRepeater.itemAt(idx)
        if (c)
            c.dropTarget = true
    }

    // 拖放目标:覆盖整页,任何位置松手都换算并重排(拖出网格也不会失序)。
    DropArea {
        id: gridDrop
        anchors.fill: parent
        onPositionChanged: (drop) => root.updateDropTarget(drop)
        onExited: root.clearDropTarget()
        onDropped: (drop) => {
            root.clearDropTarget()
            const fromIdx = AccountManager.accounts.findIndex(a => a.id === drop.source.accountId)
            if (fromIdx < 0)
                return
            const toIdx = root.dropIndex(drop.x, drop.y)
            if (fromIdx === toIdx) {
                // 拖回原位:模型不变,Flow 不会重排,强制重建网格让卡片归位。
                cardRepeater.model = null
                cardRepeater.model = AccountManager.accounts
            } else {
                AccountManager.moveAccount(AccountManager.accounts[fromIdx].id, toIdx)
            }
        }
    }

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
        id: flow
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
                    id: plusIcon
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
                id: plusHover
                anchors.fill: parent
                hoverEnabled: true
            }
        }

        // 账号卡。
        Repeater {
            id: cardRepeater
            model: AccountManager.accounts

            Rectangle {
                id: card
                width: root.cardW
                height: root.cardH
                radius: 12
                color: card.hovered ? Qt.rgba(Theme.surface.r, Theme.surface.g,
                                              Theme.surface.b, 1) : Theme.surface
                // 拖动中半透明并置顶,松手恢复。
                opacity: Drag.active ? 0.6 : 1.0
                z: Drag.active ? 10 : 0
                // 官方拖放模式:MouseArea.drag 移动卡片自身并驱动 Drag.active。
                // Drag.source 是 QObject(卡片自身),drop 侧经 accountId 识别。
                Drag.active: dragArea.drag.active
                Drag.source: card
                Drag.hotSpot.x: width / 2
                Drag.hotSpot.y: height / 2
                property string accountId: modelData.id
                // 凭据失效(重登失败)标红边;拖动落点高亮用强调色。
                border.width: modelData.tokenValid === false ? 2 : (card.dropTarget ? 2 : 1)
                border.color: modelData.tokenValid === false ? Theme.danger
                              : (card.dropTarget ? Theme.accent
                              : (card.hovered ? Qt.rgba(Theme.accent.r, Theme.accent.g,
                                                        Theme.accent.b, 0.5)
                                              : Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 1)))
                property bool hovered: false
                property bool dropTarget: false

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

                // 拖动:按住拖动卡片(跟手),松手按落点重排;hover 样式合并于此。
                MouseArea {
                    id: dragArea
                    anchors.fill: parent
                    hoverEnabled: true
                    drag {
                        target: card
                        threshold: 8
                    }
                    onEntered: card.hovered = true
                    onExited: card.hovered = false
                    onReleased: card.Drag.drop()
                }
            }
        }
    }
}
