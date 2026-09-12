pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import MoePlayer.Core

Item {
    id: root

    readonly property int cardW: Constants.serverCardW
    readonly property int cardH: Constants.serverCardH
    readonly property int iconSize: Constants.serverIconSize
    readonly property int gridSpacing: Constants.serverGridSpacing
    readonly property real hoverScale: Constants.serverHoverScale
    readonly property real expandHalf: root.cardW * (root.hoverScale - 1) / 2
    readonly property int moveDuration: Constants.serverMoveMs
    readonly property int dragDuration: Constants.serverDragMs
    readonly property int fadeDuration: Constants.serverFadeMs
    readonly property color hoverBorder: Qt.rgba(Theme.accent.r, Theme.accent.g,
                                                 Theme.accent.b, 0.5)
    property var acctCache: ({})
    property var folderCache: ({})
    readonly property var emptyAccount: ({ name: "", userName: "", serverUrl: "", authStatus: "", icon: "" })
    readonly property var emptyFolder: ({ name: "", color: "", accountIds: [] })
    property string hoveredKey: ""
    property string dropTargetKey: ""
    property string dragKey: ""
    property string pressKey: ""
    property bool dragActive: false
    readonly property int cellW: root.cardW + root.gridSpacing
    readonly property int cellH: root.cardH + root.gridSpacing
    readonly property int columns: Math.max(1, Math.floor(gridArea.width / root.cellW))
    property bool addOpen: false
    property bool adding: false
    property string errorMsg: ""
    property bool editOpen: false
    property string editAccountId: ""
    property string editError: ""
    property var expandedFolders: []
    property bool folderOpen: false
    property string folderEditId: ""
    property string folderSelectedColor: ""
    readonly property int hoveredIndex: root.indexOfKey(root.hoveredKey)
    readonly property int hoveredCell: root.hoveredKey === "" ? -1 : root.hoveredIndex
    readonly property int hoveredRow: root.hoveredCell < 0
                                      ? -1 : Math.floor(root.hoveredCell / root.columns)
    signal backRequested()

    function rowKeyOf(kind, id) { return kind + ":" + id }
    function kindOfKey(key) { return key.substring(0, key.indexOf(":")) }
    function idOfKey(key) { return key.substring(key.indexOf(":") + 1) }
    function desiredKeys() {
        const out = []
        const order = AccountManager.layoutOrder
        for (let i = 0; i < order.length; ++i) {
            const e = order[i]
            if (e.type === "folder") {
                out.push(root.rowKeyOf("folder", e.id))
                if (root.isFolderExpanded(e.id)) {
                    const ids = root.folderInfo(e.id).accountIds || []
                    for (let j = 0; j < ids.length; ++j)
                        out.push(root.rowKeyOf("account", ids[j]))
                }
            } else {
                out.push(root.rowKeyOf("account", e.id))
            }
        }
        return out
    }
    function rowObject(key) {
        if (key === "plus")
            return { key: "plus", kind: "plus", id: "" }
        return { key: key, kind: root.kindOfKey(key), id: root.idOfKey(key) }
    }
    function syncModel() {
        root.refreshDataCache()
        const want = ["plus"].concat(root.desiredKeys())
        for (let i = vmodel.count - 1; i >= 0; --i) {
            if (want.indexOf(vmodel.get(i).key) < 0)
                vmodel.remove(i)
        }
        for (let i = 0; i < want.length; ++i) {
            if (i >= vmodel.count) {
                vmodel.append(root.rowObject(want[i]))
                continue
            }
            if (vmodel.get(i).key === want[i])
                continue
            let from = -1
            for (let k = i + 1; k < vmodel.count; ++k) {
                if (vmodel.get(k).key === want[i]) {
                    from = k
                    break
                }
            }
            if (from < 0)
                vmodel.insert(i, root.rowObject(want[i]))
            else
                vmodel.move(from, i, 1)
        }
    }
    function refreshDataCache() {
        const accs = AccountManager.accounts
        const a = {}
        const prevA = root.acctCache
        for (const k in prevA)
            a[k] = prevA[k]
        for (let i = 0; i < accs.length; ++i)
            a[accs[i].id] = accs[i]
        root.acctCache = a
        const fs = AccountManager.folders
        const f = {}
        const prevF = root.folderCache
        for (const k in prevF)
            f[k] = prevF[k]
        for (let i = 0; i < fs.length; ++i)
            f[fs[i].id] = fs[i]
        root.folderCache = f
    }
    // 取数失败(行刚被移除、退场动画仍在跑)回字段齐全的空模板,
    // 卡体绑定不会求值到 undefined。
    function accountInfo(id) { return root.acctCache[id] || root.emptyAccount }
    function folderInfo(id) { return root.folderCache[id] || root.emptyFolder }

    // key → 模型行号(-1 = 不存在)。
    function indexOfKey(key) {
        for (let i = 0; i < vmodel.count; ++i)
            if (vmodel.get(i).key === key)
                return i
        return -1
    }
    // hover 让位量:同排且非自身才偏移(卡体容器 x 绑定此值)。
    function shiftOfCell(cell) {
        if (root.hoveredCell < 0 || cell === root.hoveredCell)
            return 0
        if (Math.floor(cell / root.columns) !== root.hoveredRow)
            return 0
        return cell < root.hoveredCell ? -root.expandHalf : root.expandHalf
    }

    // 拖动归位
    function settleCardBodies() {
        for (let i = 0; i < vmodel.count; ++i) {
            const it = vgrid.itemAtIndex(i)
            if (!it || it.children.length === 0)
                continue
            const holder = it.children[0]
            for (let k = 0; k < holder.children.length; ++k) {
                const ch = holder.children[k]
                if (ch.accountId !== it.id && ch.folderId !== it.id)
                    continue
                if (typeof ch.settleBack !== "function")
                    continue
                ch.settleBack()
            }
        }
    }

    // 落点行:页面坐标 → 内容坐标 → 按格宽高取格(floor;格间隙归就近格),
    // 格位超出模型范围(末行之下、最右列之外)= null(空白)。
    // 不用 vgrid.indexAt():它要 contentItem 坐标,而由页面坐标映射出的视图
    // 坐标与内容坐标差 contentX/contentY(视图滚动后落点整体错位);且它只
    // 命中 delegate 矩形,格间隙与尾部返回 -1(拖到那就没有落点)。
    // 网格上方/左侧(标题栏那条、左留白)= 占位卡格位,即"移到最前"。
    function dropTargetAt(x, y) {
        if (vmodel.count === 0)
            return null
        const p = vgrid.contentItem.mapFromItem(root, x, y)
        if (p.x < 0 || p.y < 0)
            return { kind: "plus", id: "", key: "plus" }
        const col = Math.floor(p.x / vgrid.cellWidth)
        const row = Math.floor(p.y / vgrid.cellHeight)
        if (col >= root.columns || row >= Math.ceil(vmodel.count / root.columns))
            return null
        const r = vmodel.get(Math.min(row * root.columns + col, vmodel.count - 1))
        return { kind: r.kind, id: r.id, key: r.key }
    }

    function clearDropTarget() { root.dropTargetKey = "" }

    // 落点判定(拖动过程中):与最终 drop 语义一致,只有"有意义的落点"才
    // 高亮(无操作不高亮)。
    function updateDropTarget(drop) {
        const fromKind = root.kindOfKey(root.pressKey)
        const fromId = root.idOfKey(root.pressKey)
        let next = ""
        if (fromKind !== "" && fromId !== "") {
            const t = root.dropTargetAt(drop.x, drop.y)
            // 占位卡行(格 0)= 移到最前,与拖到空白区分不了高亮,不预高亮。
            if (t && t.kind !== "plus" && t.key !== root.pressKey) {
                if (fromKind === "folder") {
                    // 文件夹:落点另一文件夹卡 = 排序;落点账号卡 = 跨类排序
                    // (本夹成员是无操作,不高亮)。
                    if (t.kind === "folder")
                        next = t.key
                    else if (AccountManager.folderIdOfAccount(t.id) !== fromId)
                        next = t.key
                } else {
                    const fromFolder = AccountManager.folderIdOfAccount(fromId)
                    if (t.kind === "folder") {
                        if (fromFolder !== t.id)
                            next = t.key
                    } else {
                        const toFolder = AccountManager.folderIdOfAccount(t.id)
                        if (fromFolder !== toFolder || (fromFolder === "" && fromId !== t.id))
                            next = t.key
                    }
                }
            }
        }
        // 只在目标真变时赋值:每次鼠标移动都 ""→key 抖动会让所有卡重算绑定。
        if (next !== root.dropTargetKey)
            root.dropTargetKey = next
    }

    // 落下:执行重排 / 加入文件夹 / 拖出。语义与原实现一致——账号:同上下文
    // 排序、落到文件夹卡或成员卡 = 加入/转移、落到空白 = 拖出;文件夹:落点
    // 文件夹或账号卡 = 排序,空白 = 不动。
    function applyDrop(x, y) {
        const fromKind = root.kindOfKey(root.pressKey)
        const fromId = root.idOfKey(root.pressKey)
        if (fromKind === "" || fromId === "")
            return
        const t = root.dropTargetAt(x, y)
        if (fromKind === "folder") {
            if (AccountManager.folders.findIndex(f => f.id === fromId) < 0)
                return
            if (!t)
                return
            if (t.kind === "plus") {
                // 占位卡位(首格):文件夹移到最前。
                root.moveLayoutElement("folder", fromId, "", "")
                return
            }
            if (t.kind === "folder") {
                if (t.id !== fromId)
                    root.moveLayoutElement("folder", fromId, "folder", t.id)
                return
            }
            if (AccountManager.folderIdOfAccount(t.id) !== fromId)
                root.moveLayoutElement("folder", fromId, "account", t.id)
            return
        }
        if (AccountManager.accounts.findIndex(a => a.id === fromId) < 0)
            return
        const fromFolder = AccountManager.folderIdOfAccount(fromId)
        if (!t || t.kind === "plus") {
            // 空白 / 占位卡格位:文件夹成员 = 拖出(回到未分组区末尾);
            // 未分组账号 = 占位卡格位算"移到最前",纯空白算"移到末尾"。
            if (fromFolder !== "")
                AccountManager.removeAccountFromFolder(fromId)
            else if (t)
                root.moveLayoutElement("account", fromId, "", "")
            else
                root.moveLayoutElement("account", fromId, "@end", "")
            return
        }
        if (t.kind === "folder") {
            if (fromFolder !== t.id)
                AccountManager.addAccountToFolder(t.id, fromId)
            return
        }
        const toFolder = AccountManager.folderIdOfAccount(t.id)
        if (fromFolder === toFolder) {
            if (fromFolder === "" && fromId !== t.id)
                root.moveLayoutElement("account", fromId, "account", t.id)
            return
        }
        if (toFolder !== "") {
            AccountManager.addAccountToFolder(toFolder, fromId)
        } else {
            AccountManager.removeAccountFromFolder(fromId)
            root.moveLayoutElement("account", fromId, "account", t.id)
        }
    }

    // 跨类排序统一入口:把视觉元素(type/id)移到 beforeType/beforeId 之前
    // (移除后插入),提交 AccountManager.setLayoutOrder 统一规范化 + 重排
    // accounts/folders + 持久化。beforeType 空 = 移到最前(占位卡格位);
    // 目标不在序列中 = 移到末尾(调用方以 "@end" 哨兵表达"移到末尾")。
    function moveLayoutElement(type, id, beforeType, beforeId) {
        const order = JSON.parse(JSON.stringify(AccountManager.layoutOrder))
        const from = order.findIndex(e => e.type === type && e.id === id)
        if (from < 0)
            return
        order.splice(from, 1)
        let to = 0
        if (beforeType !== "") {
            to = order.findIndex(e => e.type === beforeType && e.id === beforeId)
            if (to < 0)
                to = order.length
        }
        order.splice(to, 0, { type: type, id: id })
        AccountManager.setLayoutOrder(order)
    }

    // ---- 文件夹(分类) ----
    function isFolderExpanded(id) {
        return root.expandedFolders.indexOf(id) >= 0
    }
    // 点击文件夹卡:切换展开/收起。展开 = 成员卡进入视觉序列(从停靠位
    // 动画到新位 + 淡入);收起 = 成员卡移出序列隐藏(收进文件夹)。
    function toggleFolder(id) {
        if (root.isFolderExpanded(id))
            root.expandedFolders = root.expandedFolders.filter(f => f !== id)
        else
            root.expandedFolders = root.expandedFolders.concat([id])
        // 成员行随 expandedFolders 增删(见 onExpandedFoldersChanged → syncModel),
        // 展开/收起动画由视图的 add/remove/displaced 过渡播。
    }
    function folderNameById(id) {
        const folders = AccountManager.folders
        for (let i = 0; i < folders.length; ++i)
            if (folders[i].id === id)
                return folders[i].name
        return ""
    }
    function folderColorById(id) {
        const folders = AccountManager.folders
        for (let i = 0; i < folders.length; ++i)
            if (folders[i].id === id)
                return folders[i].color
        return ""
    }
    // 账号所属文件夹的颜色(空 = 未分组)。
    function folderColorOfAccount(accountId) {
        return root.folderColorById(AccountManager.folderIdOfAccount(accountId))
    }
    // "#RRGGBB" → 带透明度的 QML 颜色;非法/空返回空串(调用方 fallback)。
    function hexToRgba(hex, alpha) {
        if (!hex || hex.length < 7)
            return ""
        const h = hex.indexOf("#") === 0 ? hex.substring(1) : hex
        if (h.length < 6)
            return ""
        const r = parseInt(h.substring(0, 2), 16)
        const g = parseInt(h.substring(2, 4), 16)
        const b = parseInt(h.substring(4, 6), 16)
        if (isNaN(r) || isNaN(g) || isNaN(b))
            return ""
        return Qt.rgba(r / 255, g / 255, b / 255, alpha)
    }
    function openFolderDialog(id) {
        root.folderEditId = id
        folderNameField.text = id === "" ? "" : root.folderNameById(id)
        // 颜色:新建随机挑预设色,重命名预填当前色(可改)。
        if (id === "") {
            const colors = AccountManager.presetFolderColors()
            root.folderSelectedColor = colors[Math.floor(Math.random() * colors.length)]
        } else {
            root.folderSelectedColor = root.folderColorById(id)
        }
        root.folderOpen = true
        folderNameField.forceActiveFocus()
    }
    function closeFolderDialog() {
        root.folderOpen = false
    }
    function saveFolder() {
        const name = folderNameField.text.trim()
        if (root.folderEditId === "") {
            AccountManager.addFolder(name, root.folderSelectedColor)
        } else {
            if (name !== "" && name !== root.folderNameById(root.folderEditId))
                AccountManager.renameFolder(root.folderEditId, name)
            if (root.folderSelectedColor !== "" && root.folderSelectedColor !== root.folderColorById(root.folderEditId))
                AccountManager.setFolderColor(root.folderEditId, root.folderSelectedColor)
        }
        root.closeFolderDialog()
    }

    // ---- 服务器修改浮窗 ----
    function openEditDialog(id) {
        root.editAccountId = id
        // 预填当前值(名称/地址/用户名);图标字段留空 = 保持当前图标,
        // 且必须清掉上一次的输入(否则会把它写到另一个账号上)。
        const acc = AccountManager.accounts.find(a => a.id === id)
        if (acc) {
            editNameField.text = acc.name
            editUrlField.text = acc.serverUrl
            editUserField.text = acc.userName
        }
        editIconField.text = ""
        root.editError = ""
        root.editOpen = true
        editNameField.forceActiveFocus()
    }
    function closeEditDialog() {
        root.editOpen = false
    }
    function submitEdit() {
        const url = editUrlField.text.trim()
        const user = editUserField.text.trim()
        if (url === "") {
            root.editError = "请输入服务器地址"
            return
        }
        if (user === "") {
            root.editError = "请输入用户名"
            return
        }
        const full = url.indexOf("://") < 0 ? "http://" + url : url
        // 仅改存储(token/密码保留),保存即落盘并通知 UI。
        AccountManager.updateAccount(root.editAccountId, editNameField.text.trim(), full, user)
        // 图标:字段非空才应用(留空 = 保持当前图标);清除由"清除图标"按钮即时执行。
        const icon = editIconField.text.trim()
        if (icon !== "")
            AccountManager.setAccountIcon(root.editAccountId, icon)
        root.closeEditDialog()
    }
    // 删除:先向服务器发登出(结果忽略),再删本地数据(见
    // AccountManager.removeAccount),账号卡自动补位。
    function deleteEditAccount() {
        AccountManager.removeAccount(root.editAccountId)
        root.closeEditDialog()
    }
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
        console.info("ServerManager: 登录发起", user, "@", full)
        AccountManager.addAccount(nameField.text, full, user, passField.text)
    }

    onExpandedFoldersChanged: root.syncModel()

    Component.onCompleted: root.syncModel()

    ListModel { id: vmodel }

    Connections {
        target: AccountManager
        function onAccountsChanged() {
            root.syncModel()
        }
        function onFoldersChanged() {
            root.syncModel()
        }
        function onLayoutOrderChanged() {
            root.syncModel()
        }
    }

    Menu {
        id: blankMenu
        MenuItem {
            text: "新建文件夹…"
            onTriggered: root.openFolderDialog("")
        }
    }

    DropArea {
        anchors.fill: parent
        onPositionChanged: (drag) => root.updateDropTarget(drag)
        onExited: root.clearDropTarget()
        onDropped: (drop) => {
            drop.acceptProposedAction()
            root.clearDropTarget()
            root.applyDrop(drop.x, drop.y)
        }
    }

    Row {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 24
        spacing: 12
        AppText {
            anchors.verticalCenter: parent.verticalCenter
            text: "♥"
            color: Constants.moePink
            font.pixelSize: 24
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
            text: "· " + AccountManager.accountCount
            color: Theme.textMuted
            font.pixelSize: 16
        }
    }

    Shortcut {
        sequences: ["Alt+Left"]
        enabled: root.visible
        onActivated: root.backRequested()
    }

    Item {
        id: gridArea
        anchors.top: header.bottom
        anchors.topMargin: 20
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 24
        anchors.rightMargin: 24
        anchors.bottomMargin: 24

        MouseArea {
            id: blankArea
            anchors.fill: parent
            acceptedButtons: Qt.RightButton
            onClicked: (mouse) => blankMenu.popup(blankArea, mouse.x, mouse.y)
        }

        Column {
            anchors.centerIn: parent
            visible: AccountManager.accountCount === 0
            spacing: 12
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200 } }

            AppText {
                text: "还没有服务器哦~"
                color: Theme.textPrimary
                font.pixelSize: 18
                font.bold: true
                anchors.horizontalCenter: parent.horizontalCenter
            }
            AppText {
                text: "点击左上角的“+”卡片添加服务器吧"
                color: Theme.textMuted
                font.pixelSize: 14
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }

        GridView {
            id: vgrid
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(parent.width, root.columns * root.cellW)
            clip: true
            cellWidth: root.cellW
            cellHeight: root.cellH
            model: vmodel
            interactive: !root.dragActive
            add: Transition {
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: root.fadeDuration; easing.type: Easing.OutCubic }
            }
            remove: Transition {
                NumberAnimation { property: "opacity"; to: 0; duration: root.fadeDuration; easing.type: Easing.OutCubic }
            }
            displaced: Transition {
                NumberAnimation { properties: "x,y"; duration: root.moveDuration; easing.type: Easing.OutCubic }
            }
            move: Transition {
                NumberAnimation { properties: "x,y"; duration: root.moveDuration; easing.type: Easing.OutCubic }
            }

            delegate: Item {
                id: cell
                required property int index
                required property string key
                required property string kind
                required property string id
                readonly property var modelData: cell.kind === "folder"
                                                 ? root.folderInfo(cell.id) : root.accountInfo(cell.id)
                readonly property bool isFolder: cell.kind === "folder"
                readonly property bool isPlus: cell.kind === "plus"
                readonly property bool isHovered: root.hoveredKey === cell.key
                readonly property bool dropTarget: root.dropTargetKey === cell.key
                width: vgrid.cellWidth
                height: vgrid.cellHeight
                z: (root.dragKey === cell.key || cell.isHovered) ? 2 : 1

                Item {
                    id: holder
                    width: root.cardW
                    height: root.cardH
                    x: root.shiftOfCell(cell.index)
                    Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

                    // ===== 添加服务器占位卡(第 0 行)=====
                    Item {
                        id: plusSlot
                        visible: cell.isPlus
                        width: root.cardW
                        height: root.cardH
                        Rectangle {
                            id: plusCard
                            width: root.cardW
                            height: root.cardH
                            radius: 12
                            color: "transparent"
                            border.width: 2
                            border.color: plusHover.containsMouse ? Constants.moePink : Theme.textMuted
                            
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: -3
                                radius: 15
                                color: "transparent"
                                border.width: plusHover.containsMouse ? 2 : 0
                                border.color: Constants.moePink
                                opacity: plusHover.containsMouse ? 0.35 : 0
                                Behavior on opacity { NumberAnimation { duration: 120 } }
                            }

                            Canvas {
                                id: plusIcon
                                property color lineColor: plusHover.containsMouse ? Constants.moePink : Theme.textMuted
                                anchors.centerIn: parent
                                anchors.verticalCenterOffset: -10
                                width: 44
                                height: 44
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
                                color: plusHover.containsMouse ? Constants.moePink : Theme.textMuted
                                font.pixelSize: 14
                                Behavior on color { ColorAnimation { duration: 120 } }
                            }

                            // 点击打开添加浮窗。
                            MouseArea {
                                id: plusHover
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.openAddDialog()
                            }
                        }
                    }

                    // ===== 账号卡 =====
                    Rectangle {
                        id: card
                        readonly property var modelData: cell.kind === "account" ? cell.modelData : root.emptyAccount
                        property string accountId: cell.id
                        property bool hovered: false
                        property bool expanded: false

                        function settleBack() {
                            if (Math.abs(card.x) > 0.5) {
                                cardSettleX.from = card.x
                                cardSettleX.to = 0
                                cardSettleX.start()
                            }
                            if (Math.abs(card.y) > 0.5) {
                                cardSettleY.from = card.y
                                cardSettleY.to = 0
                                cardSettleY.start()
                            }
                        }

                        visible: cell.kind === "account"
                        width: root.cardW
                        height: root.cardH
                        radius: 12
                        color: {
                            const c = root.folderColorOfAccount(card.modelData.id)
                            if (c === "")
                                return Theme.surface
                            const col = root.hexToRgba(c, 0.30)
                            return col !== "" ? col : Theme.surface
                        }
                        opacity: Drag.active ? 0.6 : 1.0
                        scale: card.expanded ? root.hoverScale : 1.0
                        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                        Drag.active: dragArea.drag.active
                        Drag.source: card
                        Drag.hotSpot.x: width / 2
                        Drag.hotSpot.y: height / 2
                        border.width: card.modelData.authStatus === "invalid" ? 2 : (cell.dropTarget ? 2 : 1)
                        border.color: card.modelData.authStatus === "invalid" ? Theme.danger
                                      : (cell.dropTarget ? Theme.accent
                                      : (card.hovered ? Constants.moePink : Theme.bg))
                        Rectangle {
                            z: -1
                            anchors.centerIn: parent
                            width: parent.width
                            height: parent.height
                            radius: parent.radius
                            color: "transparent"
                            border.width: card.hovered ? 3 : 0
                            border.color: Constants.moePink
                            opacity: card.hovered ? 0.35 : 0
                            Behavior on opacity { NumberAnimation { duration: 120 } }
                        }

                        NumberAnimation {
                            id: cardSettleX
                            target: card
                            property: "x"
                            duration: root.dragDuration
                            easing.type: Easing.OutCubic
                        }
                        NumberAnimation {
                            id: cardSettleY
                            target: card
                            property: "y"
                            duration: root.dragDuration
                            easing.type: Easing.OutCubic
                        }

                        Timer {
                            id: hoverTimer
                            interval: 200
                            repeat: false
                            onTriggered: {
                                if (root.dragActive)
                                    return
                                card.expanded = true
                                root.hoveredKey = cell.key
                            }
                        }

                        Rectangle {
                            width: root.iconSize
                            height: root.iconSize
                            radius: 10
                            anchors.top: parent.top
                            anchors.topMargin: 14
                            anchors.left: parent.left
                            anchors.leftMargin: 14
                            color: Qt.rgba(Constants.moePink.r, Constants.moePink.g, Constants.moePink.b, 0.18)
                            ServerIcon {
                                anchors.fill: parent
                                icon: card.modelData.icon
                                fallbackText: (card.modelData.name !== "" ? card.modelData.name : card.modelData.userName).charAt(0)
                            }
                        }

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
                                    text: card.modelData.name !== "" ? card.modelData.name : card.modelData.userName
                                    color: Theme.textPrimary
                                    font.pixelSize: 15
                                    font.bold: true
                                    elide: Text.ElideRight
                                    width: parent.width - (card.modelData.authStatus === "invalid" ? 78 : 0)
                                }
                                AppText {
                                    visible: card.modelData.authStatus === "invalid"
                                    text: "[凭据失效]"
                                    color: Theme.danger
                                    font.pixelSize: 12
                                }
                            }
                            AppText {
                                width: parent.width
                                text: card.modelData.userName + " · " + card.modelData.serverUrl
                                color: Theme.textMuted
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                        }

                        MouseArea {
                            id: dragArea
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton
                            preventStealing: true
                            drag {
                                target: card
                                threshold: 8
                            }
                            onEntered: {
                                card.hovered = true
                                if (!root.dragActive)
                                    hoverTimer.start()
                            }
                            onExited: {
                                card.hovered = false
                                hoverTimer.stop()
                                card.expanded = false
                                if (root.hoveredKey === cell.key)
                                    root.hoveredKey = ""
                            }
                            onPressed: (mouse) => {
                                hoverTimer.stop()
                                card.expanded = false
                                if (root.hoveredKey === cell.key)
                                    root.hoveredKey = ""
                                root.pressKey = cell.key
                                root.dragKey = cell.key
                                root.dragActive = true
                            }
                            onClicked: (mouse) => {
                                if (mouse.modifiers & Qt.ControlModifier)
                                    root.openEditDialog(cell.id)
                            }
                            onReleased: {
                                const r = root
                                r.dragActive = false
                                card.Drag.drop()
                                r.dragKey = ""
                                r.settleCardBodies()
                            }
                        }
                    }

                    // ===== 文件夹卡 =====
                    Rectangle {
                        id: fcard
                        readonly property var modelData: cell.kind === "folder" ? cell.modelData : root.emptyFolder
                        property string folderId: cell.id
                        property bool isOpen: root.isFolderExpanded(fcard.folderId)
                        property bool hovered: false
                        property bool expanded: false

                        function settleBack() {
                            if (Math.abs(fcard.x) > 0.5) {
                                folderSettleX.from = fcard.x
                                folderSettleX.to = 0
                                folderSettleX.start()
                            }
                            if (Math.abs(fcard.y) > 0.5) {
                                folderSettleY.from = fcard.y
                                folderSettleY.to = 0
                                folderSettleY.start()
                            }
                        }

                        visible: cell.isFolder
                        width: root.cardW
                        height: root.cardH
                        radius: 12
                        color: {
                            const col = root.hexToRgba(fcard.modelData.color, 0.30)
                            return col !== "" ? col : Theme.surface
                        }
                        opacity: Drag.active ? 0.6 : 1.0
                        scale: fcard.expanded ? root.hoverScale : 1.0
                        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                        Drag.active: farea.drag.active
                        Drag.source: fcard
                        Drag.hotSpot.x: width / 2
                        Drag.hotSpot.y: height / 2
                        border.width: cell.dropTarget ? 2 : 1
                        border.color: cell.dropTarget ? Constants.moePink
                                      : (fcard.isOpen ? Qt.rgba(Constants.moePink.r, Constants.moePink.g, Constants.moePink.b, 0.45)
                                      : (fcard.hovered ? Constants.moePink : Theme.bg))
                        Rectangle {
                            z: -1
                            anchors.centerIn: parent
                            width: parent.width
                            height: parent.height
                            radius: parent.radius
                            color: "transparent"
                            border.width: fcard.hovered ? 3 : 0
                            border.color: Constants.moePink
                            opacity: fcard.hovered ? 0.35 : 0
                            Behavior on opacity { NumberAnimation { duration: 120 } }
                        }

                        NumberAnimation {
                            id: folderSettleX
                            target: fcard
                            property: "x"
                            duration: root.dragDuration
                            easing.type: Easing.OutCubic
                        }
                        NumberAnimation {
                            id: folderSettleY
                            target: fcard
                            property: "y"
                            duration: root.dragDuration
                            easing.type: Easing.OutCubic
                        }

                        Timer {
                            id: fcardHoverTimer
                            interval: 200
                            repeat: false
                            onTriggered: {
                                if (root.dragActive)
                                    return
                                fcard.expanded = true
                                root.hoveredKey = cell.key
                            }
                        }

                        Rectangle {
                            width: root.iconSize
                            height: root.iconSize
                            radius: 10
                            anchors.top: parent.top
                            anchors.topMargin: 14
                            anchors.left: parent.left
                            anchors.leftMargin: 14
                            color: Qt.rgba(Constants.moePink.r, Constants.moePink.g, Constants.moePink.b, 0.18)
                            Canvas {
                                property color lineColor: farea.containsMouse ? Constants.moePink : Theme.textMuted
                                anchors.centerIn: parent
                                width: 28
                                height: 28
                                onLineColorChanged: requestPaint()
                                onPaint: {
                                    const ctx = getContext("2d")
                                    ctx.clearRect(0, 0, width, height)
                                    ctx.lineCap = "round"
                                    ctx.lineJoin = "round"
                                    ctx.lineWidth = 2.5
                                    ctx.strokeStyle = lineColor
                                    ctx.beginPath()
                                    ctx.moveTo(5, 11)
                                    ctx.lineTo(10, 11)
                                    ctx.lineTo(13, 7)
                                    ctx.lineTo(23, 7)
                                    ctx.lineTo(23, 11)
                                    ctx.moveTo(5, 11)
                                    ctx.lineTo(5, 23)
                                    ctx.lineTo(23, 23)
                                    ctx.lineTo(23, 11)
                                    ctx.stroke()
                                }
                            }
                        }

                        Column {
                            anchors.top: parent.top
                            anchors.topMargin: 18
                            anchors.left: parent.left
                            anchors.leftMargin: 14 + root.iconSize + 12
                            anchors.right: parent.right
                            anchors.rightMargin: 14
                            spacing: 4
                            AppText {
                                width: parent.width
                                text: fcard.modelData.name
                                color: Theme.textPrimary
                                font.pixelSize: 15
                                font.bold: true
                                elide: Text.ElideRight
                            }
                            AppText {
                                width: parent.width
                                text: (fcard.modelData.accountIds ? fcard.modelData.accountIds.length : 0) + " 台服务器"
                                color: Theme.textMuted
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                        }

                        AppText {
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 8
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            text: fcard.isOpen ? "▾" : "▸"
                            color: farea.containsMouse ? Theme.accent : Theme.textMuted
                            font.pixelSize: 13
                        }

                        MouseArea {
                            id: farea
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton
                            preventStealing: true
                            drag {
                                target: fcard
                                threshold: 8
                            }
                            onEntered: {
                                fcard.hovered = true
                                if (!root.dragActive)
                                    fcardHoverTimer.start()
                            }
                            onExited: {
                                fcard.hovered = false
                                fcardHoverTimer.stop()
                                fcard.expanded = false
                                if (root.hoveredKey === cell.key)
                                    root.hoveredKey = ""
                            }
                            onPressed: (mouse) => {
                                fcardHoverTimer.stop()
                                fcard.expanded = false
                                if (root.hoveredKey === cell.key)
                                    root.hoveredKey = ""
                                root.pressKey = cell.key
                                root.dragKey = cell.key
                                root.dragActive = true
                            }
                            onClicked: (mouse) => {
                                // Ctrl+点击打开修改浮窗(重命名/删除);普通点击
                                // 展开/收起成员。拖动超过 threshold 后不触发 click。
                                if (mouse.modifiers & Qt.ControlModifier)
                                    root.openFolderDialog(cell.id)
                                else
                                    root.toggleFolder(cell.id)
                            }
                            onReleased: {
                                const r = root
                                r.dragActive = false
                                fcard.Drag.drop()
                                r.dragKey = ""
                                r.settleCardBodies()
                            }
                        }
                    }
                }
            }
        }
    }

    Connections {
        target: AccountManager
        function onAccountLoginFinished(ok, message) {
            root.adding = false
            if (ok) {
                console.info("ServerManager: 登录成功")
                root.closeAddDialog()
            } else {
                console.warn("ServerManager: 登录失败", message)
                root.errorMsg = message
            }
        }
    }

    Rectangle {
        visible: root.addOpen
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        z: 100
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

                Row {
                    spacing: 8
                    AppText {
                        text: "♥"
                        color: Constants.moePink
                        font.pixelSize: 24
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    AppText {
                        text: "添加服务器"
                        color: Theme.textPrimary
                        font.pixelSize: 20
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

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
                        height: 36
                        leftPadding: 14
                        rightPadding: 14
                        placeholderText: "留空则使用服务器端名称"
                        placeholderTextColor: Theme.textMuted
                        color: "white"
                        font.pixelSize: 14
                        background: Rectangle {
                            radius: 18
                            color: Theme.bg
                            border.width: 1
                            border.color: nameField.activeFocus ? Constants.moePink : Theme.textMuted
                        }
                        onAccepted: urlField.forceActiveFocus()
                    }
                }
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
                        height: 36
                        leftPadding: 14
                        rightPadding: 14
                        placeholderText: "http://192.168.1.100:8096"
                        placeholderTextColor: Theme.textMuted
                        color: "white"
                        font.pixelSize: 14
                        background: Rectangle {
                            radius: 18
                            color: Theme.bg
                            border.width: 1
                            border.color: urlField.activeFocus ? Constants.moePink : Theme.textMuted
                        }
                        onAccepted: userField.forceActiveFocus()
                    }
                }
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
                        height: 36
                        leftPadding: 14
                        rightPadding: 14
                        placeholderText: "请输入用户名"
                        placeholderTextColor: Theme.textMuted
                        color: "white"
                        font.pixelSize: 14
                        background: Rectangle {
                            radius: 18
                            color: Theme.bg
                            border.width: 1
                            border.color: userField.activeFocus ? Constants.moePink : Theme.textMuted
                        }
                        onAccepted: passField.forceActiveFocus()
                    }
                }
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
                        height: 36
                        leftPadding: 14
                        rightPadding: 14
                        placeholderText: "留空则不保存密码"
                        placeholderTextColor: Theme.textMuted
                        color: "white"
                        echoMode: TextInput.Password
                        font.pixelSize: 14
                        background: Rectangle {
                            radius: 18
                            color: Theme.bg
                            border.width: 1
                            border.color: passField.activeFocus ? Constants.moePink : Theme.textMuted
                        }
                        onAccepted: root.submitAdd()
                    }
                }

                Button {
                    id: addBtn
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 160
                    height: 36
                    text: root.adding ? "登录中…" : "添加"
                    enabled: !root.adding
                    onClicked: root.submitAdd()
                    background: Rectangle {
                        radius: 18
                        color: addBtn.hovered ? Constants.moePinkDark : Constants.moePink
                        border.width: 0
                    }
                    contentItem: AppText {
                        text: addBtn.text
                        color: "white"
                        font.pixelSize: 14
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

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

    Rectangle {
        id: folderOverlay
        visible: root.folderOpen
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        z: 100
        MouseArea {
            anchors.fill: parent
            onClicked: root.closeFolderDialog()
        }

        Rectangle {
            anchors.centerIn: parent
            width: 380
            height: folderCol.implicitHeight + 48
            radius: 12
            color: Theme.surface
            border.width: 1
            border.color: Qt.rgba(Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 0.35)

            MouseArea {
                anchors.fill: parent
            }

            Column {
                id: folderCol
                anchors.top: parent.top
                anchors.topMargin: 24
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width - 48
                spacing: 14

                Row {
                    spacing: 8
                    AppText {
                        text: "♥"
                        color: Constants.moePink
                        font.pixelSize: 24
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    AppText {
                        text: root.folderEditId === "" ? "新建文件夹" : "重命名文件夹"
                        color: Theme.textPrimary
                        font.pixelSize: 20
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                AppText {
                    text: root.folderEditId === ""
                          ? "新建后拖动服务器卡片到文件夹上即可归类"
                          : "重命名后立即生效"
                    color: Theme.textMuted
                    font.pixelSize: 12
                }

                TextField {
                    id: folderNameField
                    width: parent.width
                    height: 36
                    leftPadding: 14
                    rightPadding: 14
                    placeholderText: "文件夹名称(留空自动命名)"
                    placeholderTextColor: Theme.textMuted
                    color: "white"
                    font.pixelSize: 14
                    background: Rectangle {
                        radius: 18
                        color: Theme.bg
                        border.width: 1
                        border.color: folderNameField.activeFocus ? Constants.moePink : Theme.textMuted
                    }
                    onAccepted: root.saveFolder()
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8
                    Repeater {
                        model: AccountManager.presetFolderColors()
                        Rectangle {
                            required property string modelData
                            width: 24
                            height: 24
                            radius: 12
                            color: modelData
                            border.width: root.folderSelectedColor === modelData ? 3 : 0
                            border.color: Constants.moePink
                            scale: root.folderSelectedColor === modelData ? 1.15 : 1.0
                            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: root.folderSelectedColor = modelData
                            }
                        }
                    }
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 12
                    Button {
                        id: folderOkBtn
                        width: 120
                        height: 36
                        text: "确定"
                        onClicked: root.saveFolder()
                        background: Rectangle {
                            radius: 18
                            color: folderOkBtn.hovered ? Constants.moePinkDark : Constants.moePink
                            border.width: 0
                        }
                        contentItem: AppText {
                            text: folderOkBtn.text
                            color: "white"
                            font.pixelSize: 14
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                    Button {
                        id: folderCancelBtn
                        width: 120
                        height: 36
                        text: "取消"
                        onClicked: root.closeFolderDialog()
                        background: Rectangle {
                            radius: 18
                            color: folderCancelBtn.hovered ? Qt.rgba(Theme.textPrimary.r, Theme.textPrimary.g, Theme.textPrimary.b, 0.1) : "transparent"
                            border.width: 1
                            border.color: folderCancelBtn.hovered ? Constants.moePink : Theme.textMuted
                        }
                        contentItem: AppText {
                            text: folderCancelBtn.text
                            color: folderCancelBtn.hovered ? Constants.moePink : Theme.textPrimary
                            font.pixelSize: 14
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                Button {
                    id: folderDeleteBtn
                    visible: root.folderEditId !== ""
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 160
                    height: 36
                    text: "删除文件夹"
                    onClicked: {
                        AccountManager.removeFolder(root.folderEditId)
                        root.closeFolderDialog()
                    }
                    background: Rectangle {
                        radius: 18
                        color: folderDeleteBtn.hovered ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.15) : "transparent"
                        border.width: 1
                        border.color: folderDeleteBtn.hovered ? Theme.danger : Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.5)
                    }
                    contentItem: AppText {
                        text: folderDeleteBtn.text
                        color: folderDeleteBtn.hovered ? Theme.danger : Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.85)
                        font.pixelSize: 14
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }

    Rectangle {
        id: editOverlay
        visible: root.editOpen
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        z: 100
        MouseArea {
            anchors.fill: parent
            onClicked: root.closeEditDialog()
        }

        Rectangle {
            anchors.centerIn: parent
            width: 420
            height: editCol.implicitHeight + 48
            radius: 12
            color: Theme.surface
            border.width: 1
            border.color: Qt.rgba(Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 0.35)

            MouseArea {
                anchors.fill: parent
            }

            Column {
                id: editCol
                anchors.top: parent.top
                anchors.topMargin: 24
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width - 48
                spacing: 14

                Row {
                    spacing: 8
                    AppText {
                        text: "♥"
                        color: Constants.moePink
                        font.pixelSize: 24
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    AppText {
                        text: "修改服务器"
                        color: Theme.textPrimary
                        font.pixelSize: 20
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Column {
                    width: parent.width
                    spacing: 6
                    AppText {
                        text: "服务器名称（可选，留空自动获取）"
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                    TextField {
                        id: editNameField
                        width: parent.width
                        height: 36
                        leftPadding: 14
                        rightPadding: 14
                        placeholderText: "留空则使用服务器端名称"
                        placeholderTextColor: Theme.textMuted
                        color: "white"
                        font.pixelSize: 14
                        background: Rectangle {
                            radius: 18
                            color: Theme.bg
                            border.width: 1
                            border.color: editNameField.activeFocus ? Constants.moePink : Theme.textMuted
                        }
                        onAccepted: editUrlField.forceActiveFocus()
                    }
                }
                Column {
                    width: parent.width
                    spacing: 6
                    AppText {
                        text: "服务器地址"
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                    TextField {
                        id: editUrlField
                        width: parent.width
                        height: 36
                        leftPadding: 14
                        rightPadding: 14
                        placeholderText: "http://192.168.1.100:8096"
                        placeholderTextColor: Theme.textMuted
                        color: "white"
                        font.pixelSize: 14
                        background: Rectangle {
                            radius: 18
                            color: Theme.bg
                            border.width: 1
                            border.color: editUrlField.activeFocus ? Constants.moePink : Theme.textMuted
                        }
                        onAccepted: editUserField.forceActiveFocus()
                    }
                }
                Column {
                    width: parent.width
                    spacing: 6
                    AppText {
                        text: "用户名"
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                    TextField {
                        id: editUserField
                        width: parent.width
                        height: 36
                        leftPadding: 14
                        rightPadding: 14
                        placeholderText: "请输入用户名"
                        placeholderTextColor: Theme.textMuted
                        color: "white"
                        font.pixelSize: 14
                        background: Rectangle {
                            radius: 18
                            color: Theme.bg
                            border.width: 1
                            border.color: editUserField.activeFocus ? Constants.moePink : Theme.textMuted
                        }
                        onAccepted: root.submitEdit()
                    }
                }

                Column {
                    width: parent.width
                    spacing: 6
                    AppText {
                        text: "服务器图标（可选，留空保持不变）"
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                    Row {
                        width: parent.width
                        spacing: 12
                        Rectangle {
                            width: 52
                            height: 52
                            radius: 10
                            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                            ServerIcon {
                                anchors.fill: parent
                                icon: editIconField.text.trim() || root.accountInfo(root.editAccountId).icon
                                fallbackText: "图"
                            }
                        }
                        TextField {
                            id: editIconField
                            width: parent.width - 172
                            height: 36
                            anchors.verticalCenter: parent.verticalCenter
                            leftPadding: 14
                            rightPadding: 14
                            placeholderText: "图片 URL 或本地路径,如 /path/icon.png"
                            placeholderTextColor: Theme.textMuted
                            color: "white"
                            font.pixelSize: 14
                            background: Rectangle {
                                radius: 18
                                color: Theme.bg
                                border.width: 1
                                border.color: editIconField.activeFocus ? Constants.moePink : Theme.textMuted
                            }
                            onAccepted: root.submitEdit()
                        }
                        Button {
                            id: editIconClearBtn
                            width: 96
                            height: 30
                            anchors.verticalCenter: parent.verticalCenter
                            text: "清除图标"
                            enabled: editIconField.text.trim() !== ""
                                     || (root.accountInfo(root.editAccountId).icon || "") !== ""
                            onClicked: {
                                AccountManager.setAccountIcon(root.editAccountId, "")
                                editIconField.text = ""
                            }
                            background: Rectangle {
                                radius: 15
                                color: editIconClearBtn.enabled && editIconClearBtn.hovered ? Qt.rgba(Theme.textPrimary.r, Theme.textPrimary.g, Theme.textPrimary.b, 0.1) : "transparent"
                                border.width: 1
                                border.color: editIconClearBtn.enabled ? (editIconClearBtn.hovered ? Constants.moePink : Theme.textMuted) : Theme.textMuted
                            }
                            contentItem: AppText {
                                text: editIconClearBtn.text
                                color: editIconClearBtn.enabled ? (editIconClearBtn.hovered ? Constants.moePink : Theme.textPrimary) : Theme.textMuted
                                font.pixelSize: 13
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 12
                    Button {
                        id: editSaveBtn
                        width: 120
                        height: 36
                        text: "保存"
                        onClicked: root.submitEdit()
                        background: Rectangle {
                            radius: 18
                            color: editSaveBtn.hovered ? Constants.moePinkDark : Constants.moePink
                            border.width: 0
                        }
                        contentItem: AppText {
                            text: editSaveBtn.text
                            color: "white"
                            font.pixelSize: 14
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                    Button {
                        id: editCancelBtn
                        width: 120
                        height: 36
                        text: "取消"
                        onClicked: root.closeEditDialog()
                        background: Rectangle {
                            radius: 18
                            color: "transparent"
                            border.width: 1
                            border.color: editCancelBtn.hovered ? Constants.moePink : Theme.textMuted
                        }
                        contentItem: AppText {
                            text: editCancelBtn.text
                            color: editCancelBtn.hovered ? Constants.moePink : Theme.textPrimary
                            font.pixelSize: 14
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                Column {
                    visible: root.editError !== ""
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
                        text: root.editError
                        color: Theme.textMuted
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                    }
                }

                Button {
                    id: editDeleteBtn
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 160
                    height: 36
                    text: "删除服务器"
                    onClicked: root.deleteEditAccount()
                    background: Rectangle {
                        radius: 18
                        color: editDeleteBtn.hovered ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.15) : "transparent"
                        border.width: 1
                        border.color: editDeleteBtn.hovered ? Theme.danger : Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.5)
                    }
                    contentItem: AppText {
                        text: editDeleteBtn.text
                        color: editDeleteBtn.hovered ? Theme.danger : Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.85)
                        font.pixelSize: 14
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }
}
