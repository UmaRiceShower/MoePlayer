pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import MoePlayer.Core

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

    // 卡片尺寸(与 PosterCard 同风格:圆角 + surface 底)。
    readonly property int cardW: 280
    readonly property int cardH: 150
    readonly property int iconSize: 52
    // 网格间距与 hover 放大参数。
    readonly property int gridSpacing: 16
    // 放大倍数:等比例 scale(宽高同倍),不单独加宽。
    readonly property real hoverScale: 1.12
    // 放大后每侧视觉溢出 = 卡宽 × (scale-1)/2;左右邻居各让出该距离(一致)。
    readonly property real expandHalf: root.cardW * (root.hoverScale - 1) / 2
    // 重排动画(水波):让位卡 320ms、被拖卡 1.5 倍时长追赶(480ms);跨行
    // 换行/被拖卡淡入 0.5→1。均 OutCubic 无回弹。
    readonly property int moveDuration: 320
    readonly property int dragDuration: 480
    readonly property int fadeDuration: 320

    // 重排状态(FLIP First):模型变化前抓各卡位置快照(id → {x,y}),
    // 新 delegate 按快照就位(消除瞬移 (0,0));dragAccountId 标记被拖卡
    // (水波:更长动画);reordering 标志本次布局走重排动画而非 hover 挤压。
    property var posSnapshot: ({})
    property string dragAccountId: ""
    property bool reordering: false
    // 上次已知账号 id 集合:isNew 判定基线(新 id = 新卡,淡入出场;
    // 旧 id 重登/添加引起的重建不误判为新卡,避免全网格集体淡入)。
    property var prevAccountIds: []
    // 拖动状态:按下时记录的卡 id 与布局位置。drop 处理不触碰 drop.source
    // (拖动中重建后 source 可能是已销毁的旧卡,访问即 internal error),
    // 统一走这里记录的值。
    property string pressCardId: ""
    property real pressStartX: 0
    property real pressStartY: 0
    // 拖动期间模型是否变化过(accountsChanged):拖放重排/重登/添加都会
    // 触发 Repeater 重建,旧卡 delegate 的 context 被引擎失效但对象尚未
    // 销毁(deleteLater),此时调用旧卡任何 QML 函数会触发引擎
    // "QQmlVMEMetaObject: Internal error - invalid context"。onReleased
    // 据此外出——模型未变(拖出窗口)时旧卡必然有效,归位兜底才安全。
    property bool dragDirty: false

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

    // ---- 图标设置浮窗 ----
    property bool iconOpen: false
    property string iconAccountId: ""
    property string iconServerDefault: ""

    signal backRequested()

    // 手动布局:占位卡第 0 格,账号卡其后。hover 卡等比例放大(scale),
    // 其左侧全部卡片左移 expandHalf、右侧全部卡片右移 expandHalf(对称
    // 一致挤压);y 不变(行距 16 > 上下视觉溢出 9,不重叠)。
    // animate=true 时位置变化走卡片内动画(挤压 220ms/复位 120ms,OutCubic),
    // false 用于初始/resize 直接定位。
    // qmllint disable missing-property
    // cardRepeater.itemAt() 的静态类型是 QQuickItem,delegate 自定义成员
    // (expanded/isNew/accountId/animateTo 等)无法静态推导——这是 Repeater
    // itemAt 回访的固有局限。所有访问均有空值守卫且 delegate 类型恒定,
    // 运行时安全,故屏蔽该误报。
    function layoutCards(animate) {
        const n = cardRepeater.count
        const stepW = root.cardW + root.gridSpacing
        const stepH = root.cardH + root.gridSpacing
        const cols = Math.max(1, Math.floor((grid.width + root.gridSpacing) / stepW))
        let hover = -1
        for (let i = 0; i < n; ++i) {
            const c = cardRepeater.itemAt(i)
            if (c && c.expanded) {
                hover = i
                break
            }
        }
        // hover 卡所在行:挤压只作用于同行左右,其他行不受影响。
        let hcell = -1
        let hrow = -1
        if (hover >= 0) {
            hcell = hover + 1
            hrow = Math.floor(hcell / cols)
        }
        // 无放大卡 = 复原:全部卡片用短时复位动画(时长 < hover 触发阈值,
        // 复原期间移回不与放大动画冲突)。
        const restore = hover < 0
        // 重排(水波)模式:快照生效中且无 hover 挤压时,受影响卡从旧位置
        // 动画到新位置(让位卡 220ms、被拖卡 330ms),跨行/被拖卡淡入;
        // 新卡(无快照)直接定位 + 淡入,不参与位置动画。
        const wave = root.reordering && hover < 0 && animate
        // 占位卡(格 0):行 0 且有同行放大卡时一并左移让位。
        root.placeCard(plusCard, hrow === 0 ? -root.expandHalf : 0, 0, animate, restore, false, 0)
        for (let i = 0; i < n; ++i) {
            const c = cardRepeater.itemAt(i)
            if (!c || c.Drag.active)
                continue
            const cell = i + 1 // 占位卡占第 0 格
            const col = cell % cols
            const row = Math.floor(cell / cols)
            const y = row * stepH
            let x = col * stepW
            if (hover >= 0 && row === hrow) {
                if (cell < hcell)
                    x -= root.expandHalf
                else if (cell > hcell)
                    x += root.expandHalf
            }
            if (c.isNew) {
                // 新账号卡:直接定位(位置无需动画)+ 淡入;初始/无动画场景
                // 直接显示(避免启动时全卡透明)。
                c.x = x
                c.y = y
                c.isNew = false
                if (animate)
                    c.fadeInFromZero()
                else
                    c.opacity = 1
                continue
            }
            // 受影响 = 位置变化(以动画前位置为准:重建卡已被快照复位)。
            // 跨行(旧 y ≠ 新 y)或为被拖卡 → 淡入;行内平移不淡。
            const moved = Math.abs(c.x - x) > 0.5 || Math.abs(c.y - y) > 0.5
            if (!wave) {
                root.placeCard(c, x, y, animate, restore, false, 0)
                continue
            }
            // 重建后无快照的非新卡(添加场景旧卡):位置不变,静默定位
            // (1ms 内完成,不渲染 (0,0)),不走 (0,0) 飞行动画。
            if (!root.posSnapshot[c.accountId]) {
                c.x = x
                c.y = y
                continue
            }
            const isDrag = c.accountId === root.dragAccountId
            // 重排走长动画(非短时复位),fade 由跨行/被拖卡判定决定。
            root.placeCard(c, x, y, animate, false,
                           moved && (Math.abs(c.y - y) > 0.5 || isDrag),
                           isDrag ? root.dragDuration : root.moveDuration)
        }
    }

    // 放置卡片:位置变化时 animate=true 走卡片内部 animateTo(restore=true
    // 用短时复位动画),否则直接赋值。卡片内动画以 id 引用(delegate 内部
    // 合法),外部经函数访问(QML id 不是对象属性,itemAt(i).animX 无法直达)。
    // fade/duration 仅重排(水波)时使用:跨行卡淡入、被拖卡 330ms 追赶。
    function placeCard(c, x, y, animate, restore, fade, duration) {
        if (animate)
            c.animateTo(x, y, restore, fade, duration)
        else {
            c.x = x
            c.y = y
        }
    }

    // 重排前抓位置快照(FLIP First):遍历当前卡片记录 id → {x,y}。新
    // delegate 按快照复位(见 delegate Component.onCompleted),重排动画
    // 从旧位置出发;dragId 为空表示删除场景(无被拖卡)。动画结束后由
    // dragResetTimer 清状态,避免后续 hover 挤压误判为重排。
    function snapshotPositions(dragId) {
        root.posSnapshot = {}
        root.dragAccountId = dragId || ""
        root.reordering = true
        // 基线 = 变化前的账号集合(交换/删除不改变"哪些卡存在",仅顺序)。
        root.prevAccountIds = AccountManager.accounts.map(a => a.id)
        for (let i = 0; i < cardRepeater.count; ++i) {
            const c = cardRepeater.itemAt(i)
            if (c)
                root.posSnapshot[c.accountId] = { x: c.x, y: c.y }
        }
        dragResetTimer.restart()
    }
    // qmllint enable missing-property

    // hover 状态/账号列表变化后延迟一帧重排(等 delegate 稳定)。
    function scheduleLayout() {
        layoutTimer.restart()
    }

    // 把落点坐标(相对 root,即 DropArea 原点)换算为账号索引。
    // 加号占位卡占内容区第一格,账号卡从第二格起;坐标 clamp 到有效范围,
    // 保证松手必落入某账号位置(全页 DropArea,任何位置都归位)。
    function dropIndex(dx, dy) {        const n = AccountManager.accounts.length
        if (n <= 0)
            return 0
        const stepW = root.cardW + root.gridSpacing
        const stepH = root.cardH + root.gridSpacing
        // 内容区坐标系 = grid 自身坐标系(drop 坐标减去 grid 偏移)。
        const lx = dx - grid.x
        const ly = dy - grid.y
        const cols = Math.max(1, Math.floor((grid.width + root.gridSpacing) / stepW))
        const col = Math.max(0, Math.min(cols - 1, Math.floor((lx + root.gridSpacing / 2) / stepW)))
        const row = Math.max(0, Math.floor((ly + root.gridSpacing / 2) / stepH))
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
        // 用 onPressed 记录的 id,不触碰 drop.source:拖动中模型可能被重建
        // (重登/添加触发 accountsChanged),旧卡已销毁,访问其属性会触发
        // 引擎 internal error。
        const fromIdx = AccountManager.accounts.findIndex(a => a.id === root.pressCardId)
        if (fromIdx < 0)
            return
        const idx = root.dropIndex(drop.x, drop.y)
        if (idx === fromIdx)
            return
        const c = cardRepeater.itemAt(idx)
        if (c)
            c.dropTarget = true
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

    function openIconDialog(id, current, serverUrl, serverDefault) {
        root.iconAccountId = id
        root.iconServerDefault = serverDefault
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

    // 重排动画(被拖卡 330ms)结束后清状态,防后续 hover 挤压误判。
    Timer {
        id: dragResetTimer
        interval: root.dragDuration + 80
        repeat: false
        onTriggered: {
            root.reordering = false
            root.dragAccountId = ""
            root.posSnapshot = {}
        }
    }

    // 账号增删/排序后 Repeater 重建 delegate,重排到位。
    Connections {
        target: AccountManager
        function onAccountsChanged() {
            // 模型变化 → 旧卡 context 失效(见 dragDirty 说明),onReleased
            // 不得再触碰卡函数。
            root.dragDirty = true
            // 重建完成后一拍布局:accountsChanged 处理后旧 delegate 已销毁、
            // 新 delegate 已按快照复位,此时 layoutCards 只作用于新卡,不会
            // 把拖动卡定位回原位。若孵化未完成(部分新卡未创建),onCompleted
            // 的兜底 scheduleLayout 会补全——两者幂等合并。
            // 注意:不在此同步 isNew 基线(会先于异步重建的 delegate 判定,
            // 导致新增卡误判为旧卡)。
            root.scheduleLayout()
        }
    }

    // 卡片右键菜单:设置图标 / 删除(登出服务器 + 删除本地数据)。
    Menu {
        id: cardMenu
        property string accountId: ""
        property string currentIcon: ""
        property string serverUrl: ""
        property string serverIcon: ""
        MenuItem {
            text: "设置图标…"
            onTriggered: root.openIconDialog(cardMenu.accountId, cardMenu.currentIcon,
                                             cardMenu.serverUrl, cardMenu.serverIcon)
        }
        MenuSeparator {}
        MenuItem {
            onTriggered: {
                // 删除前抓快照:补位卡逐格前移动画(跨行淡入),被删卡消失。
                root.snapshotPositions("")
                AccountManager.removeAccount(cardMenu.accountId)
            }
            // 删除:先向服务器发登出(结果忽略),再删本地数据(见
            // AccountManager.removeAccount),账号卡自动补位。
            contentItem: AppText {
                text: "删除"
                color: Theme.danger
                font.pixelSize: 14
            }
        }
    }

    // 拖放目标:覆盖整页,任何位置松手都换算并重排(拖出网格也不会失序)。
    DropArea {
        id: gridDrop
        anchors.fill: parent
        onPositionChanged: (drop) => root.updateDropTarget(drop)
        onExited: root.clearDropTarget()
        // 同 layoutCards:itemAt 回访的动态类型访问,空值守卫下安全。
        // qmllint disable missing-property
        onDropped: (drop) => {
            root.clearDropTarget()
            // 不触碰 drop.source(拖动中重建后可能已销毁,访问即 internal
            // error),来源 id 与归位值统一用 onPressed 记录的 root 状态。
            const fromId = root.pressCardId
            const fromIdx = AccountManager.accounts.findIndex(a => a.id === fromId)
            if (fromIdx < 0)
                return
            const toIdx = root.dropIndex(drop.x, drop.y)
            if (fromIdx !== toIdx) {
                // 真实交换:立即执行。快照在模型变化前抓(被拖卡此刻 x/y
                // 已是拖动位置,FLIP First),重建后新 delegate 按快照复位,
                // 直接从拖动位置动画到目标格位(无"先回原位"的中间态)。
                // Home 侧的去重/行就绪门控已消除 drop() 调用栈内重建的
                // 引擎错误,无需延迟。
                root.snapshotPositions(fromId)
                AccountManager.moveAccount(fromId, toIdx)
            } else {
                // 拖回原位:模型不变。若拖动中被重建过,当前卡是新实例,
                // 位置已在布局位;找到存活卡按按下时位置短时复位归位。
                for (let i = 0; i < cardRepeater.count; ++i) {
                    const c = cardRepeater.itemAt(i)
                    if (c && c.accountId === fromId) {
                        c.animateTo(root.pressStartX, root.pressStartY, true)
                        break
                    }
                }
            }
        }
        // qmllint enable missing-property
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

    // 卡片网格(手动布局,见 layoutCards):第一张为加号占位卡,其后每账号一张。
    // hover 放大/左右对称挤压/动画均由 layoutCards 驱动,不用 Flow(Flow
    // 无法表达"左侧也被挤压"且加宽是横向的,做不到等比例)。
    Item {
        id: grid
        anchors.top: header.bottom
        anchors.topMargin: 20
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 24
        anchors.rightMargin: 24
        anchors.bottomMargin: 24
        Component.onCompleted: {
            // isNew 判定基线:页面打开时的账号集合。此后添加账号 = 新 id
            // 淡入;重登/重建 = 旧 id 不误判,不触发集体淡入。
            root.prevAccountIds = AccountManager.accounts.map(a => a.id)
            root.layoutCards(false)
        }
        onWidthChanged: root.layoutCards(false)
        onHeightChanged: root.layoutCards(false)

        // 延迟重排(hover 状态/账号变化后执行);首次与 resize 直接定位无动画。
        Timer {
            id: layoutTimer
            interval: 1
            repeat: false
            onTriggered: root.layoutCards(true)
        }

        // 添加服务器占位卡(具体添加 UI 后续设计,先占位)。
        Rectangle {
            id: plusCard
            width: root.cardW
            height: root.cardH
            radius: 12
            color: "transparent"
            border.width: 2
            border.color: plusHover.containsMouse
                          ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.8)
                          : Qt.rgba(Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 0.35)
            // 被同行放大卡挤压时同样让位/复位(经 animateTo 驱动)。
            function animateTo(tx, ty, restore) {
                if (Math.abs(plusCard.x - tx) > 0.5) {
                    if (restore) {
                        plusAnimXBack.from = plusCard.x
                        plusAnimXBack.to = tx
                        plusAnimXBack.start()
                    } else {
                        plusAnimX.from = plusCard.x
                        plusAnimX.to = tx
                        plusAnimX.start()
                    }
                }
                if (Math.abs(plusCard.y - ty) > 0.5) {
                    if (restore) {
                        plusAnimYBack.from = plusCard.y
                        plusAnimYBack.to = ty
                        plusAnimYBack.start()
                    } else {
                        plusAnimY.from = plusCard.y
                        plusAnimY.to = ty
                        plusAnimY.start()
                    }
                }
            }
            NumberAnimation {
                id: plusAnimX
                target: plusCard
                property: "x"
                duration: 220
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                id: plusAnimY
                target: plusCard
                property: "y"
                duration: 220
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                id: plusAnimXBack
                target: plusCard
                property: "x"
                duration: 120
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                id: plusAnimYBack
                target: plusCard
                property: "y"
                duration: 120
                easing.type: Easing.OutCubic
            }

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
                // Repeater 注入的模型元素。显式 required 声明让 qmllint 把
                // delegate 内 modelData 视为本卡属性(否则逐处报 unqualified)。
                required property var modelData
                // hover 放大:等比例 scale(宽高同倍),200ms 触发阈值(快速
                // 划过不触发),拖动中收起。位置由 root.layoutCards 管理:
                // 放大卡左右邻居对称让位(expandHalf),动画走 animX/animY
                // (220ms)与 animXBack/animYBack(120ms),均 OutCubic 无回弹。
                width: root.cardW
                height: root.cardH
                radius: 12
                color: card.hovered ? Qt.rgba(Theme.surface.r, Theme.surface.g,
                                              Theme.surface.b, 1) : Theme.surface
                // 拖动中半透明并置顶,松手恢复;放大卡同样置顶避免压边。
                opacity: Drag.active ? 0.6 : 1.0
                z: Drag.active ? 10 : (card.expanded ? 9 : 0)
                scale: card.expanded ? root.hoverScale : 1.0
                Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                // 官方拖放模式:MouseArea.drag 移动卡片自身并驱动 Drag.active。
                // Drag.source 是 QObject(卡片自身),drop 侧经 accountId 识别。
                Drag.active: dragArea.drag.active
                Drag.source: card
                Drag.hotSpot.x: width / 2
                Drag.hotSpot.y: height / 2
                property string accountId: card.modelData.id
                // 凭据失效(重登失败)标红边;拖动落点高亮用强调色。
                border.width: card.modelData.tokenValid === false ? 2 : (card.dropTarget ? 2 : 1)
                border.color: card.modelData.tokenValid === false ? Theme.danger
                              : (card.dropTarget ? Theme.accent
                              : (card.hovered ? Qt.rgba(Theme.accent.r, Theme.accent.g,
                                                        Theme.accent.b, 0.5)
                                              : Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 1)))
                property bool hovered: false
                property bool dropTarget: false
                property bool expanded: false
                // 新账号卡(无位置快照):直接定位 + 淡入,不参与重排位移动画。
                property bool isNew: false
                property real dragStartX: 0
                property real dragStartY: 0
                // 重排后按快照复位到旧位置(FLIP Invert),消除瞬移 (0,0)。
                // isNew 由账号 id 基线判定(非快照缺失):新 id 淡入出场;
                // 旧 id 重建(添加/重登)不误判,无快照时由布局静默定位。
                // 销毁前停掉所有动画:target 随 delegate 销毁,主动 stop
                // 避免动画引擎在失效对象上求值(QQmlVMEMetaObject internal
                // error——重登等触发的重建可能发生在动画进行中)。
                Component.onDestruction: {
                    animX.stop()
                    animY.stop()
                    animXBack.stop()
                    animYBack.stop()
                    opacityAnim.stop()
                }
                Component.onCompleted: {
                    const p = root.posSnapshot[card.modelData.id]
                    card.isNew = !root.prevAccountIds.includes(card.modelData.id)
                    if (p) {
                        card.x = p.x
                        card.y = p.y
                    } else if (card.isNew) {
                        card.opacity = 0
                    }
                    // Repeater 重建为异步(incubation):accountsChanged 触发的
                    // 1ms 布局可能跑在重建完成前。本 delegate 完成后主动触发
                    // 一次布局,同批次全部 onCompleted 会合并到同一 Timer 周期,
                    // 最终布局在全部 delegate 就绪后执行(幂等,仅动位置变化的卡)。
                    root.scheduleLayout()
                }

                // 放大状态变化 → 重排(左右邻居让位/复位)。
                onExpandedChanged: root.scheduleLayout()
                // 位移动画:线性插值 + easeOutCubic(挤压与复位一致,无回弹);
                // 复位 120ms < hover 触发 200ms,复原期间移回不会与放大
                // 动画冲突。手动 from/to 驱动(不设 Behavior,否则初始
                // 布局也会动画)。
                function animateTo(tx, ty, restore, fade, duration) {
                    if (Math.abs(card.x - tx) > 0.5) {
                        if (restore) {
                            animXBack.from = card.x
                            animXBack.to = tx
                            animXBack.start()
                        } else {
                            animX.duration = duration > 0 ? duration : root.moveDuration
                            animX.from = card.x
                            animX.to = tx
                            animX.start()
                        }
                    }
                    if (Math.abs(card.y - ty) > 0.5) {
                        if (restore) {
                            animYBack.from = card.y
                            animYBack.to = ty
                            animYBack.start()
                        } else {
                            animY.duration = duration > 0 ? duration : root.moveDuration
                            animY.from = card.y
                            animY.to = ty
                            animY.start()
                        }
                    }
                    // 跨行换行/被拖卡淡入(0.5→1),行内平移不淡。
                    if (fade && !restore) {
                        opacityAnim.from = 0.5
                        opacityAnim.to = 1
                        opacityAnim.start()
                    }
                }
                // 新账号卡:淡入(0→1)出场。
                function fadeInFromZero() {
                    opacityAnim.from = 0
                    opacityAnim.to = 1
                    opacityAnim.start()
                }
                NumberAnimation {
                    id: animX
                    target: card
                    property: "x"
                    duration: 220
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    id: animY
                    target: card
                    property: "y"
                    duration: 220
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    id: animXBack
                    target: card
                    property: "x"
                    duration: 120
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    id: animYBack
                    target: card
                    property: "y"
                    duration: 120
                    easing.type: Easing.OutCubic
                }
                // 重排淡入:跨行换行/被拖卡 0.5→1、新卡 0→1。
                NumberAnimation {
                    id: opacityAnim
                    target: card
                    property: "opacity"
                    duration: root.fadeDuration
                    easing.type: Easing.OutCubic
                }

                // hover 触发阈值:进入后 200ms 才放大,快速划过不触发;
                // 大于复原动画时长(120ms),复原期间移回不会与放大冲突。
                Timer {
                    id: hoverTimer
                    interval: 200
                    repeat: false
                    onTriggered: card.expanded = true
                }

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
                        customIcon: card.modelData.icon
                        defaultIcon: card.modelData.serverIcon
                        fallbackText: (card.modelData.name !== "" ? card.modelData.name : card.modelData.userName).charAt(0)
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
                            text: card.modelData.name !== "" ? card.modelData.name : card.modelData.userName
                            color: Theme.textPrimary
                            font.pixelSize: 15
                            font.bold: true
                            elide: Text.ElideRight
                            width: parent.width - (card.modelData.tokenValid === false ? 78 : 0)
                        }
                        AppText {
                            visible: card.modelData.tokenValid === false
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
                    onEntered: {
                        card.hovered = true
                        hoverTimer.start()
                    }
                    onExited: {
                        card.hovered = false
                        hoverTimer.stop()
                        card.expanded = false
                    }
                    onPressed: (mouse) => {
                        // 按住立即收起放大(hover 让位于拖动),并记录布局位置
                        // 与卡 id(root 级,drop 处理经此访问,不触碰可能已
                        // 随重建销毁的 drop.source)。
                        hoverTimer.stop()
                        card.expanded = false
                        card.dragStartX = card.x
                        card.dragStartY = card.y
                        root.pressCardId = card.accountId
                        root.pressStartX = card.x
                        root.pressStartY = card.y
                        root.dragDirty = false // 新一轮拖动,清模型变化标记
                    }
                    onClicked: (mouse) => {
                        // 右键弹出卡片菜单(设置图标等);左键点击无操作。
                        if (mouse.button === Qt.RightButton) {
                            cardMenu.accountId = card.modelData.id
                            cardMenu.currentIcon = card.modelData.icon
                            cardMenu.serverUrl = card.modelData.serverUrl
                            cardMenu.serverIcon = card.modelData.serverIcon
                            const g = card.mapToGlobal(mouse.x, mouse.y)
                            cardMenu.x = g.x
                            cardMenu.y = g.y
                            cardMenu.open()
                        }
                    }
                    onReleased: {
                        // 事件顺序:released 先于 drop 投递。Drag.drop() 在
                        // 本 handler 内投递 drop → onDropped → moveAccount →
                        // Repeater 重建会使本卡 delegate 的 context 失效
                        // (clearContext,对象未销毁)。此后本 handler 内任何
                        // id 解析(root/card)都会 ReferenceError,任何本卡
                        // QML 函数调用都会 "QQmlVMEMetaObject: Internal
                        // error - invalid context"(gdb 实证)。因此全部取值
                        // 在 drop 前完成:捕获根对象引用 r(JS 引用,属性读取
                        // 不走 context,drop 后仍可安全读 r.dragDirty)与
                        // 归位目标;drop 后不再做任何 id 查找。
                        const r = root
                        const sx = card.dragStartX
                        const sy = card.dragStartY
                        const act = card.Drag.drop()
                        // 仅当 drop 未投递(拖出窗口,IgnoreAction)且模型未变
                        // (dragDirty 仍 false,本卡有效)时手动归位;投递成功
                        // 时归位由 onDropped(from==to)或重排布局完成,本卡
                        // 已失效,不再触碰。
                        if (act === Qt.IgnoreAction && !r.dragDirty && card.animateTo)
                            card.animateTo(sx, sy, true)
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
                            customIcon: iconUrlField.text.trim()
                            defaultIcon: root.iconServerDefault
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
