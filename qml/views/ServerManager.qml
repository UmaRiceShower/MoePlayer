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

    // 卡片右键菜单:设置图标 / 删除(登出服务器 + 删除本地数据)。
    Menu {
        id: cardMenu
        property string accountId: ""
        property string currentIcon: ""
        property string serverUrl: ""
        MenuItem {
            text: "设置图标…"
            onTriggered: root.openIconDialog(cardMenu.accountId, cardMenu.currentIcon,
                                             cardMenu.serverUrl)
        }
        MenuSeparator {}
        MenuItem {
            // 删除:先向服务器发登出(结果忽略),再删本地数据(见
            // AccountManager.removeAccount),账号卡自动补位。
            contentItem: AppText {
                text: "删除"
                color: Theme.danger
                font.pixelSize: 14
            }
            onTriggered: AccountManager.removeAccount(cardMenu.accountId)
        }
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
            if (fromIdx !== toIdx) {
                // 真实交换:模型变化触发 Flow 重排,卡片随布局归位。
                AccountManager.moveAccount(AccountManager.accounts[fromIdx].id, toIdx)
            } else {
                // 拖回原位:模型不变,卡片仍有效,手动归位到布局位置。
                drop.source.x = drop.source.dragStartX
                drop.source.y = drop.source.dragStartY
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

            Canvas {
                id: plusIcon
                anchors.centerIn: parent
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
                anchors.top: plusIcon.bottom
                anchors.topMargin: 8
                anchors.horizontalCenter: parent.horizontalCenter
                text: "添加服务器"
                color: plusHover.containsMouse ? Theme.accent : Theme.textMuted
                font.pixelSize: 14
            }

            // 点击打开添加浮窗。
            MouseArea {
                id: plusHover
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.openAddDialog()
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
                property real dragStartX: 0
                property real dragStartY: 0

                // 图标区:自定义图标 → 服务器默认 Emby 图标(web PWA 图标/
                // favicon)→ 名称首字,加载失败自动降档(见 ServerIcon)。
                Rectangle {
                    width: root.iconSize
                    height: root.iconSize
                    radius: 10
                    anchors.top: parent.top
                    anchors.topMargin: 14
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                    ServerIcon {
                        anchors.fill: parent
                        serverUrl: modelData.serverUrl
                        customIcon: modelData.icon
                        fallbackText: (modelData.name !== "" ? modelData.name : modelData.userName).charAt(0)
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
                // 拖动前记录布局位置:未发生真实交换时(drop 未投递/拖回原位)
                // 手动归位——不触碰 Repeater.model(赋值会破坏 accounts 绑定,
                // 导致后续所有重排都不刷新)。
                MouseArea {
                    id: dragArea
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    drag {
                        target: card
                        threshold: 8
                    }
                    onEntered: card.hovered = true
                    onExited: card.hovered = false
                    onPressed: (mouse) => {
                        card.dragStartX = card.x
                        card.dragStartY = card.y
                    }
                    onClicked: (mouse) => {
                        // 右键弹出卡片菜单(设置图标等);左键点击无操作。
                        if (mouse.button === Qt.RightButton) {
                            cardMenu.accountId = modelData.id
                            cardMenu.currentIcon = modelData.icon
                            cardMenu.serverUrl = modelData.serverUrl
                            const g = card.mapToGlobal(mouse.x, mouse.y)
                            cardMenu.x = g.x
                            cardMenu.y = g.y
                            cardMenu.open()
                        }
                    }
                    onReleased: {
                        // drop() 可能同步触发模型重排销毁本 delegate,之后不得
                        // 访问任何 QML 上下文——提前捕获局部引用与归位值。
                        // 仅当 drop 未投递(拖出窗口,IgnoreAction)时模型未变、
                        // 卡片仍有效,此时手动归位;投递成功时归位由 onDropped
                        // (from==to)或 Flow 重排(from!=to)完成。
                        const c = card
                        const sx = c.dragStartX
                        const sy = c.dragStartY
                        const act = c.Drag.drop()
                        if (act === Qt.IgnoreAction) {
                            c.x = sx
                            c.y = sy
                        }
                    }
                }
            }
        }
    }

    // ---- 添加服务器浮窗 ----
    // 半透明遮罩 + 居中卡片。字段:名称(可选,留空登录成功后自动获取
    // 服务器端 ServerName)、地址(必填,无 scheme 自动补 http://)、
    // 用户名(必填)、密码(可为空,填了默认记住供 token 失效自动重登)。
    // 点"添加"经 AccountManager.addAccount 登录:成功关闭浮窗(账号卡
    // 自动出现,首页经 accountsChanged 自动重拉聚合);失败在按钮下方
    // 显示"失败"与详细原因。点击遮罩取消。
    property bool addOpen: false
    property bool adding: false
    property string errorMsg: ""

    function openAddDialog() {
        root.addOpen = true
        nameField.text = ""
        urlField.text = ""
        userField.text = ""
        passField.text = ""
        root.errorMsg = ""
        urlField.forceActiveFocus()
    }
    function closeAddDialog() {
        root.addOpen = false
        root.adding = false
        passField.text = "" // 不留密码于控件,避免二次读取
    }

    // ---- 图标设置浮窗 ----
    property bool iconOpen: false
    property string iconAccountId: ""
    property string iconServerUrl: ""

    function openIconDialog(id, current, serverUrl) {
        root.iconAccountId = id
        root.iconServerUrl = serverUrl
        iconUrlField.text = current || ""
        root.iconOpen = true
        iconUrlField.forceActiveFocus()
    }
    function closeIconDialog() {
        root.iconOpen = false
    }
    // 保存即持久化(AccountManager.setAccountIcon 立即落盘)。
    function saveIcon() {
        AccountManager.setAccountIcon(root.iconAccountId, iconUrlField.text.trim())
        root.closeIconDialog()
    }
    // 清除自定义图标 → 恢复默认(服务器 Emby 图标)。
    function clearIcon() {
        AccountManager.setAccountIcon(root.iconAccountId, "")
        root.closeIconDialog()
    }

    function submitAdd() {
        if (root.adding)
            return
        const url = urlField.text.trim()
        const user = userField.text.trim()
        if (url === "") {
            root.errorMsg = "请输入服务器地址"
            return
        }
        if (user === "") {
            root.errorMsg = "请输入用户名"
            return
        }
        const full = url.indexOf("://") < 0 ? "http://" + url : url
        root.errorMsg = ""
        root.adding = true
        AccountManager.addAccount(nameField.text, full, user, passField.text,
                                  passField.text.length > 0)
    }

    Connections {
        target: AccountManager
        function onAccountLoginFinished(ok, message) {
            root.adding = false
            if (ok) {
                root.closeAddDialog()
            } else {
                root.errorMsg = message
            }
        }
    }

    Rectangle {
        visible: root.addOpen
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        z: 100
        // 点击遮罩取消;浮窗打开时遮罩拦截鼠标,卡片网格不可拖动。
        MouseArea {
            anchors.fill: parent
            onClicked: root.closeAddDialog()
        }

        Rectangle {
            anchors.centerIn: parent
            width: 420
            height: addCol.implicitHeight + 48
            radius: 12
            color: Theme.surface
            border.width: 1
            border.color: Qt.rgba(Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 0.35)

            // 吞掉点击:卡片空白处(标题/标签/间隙)不穿透到遮罩误关。
            // 须在 Column 之前声明(下层),TextField/Button 在其上正常交互。
            MouseArea {
                anchors.fill: parent
            }

            Column {
                id: addCol
                anchors.top: parent.top
                anchors.topMargin: 24
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width - 48
                spacing: 14

                AppText {
                    text: "添加服务器"
                    color: Theme.textPrimary
                    font.pixelSize: 20
                    font.bold: true
                }

                // 名称(可选)。
                Column {
                    width: parent.width
                    spacing: 6
                    AppText {
                        text: "服务器名称（可选，留空自动获取）"
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                    TextField {
                        id: nameField
                        width: parent.width
                        placeholderText: "留空则使用服务器端名称"
                        onAccepted: urlField.forceActiveFocus()
                    }
                }
                // 地址(必填)。
                Column {
                    width: parent.width
                    spacing: 6
                    AppText {
                        text: "服务器地址"
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                    TextField {
                        id: urlField
                        width: parent.width
                        placeholderText: "http://192.168.1.100:8096"
                        onAccepted: userField.forceActiveFocus()
                    }
                }
                // 用户名(必填)。
                Column {
                    width: parent.width
                    spacing: 6
                    AppText {
                        text: "用户名"
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                    TextField {
                        id: userField
                        width: parent.width
                        onAccepted: passField.forceActiveFocus()
                    }
                }
                // 密码(可为空,回车提交)。
                Column {
                    width: parent.width
                    spacing: 6
                    AppText {
                        text: "密码（可为空）"
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                    TextField {
                        id: passField
                        width: parent.width
                        echoMode: TextInput.Password
                        onAccepted: root.submitAdd()
                    }
                }

                Button {
                    id: addBtn
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 160
                    text: root.adding ? "登录中…" : "添加"
                    enabled: !root.adding
                    onClicked: root.submitAdd()
                }

                // 失败提示(按钮下方):红色"失败" + 详细错误(网络/HTTP 状态)。
                Column {
                    visible: root.errorMsg !== ""
                    width: parent.width
                    spacing: 4
                    AppText {
                        text: "失败"
                        color: Theme.danger
                        font.pixelSize: 15
                        font.bold: true
                    }
                    AppText {
                        width: parent.width
                        text: root.errorMsg
                        color: Theme.textMuted
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }

    // ---- 图标设置浮窗 ----
    // 半透明遮罩 + 居中卡片:输入图片 URL(图床/服务器资源),实时预览,
    // 保存即持久化(conf 落盘,卡片与设置入口自动刷新);"清除"恢复名称首字。
    // 点击遮罩取消。
    Rectangle {
        id: iconOverlay
        visible: root.iconOpen
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        z: 100
        MouseArea {
            anchors.fill: parent
            onClicked: root.closeIconDialog()
        }

        Rectangle {
            anchors.centerIn: parent
            width: 420
            height: iconCol.implicitHeight + 48
            radius: 12
            color: Theme.surface
            border.width: 1
            border.color: Qt.rgba(Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 0.35)

            // 同添加浮窗:吞掉空白处点击,防穿透误关。
            MouseArea {
                anchors.fill: parent
            }

            Column {
                id: iconCol
                anchors.top: parent.top
                anchors.topMargin: 24
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width - 48
                spacing: 14

                AppText {
                    text: "服务器图标"
                    color: Theme.textPrimary
                    font.pixelSize: 20
                    font.bold: true
                }

                // 预览:自定义 URL 生效即显示,否则走服务器默认图标链
                // (与卡片一致);输入实时反映。
                Row {
                    spacing: 14
                    Rectangle {
                        width: 52
                        height: 52
                        radius: 10
                        color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                        ServerIcon {
                            anchors.fill: parent
                            serverUrl: root.iconServerUrl
                            customIcon: iconUrlField.text.trim()
                            fallbackText: "图"
                        }
                    }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        AppText {
                            text: "输入图片 URL 覆盖默认图标"
                            color: Theme.textMuted
                            font.pixelSize: 13
                        }
                        AppText {
                            text: "默认显示服务器 Emby 图标;清除恢复默认"
                            color: Theme.textMuted
                            font.pixelSize: 12
                        }
                    }
                }

                TextField {
                    id: iconUrlField
                    width: parent.width
                    placeholderText: "https://example.com/logo.png"
                    onAccepted: root.saveIcon()
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 12
                    Button {
                        width: 110
                        text: "保存"
                        onClicked: root.saveIcon()
                    }
                    Button {
                        width: 110
                        text: "清除"
                        enabled: iconUrlField.text.trim() !== ""
                        onClicked: root.clearIcon()
                    }
                    Button {
                        width: 110
                        text: "取消"
                        onClicked: root.closeIconDialog()
                    }
                }
            }
        }
    }
}
