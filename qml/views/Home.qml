import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import "qrc:/qml/theme"

//! 首页:每行一个媒体库,行首为库海报,后面是该库按加入时间倒序的最近条目。
//! 中间一行最大,上下行尺寸与透明度逐级递减(透视感)。
//! 点击条目进详情;库海报点击进媒体库页(暂推默认库,后续调整)。
Item {
    id: root

    signal showDetail(string itemId, string posterId, string title)
    // viewId 为被点击的媒体库 id,媒体库页打开时直接选中该库。
    signal openLibrary(string viewId)
    // 打开服务器管理页(未登录提示条入口)。
    signal openServerManager()

    // 聚合行(所有账号的媒体库,顺序按服务器管理中的账号排序)。
    property var rows: AccountManager.homeRows
    // 循环模型:rows 复制 3 份,始终在中间副本内滚动,边界时跳回中间副本,
    // 实现无限循环(网上通用做法:首尾复制模型作缓冲)。
    property var loopRows: []
    // 跨服导航:等待账号切换成功后再执行的跳转(见 ensureAccount)。
    property var pendingNav: null
    // 当前逻辑行(0..rows-1)与实测行距(负间距布局下相邻行 y 之差)。
    // 滚动直接按逻辑行换算 contentY(夹取在副本范围内),不依赖
    // indexAt/positionViewAtIndex 的估计定位——堆叠负间距下它们会错位,
    // 导致单格滚动不推进。
    property int rowIndex: 0
    // 连续绝对行索引(从中间副本起点 n 起,可滚入第三副本):回绕时
    // 跳回同逻辑行(对 rows 取模相同),视口内容不变,循环无缝。
    property int absRow: 0
    property real rowStep: 0
    // 滚轮速度(px/s):最近 350ms 窗口内滚轮步长换算,驱动滚动动画
    // 时长(距离/速度)——滚得越快动画越快,内容跟得上节奏不丢动画。
    property real scrollVelocity: 800
    property var wheelLog: []

    // 记录滚轮事件步长并换算滚动速度(行/秒 → px/s,夹到合理范围)。
    function noteWheel(step) {
        const now = Date.now()
        root.wheelLog.push([now, step])
        while (root.wheelLog.length > 0 && now - root.wheelLog[0][0] > 350)
            root.wheelLog.shift()
        let total = 0
        for (let i = 0; i < root.wheelLog.length; i++)
            total += root.wheelLog[i][1]
        const first = root.wheelLog[0]
        const last = root.wheelLog[root.wheelLog.length - 1]
        const span = last[0] - first[0]
        const rowsPerSec = span > 0 ? total * 1000 / span : 0
        root.scrollVelocity = Math.max(300, Math.min(3200, rowsPerSec * root.rowStep))
    }

    // 平滑滚动动画对象:每次滚动新建(见 scrollBy)——QML 动画对象复用
    // 有状态残留导致 start() 偶发无效,新对象保证动画必然执行。
    // 时长按滚轮速度动态换算,快速滚动时动画更快,内容跟得上节奏。
    property var scrollAnim: null
    // 横向条目滚动动画对象(普通滚轮驱动),模式同 scrollAnim。
    property var hAnim: null

    // 选中块:焦点行(loopRows 索引,几何居中行)与列(-1=库海报,≥0=条目)。
    // 上下滚动后选中新居中行的库海报;左右键在可视区内移动列,
    // 到边缘滚动展示内容,内容到头做拉动画。
    property int focusRowIdx: 0
    property int focusCol: -1

    // 几何居中行(loopRows 索引):负间距堆叠下视口中心的行——absRow
    // 行贴视口顶部,视觉居中的无缩放行必须按中心距实测(遍历可见行)。
    function findCenterRowIndex() {
        let best = -1
        let bestDist = Infinity
        for (let i = 0; i < list.count; ++i) {
            const d = list.itemAtIndex(i)
            if (!d)
                continue
            const cy = d.y + d.height / 2 - list.contentY
            const dist = Math.abs(cy - list.height / 2)
            if (dist < bestDist) {
                bestDist = dist
                best = i
            }
        }
        return best
    }

    // 焦点行 delegate(可能未实例化返回 null)。
    function focusRow() {
        return list.itemAtIndex(root.focusRowIdx)
    }

    // 焦点行横向条目视图的 contentX 动画(新建对象,先 stop 再 destroy)。
    function animateContentX(v, to, withBounce) {
        const from = v.contentX
        const dist = Math.abs(to - from)
        if (dist < 0.5)
            return
        if (root.hAnim) {
            root.hAnim.stop()
            root.hAnim.destroy()
            root.hAnim = null
        }
        root.hAnim = Qt.createQmlObject(
            'import QtQuick; NumberAnimation { property: "contentX"; easing.type: Easing.OutCubic }',
            root)
        root.hAnim.target = v
        root.hAnim.from = from
        root.hAnim.to = to
        if (withBounce) {
            root.hAnim.easing.type = Easing.OutBack
            root.hAnim.easing.overshoot = 1.6
        }
        root.hAnim.duration = Math.max(30, Math.min(250, dist / root.scrollVelocity * 1000))
        root.hAnim.start()
    }

    // 横向滚动展示当前焦点行(居中行)的条目:每次滚两卡,行首库海报
    // 固定不动,只移动剧集/电影的海报图。
    function scrollRow(step) {
        const row = root.focusRow()
        if (!row || !row.rowItemsView)
            return
        const v = row.rowItemsView
        // 每次滚一格(卡片宽+间距)。
        const cell = 112 + 12
        const from = v.contentX
        const target = Math.max(0, Math.min(v.contentWidth - v.width, from + step * cell))
        if (Math.abs(target - from) < 0.5)
            return
        root.noteWheel(step)
        root.animateContentX(v, target, true)
    }

    // 上下滚动切换媒体库行(上下键 / Ctrl+滚轮):滚动后选中新居中行的
    // 媒体库海报(focusRowIdx 由 contentY 变化实时更新)。
    function moveRow(step) {
        root.focusCol = -1
        root.scrollBy(step)
    }

    // 左右移动选中块(左右键 / 普通滚轮):可视区内逐列移动;焦点到
    // 可视区边缘时滚动展示内容;内容到头时做拉动画。delta +1 向右。
    function moveCol(delta) {
        const row = root.focusRow()
        if (!row || !row.rowItemsView)
            return
        const v = row.rowItemsView
        const cell = 112 + 12
        const maxCol = v.count - 1
        if (root.focusCol === -1) {
            if (delta > 0) {
                // 库海报 → 第一个条目;内容已滚动则先滚回开头。
                root.focusCol = 0
                if (v.contentX > 0.5)
                    root.animateContentX(v, 0, false)
                return
            }
            root.pullAnim(-1) // 库海报已是左端,左拉表示到头
            return
        }
        const newCol = root.focusCol + delta
        if (newCol < 0) {
            // 回到库海报,内容滚回开头。
            root.focusCol = -1
            if (v.contentX > 0.5)
                root.animateContentX(v, 0, false)
            return
        }
        if (newCol > maxCol) {
            // 内容末尾:还能滚动则滚动展示,否则到头拉动画。
            if (v.contentX + v.width < v.contentWidth - 1)
                root.scrollRow(1)
            else
                root.pullAnim(1)
            return
        }
        root.focusCol = newCol
        // 焦点出可视区则滚动跟随(右缘向前滚,左缘向后滚)。
        const colStart = Math.floor(v.contentX / cell)
        const colEnd = colStart + Math.floor(v.width / cell) - 1
        if (root.focusCol > colEnd)
            root.scrollRow(1)
        else if (root.focusCol < colStart)
            root.scrollRow(-1)
    }

    // 到头拉动画:内容向滚动意图方向超冲一点再弹回(橡皮筋,表示已到
    // 尽头)。direction +1 = 向右滚的意图, -1 = 向左。
    // 两段顺序动画用声明式 SequentialAnimation(动态设 target/from/to),
    // 避免 JS 闭包持有动态对象不可靠的问题。
    function pullAnim(direction) {
        const row = root.focusRow()
        if (!row || !row.rowItemsView)
            return
        const v = row.rowItemsView
        const maxX = Math.max(0, v.contentWidth - v.width)
        const over = 24
        pullSeq.stop()
        pullOut.target = v
        pullOut.from = v.contentX
        pullOut.to = direction > 0 ? maxX + over : -over
        pullBack.target = v
        pullBack.from = pullOut.to
        pullBack.to = direction > 0 ? maxX : 0
        pullSeq.start()
    }

    // 拉动画两段:先冲出边界(约 24px),再弹回边界。
    SequentialAnimation {
        id: pullSeq
        NumberAnimation {
            id: pullOut
            property: "contentX"
            duration: 110
            easing.type: Easing.OutQuad
        }
        NumberAnimation {
            id: pullBack
            property: "contentX"
            duration: 240
            easing.type: Easing.OutBack
            easing.overshoot: 1.4
        }
    }

    function rebuildLoop() {
        // 模型重建旧行销毁,横向动画若还在跑会写到已销毁的视图上,先停。
        if (root.hAnim) {
            root.hAnim.stop()
            root.hAnim.destroy()
            root.hAnim = null
        }
        pullSeq.stop()
        const prevAbs = root.absRow
        root.loopRows = root.rows.concat(root.rows).concat(root.rows)
        // 模型重建后旧 contentY 可能越界(视口外全黑),延迟到布局更新后
        // 按逻辑行定位。保留滚动位置:rows 异步刷新完成触发 rebuildLoop
        // 时若跳回起点,滚动中会瞬间跳变(动画"消失")。
        if (root.rows.length > 0) {
            if (prevAbs >= 0 && prevAbs < 3 * root.rows.length) {
                root.absRow = prevAbs
            } else {
                root.absRow = root.rows.length
            }
            root.rowIndex = root.absRow % root.rows.length
            root.rowStep = 0
            Qt.callLater(function () {
                root.ensureRowStep()
                list.contentY = root.absRow * root.rowStep
                // 初始 contentY 可能恰为 0(0→0 不触发 onContentYChanged),
                // 显式初始化焦点行为几何居中行;行位置下一帧才稳定,再查一次。
                root.focusRowIdx = root.findCenterRowIndex()
                Qt.callLater(function () {
                    root.focusRowIdx = root.findCenterRowIndex()
                })
            })
        }
    }

    // 实测行距:从相邻可见行取 y 差(负间距下为 行高 + 负间距)。
    // 内容起点行数(第一副本)可能未被实例化,故从可见区取样。
    function ensureRowStep() {
        if (root.rowStep > 0)
            return
        for (let i = 0; i < list.count - 1; i++) {
            const a = list.itemAtIndex(i)
            const b = list.itemAtIndex(i + 1)
            if (a && b && b.y > a.y) {
                root.rowStep = b.y - a.y
                return
            }
        }
        // 兜底:行高(标题约 24 + 卡片 172)减重叠 44。
        root.rowStep = 152
    }

    // 循环滚动:绝对行索引推进,目标 contentY 经 NumberAnimation 动画
    // (每次新建对象,时长按滚轮速度动态换算:快速滚动动画更快,
    // contentY 跟得上节奏,不累积滞后丢动画)。回绕/首滚的不可见
    // 传送:销毁动画对象后瞬间定位(同逻辑行,视觉不变)。
    function scrollBy(step) {
        const n = root.rows.length
        if (n === 0)
            return
        root.ensureRowStep()
        root.noteWheel(step)
        // 首次/模型重建后 contentY 可能停在 0(第一副本起点,定位未生效):
        // 中间副本及之后的滚动瞬间校正到对应行,避免首滚跳变。
        if (root.absRow >= n && list.contentY < n * root.rowStep) {
            if (root.scrollAnim) {
                // destroy 延迟到安全点才真正删除,先 stop 停止写 contentY,
                // 避免旧动画继续朝旧目标走和新动画打架。
                root.scrollAnim.stop()
                root.scrollAnim.destroy()
                root.scrollAnim = null
            }
            list.contentY = root.absRow * root.rowStep
        }
        root.absRow += step
        const maxY = list.contentHeight - list.height
        // 回绕:先把 contentY 传送到"当前视觉行"的中间副本——逻辑行
        // 相同、内容一致,视觉无感(不可见传送);absRow 同步后再按
        // step 正常步进,回绕那格就是普通一格的平滑滚动。
        if (root.absRow * root.rowStep > maxY || root.absRow < 0) {
            let curAbs = Math.max(0, Math.floor(list.contentY / root.rowStep))
            let mid = curAbs
            if (curAbs >= 2 * n)
                mid = curAbs - n
            else if (curAbs < n)
                mid = curAbs + n
            root.absRow = mid
            if (root.scrollAnim) {
                root.scrollAnim.stop()
                root.scrollAnim.destroy()
                root.scrollAnim = null
            }
            list.contentY = mid * root.rowStep
            root.absRow += step
        }
        // 副本范围兜底 [0, 3n)。
        root.absRow = Math.max(0, Math.min(3 * n - 1, root.absRow))
        root.rowIndex = root.absRow % n
        const target = root.absRow * root.rowStep
        const dist = Math.abs(target - list.contentY)
        if (dist > 0.5) {
            // 每次新建动画对象,start 必然生效;旧对象先 stop 再 destroy,
            // 避免延迟删除期间旧动画继续写 contentY。
            if (root.scrollAnim) {
                root.scrollAnim.stop()
                root.scrollAnim.destroy()
                root.scrollAnim = null
            }
            root.scrollAnim = Qt.createQmlObject(
                'import QtQuick; NumberAnimation { target: list; property: "contentY"; easing.type: Easing.OutCubic }',
                root)
            root.scrollAnim.from = list.contentY
            root.scrollAnim.to = target
            // 大幅滚动(单次≥2行)结尾超调目标再回弹:OutBack 是 boomerang
            // 曲线,末段越过终点再返回,overshoot 控制超调幅度(约 17%)。
            // 小幅滚动保持 OutCubic 平滑收尾,回弹会显得拖沓;快速连滚
            // 每步 1 行不弹,不打断节奏。超调期间仍在中间副本内不露边界。
            if (dist >= root.rowStep * 2) {
                root.scrollAnim.easing.type = Easing.OutBack
                root.scrollAnim.easing.overshoot = 2.0
            }
            // 动态时长:距离/滚轮速度(px/s)。慢速滚动长动画平滑,
            // 快速滚动动画更快,内容移动速度与滚轮一致,不丢动画。
            root.scrollAnim.duration = Math.max(30, Math.min(250, dist / root.scrollVelocity * 1000))
            root.scrollAnim.start()
        } else {
            if (root.scrollAnim) {
                root.scrollAnim.stop()
                root.scrollAnim.destroy()
                root.scrollAnim = null
            }
            list.contentY = target
        }
    }

    // 行点击目标账号与当前会话一致则立即执行,否则先切换账号再执行。
    // 行跨服时切换会话后详情/媒体库页按该服数据打开。
    function ensureAccount(accountId, action) {
        if (accountId === "" || accountId === AccountManager.activeAccountId) {
            action()
            return
        }
        root.pendingNav = action
        AccountManager.switchAccount(accountId)
    }

    // 聚合拉取不依赖当前会话(每服用各自缓存的 token),有账号即拉;
    // 账号增删/排序变化(accountsChanged)时按新顺序重拉。
    Component.onCompleted: {
        if (AccountManager.hasAccounts)
            AccountManager.fetchHomeRows(20)
        root.forceActiveFocus()
    }

    // 未登录提示条:没有任何已保存账号时覆盖在首页上方,提供服务器管理入口。
    Rectangle {
        visible: !AccountManager.hasAccounts
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: 16
        width: Math.min(420, parent.width - 32)
        height: 44
        radius: 8
        color: Theme.surface
        border.width: 1
        border.color: Theme.accent

        Row {
            anchors.centerIn: parent
            spacing: 12
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "未添加服务器，添加后即可浏览媒体库"
                color: Theme.textPrimary
                font.pixelSize: 13
            }
            Button {
                text: "服务器管理"
                onClicked: root.openServerManager()
            }
        }
    }

    Connections {
        target: AccountManager
        function onHomeRowsReady() {
            root.rows = AccountManager.homeRows
            root.rebuildLoop()
        }
        function onAccountsChanged() {
            if (AccountManager.hasAccounts)
                AccountManager.fetchHomeRows(20)
        }
        function onAccountLoginFinished(ok) {
            if (ok && root.pendingNav) {
                const nav = root.pendingNav
                root.pendingNav = null
                nav()
            } else if (!ok) {
                root.pendingNav = null
            }
        }
    }
    onRowsChanged: if (root.rows.length > 0) root.rebuildLoop()

    // 每行条目卡片(库海报或媒体条目)。尺寸由调用处指定(cardW/cardH),
    // 有图时底部显示标题,无图时居中显示占位文字。
    component RowCard: Rectangle {
        property string cardImage: ""
        property string cardText: ""
        property bool isLibrary: false
        property bool selected: false
        property int cardW: 112
        property int cardH: 168
        property alias cardArea: cardArea
        width: cardW
        height: cardH
        color: Theme.surface
        radius: 10
        // 选中块高亮(accent 边框);悬停次之。
        border.width: selected ? 3 : (cardArea.hovered ? 2 : 0)
        border.color: Theme.accent
        Image {
            anchors.fill: parent
            anchors.leftMargin: 5
            anchors.rightMargin: 5
            anchors.topMargin: 5
            anchors.bottomMargin: 22
            source: cardImage !== "" ? "image://emby/" + cardImage : ""
            fillMode: Image.PreserveAspectCrop
            cache: true
            // 异步解码:大量海报同时加载时避免阻塞 UI 线程导致滚动卡顿。
            asynchronous: true
        }
        Text {
            visible: cardImage === ""
            anchors.centerIn: parent
            text: cardText
            color: Theme.textPrimary
            font.pixelSize: isLibrary ? 16 : 13
            font.bold: isLibrary
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            width: parent.width - 8
            wrapMode: Text.Wrap
        }
        Text {
            visible: cardImage !== ""
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            anchors.bottomMargin: 3
            text: cardText
            color: Theme.textPrimary
            font.pixelSize: isLibrary ? 13 : 12
            font.bold: isLibrary
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
        }
        MouseArea {
            id: cardArea
            anchors.fill: parent
            hoverEnabled: true
        }
    }

    // 堆叠式竖向轮盘:行与行部分重叠(负间距),中间行最前最亮,
    // 上下行被相邻行覆盖一部分并逐级缩小变暗(类似应用库的堆叠效果,
    // 但间距更大,适合媒体库浏览)。
    // 键盘四向控制:上下切换媒体库行,左右移动选中块;与滚轮共用逻辑。
    focus: true
    Keys.onUpPressed: root.moveRow(-1)
    Keys.onDownPressed: root.moveRow(1)
    Keys.onLeftPressed: root.moveCol(-1)
    Keys.onRightPressed: root.moveCol(1)
    // 页面回到前台时恢复键盘焦点。
    onVisibleChanged: if (root.visible) root.forceActiveFocus()
    // 滚动时实时更新焦点行(选中块跟随居中的无缩放行)。
    ListView {
        id: list
        anchors.fill: parent
        clip: true
        model: root.loopRows
        spacing: -44
        onContentYChanged: root.focusRowIdx = root.findCenterRowIndex()
        // 缓冲只保留约 1.5 行:堆叠行内容较重(每行多张海报),
        // 过大的默认缓冲会让大量行同时实例化拖慢滚动。
        cacheBuffer: 300
        // 不强制 highlight 居中:contentY 由 scrollBy 按逻辑行精确设置,
        // 且不启用 snap(负间距堆叠下 snap 会把 contentY 吸回旧位置,
        // 导致单格滚动不推进)。
        highlightRangeMode: ListView.NoHighlightRange
        // 纯滚轮驱动(外层 MouseArea):禁拖拽,避免与滚动动画冲突。
        interactive: false

        delegate: Column {
            id: rowDelegate
            width: list.width
            transformOrigin: Item.Top
            // 行数据快照:modelData 是委托上下文变量,不能作为对象属性
            // (rowDelegate.modelData)访问;存入显式属性供嵌套卡片取行级信息。
            property var rowData: modelData
            // 供 scrollRow 访问横向条目视图(只移动条目海报)。
            property alias rowItemsView: rowItems
            // 本行在 loopRows 中的索引,供选中块高亮判定。
            property int rowIndex: index
            // 行中心到视口中心的距离(随滚动变化)驱动缩放与透明度。
            function centerDist() {
                const centerY = rowDelegate.y + rowDelegate.height / 2 - list.contentY
                return Math.abs(centerY - list.height / 2)
            }
            // 堆叠缩放/透明度:距中心越远越小越暗。
            function stackScale() {
                const maxDist = Math.max(1, list.height / 2 - 60)
                return Math.max(0.55, 1 - 0.14 * rowDelegate.centerDist() / maxDist)
            }
            function stackOpacity() {
                const maxDist = Math.max(1, list.height / 2 - 60)
                return Math.max(0.3, 1 - 0.7 * rowDelegate.centerDist() / maxDist)
            }
            // 堆叠层级:距视口中心越近越靠前(离散三档,滚动动画中跨档
            // 才重排场景图,比逐帧浮点 z 便宜得多);中间行最前可点,
            // 上下行被相邻行覆盖。
            z: {
                const d = rowDelegate.centerDist()
                return d < 90 ? 3 : (d < 220 ? 2 : 1)
            }
            // 滚动动画中实时过渡:行随距中心距离连续缩放/变暗。
            scale: rowDelegate.stackScale()
            opacity: rowDelegate.stackOpacity()

            // 行标题:服务器名 - 媒体库名(同一服务器多库时区分来源)。
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: modelData.serverName !== ""
                        ? modelData.serverName + " - " + modelData.viewName
                        : modelData.viewName
                color: Theme.textPrimary
                font.pixelSize: 17
                font.bold: true
            }
            // 行内容:宽度为视口宽,条目多时右侧裁剪(拉取数量保证
            // 首屏尽量填满)。条目用横向 ListView 虚拟化,只实例化
            // 可见卡片,避免每行 1 张海报全部加载拖慢滚动。
            Item {
                width: list.width
                height: 172
                clip: true
                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 24
                    spacing: 12
                    // 库海报(行首):焦点在库海报且本行为居中行时高亮。
                    // z 置顶:左拉动画(contentX 负)时条目卡可能短暂越出
                    // ListView 边界,保证库海报始终在条目海报上层。
                    RowCard {
                        z: 1
                        cardImage: modelData.posterId || ""
                        cardText: modelData.viewName
                        isLibrary: true
                        cardW: 124
                        cardH: 172
                        selected: rowDelegate.rowIndex === root.focusRowIdx && root.focusCol === -1
                        cardArea.onClicked: root.ensureAccount(modelData.accountId,
                            function () { root.openLibrary(modelData.viewId) })
                    }
                    // 该库最近条目:横向滚动列表,虚拟化渲染。
                    ListView {
                        id: rowItems
                        width: list.width - 24 - 124 - 12
                        height: 172
                        orientation: ListView.Horizontal
                        spacing: 12
                        // 裁剪到自身边界:拉动画/回滚时 contentX 会短暂越界,
                        // 不裁剪则条目卡会覆盖到左侧库海报上。
                        clip: true
                        // 纯展示:滚轮由外层竖向处理,避免嵌套滚动冲突。
                        interactive: false
                        model: modelData.items
                        delegate: RowCard {
                            cardImage: modelData.posterId || ""
                            cardText: modelData.name
                            cardW: 112
                            cardH: 172
                            // 内层 modelData 是条目,行级 accountId 从 rowData 取。
                            // 选中块高亮:本行为居中行且列索引匹配。
                            selected: rowDelegate.rowIndex === root.focusRowIdx && index === root.focusCol
                            cardArea.onClicked: function () {
                                // 点击即选中该卡,并保持行焦点同步。
                                root.focusRowIdx = rowDelegate.rowIndex
                                root.focusCol = index
                                root.ensureAccount(rowDelegate.rowData.accountId,
                                    function () {
                                        root.showDetail(modelData.id, modelData.posterId || "",
                                                        modelData.name)
                                    })
                            }
                        }
                    }
                }
            }
        }
    }

    // 滚轮无缝循环:每格按一个"可见行"滚动,回绕跳回同逻辑行
    // (视觉内容不变)。向上滚上移,向下滚下移。
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton // 不拦截点击,只接收滚轮
        onWheel: function (wheel) {
            // 与键盘共用逻辑:普通滚轮=左右键(选中块移动/滚动/拉动画),
            // Ctrl+滚轮=上下键(切换媒体库行)。速度记账在 scrollBy/
            // scrollRow 内做,这里不重复。
            const delta = Math.round(wheel.angleDelta.y / 120)
            if (delta === 0)
                return
            if (wheel.modifiers & Qt.ControlModifier)
                root.moveRow(-delta)
            else
                root.moveCol(-delta)
            wheel.accepted = true
        }
    }
}
