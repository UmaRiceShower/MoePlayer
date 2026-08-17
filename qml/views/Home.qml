pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import MoePlayer.Core

//! 首页:每行一个媒体库,行首为库海报,后面是该库按加入时间倒序的最近条目。
//! 中间一行最大,上下行尺寸与透明度逐级递减(透视感)。
//! 点击条目进详情;库海报点击进媒体库页(暂推默认库,后续调整)。
Item {
    id: root

    // 聚合行(所有账号的媒体库,顺序按服务器管理中的账号排序)。
    // 节流:homeRowsReady 可能连续触发(缓存先行 → 网络刷新 → 重登重拉),
    // 合并后一次替换 rows,避免模型在行 delegate 孵化期间被 reset 打断
    // (Qt "Cannot create delegate" 警告 + VMEMetaObject internal error)。
    property var rows: []
    property var pendingRows: []
    // 最近一次行 delegate 就绪时刻(rowReady):替换 rows 前须确认上一轮
    // 行孵化已稳定(无新就绪超过 settleMs),否则 model 替换会打断孵化,
    // Qt 引擎在失效 context 上求值,打印 "QQmlVMEMetaObject: Internal
    // error"。行就绪信号驱动比固定时间窗可靠(孵化时长随行数变化)。
    property double lastRowReady: 0
    readonly property int rowsSettleMs: 400
    // 循环模型:rows 复制 3 份,始终在中间副本内滚动,边界时跳回中间副本,
    // 实现无限循环(网上通用做法:首尾复制模型作缓冲)。
    property var loopRows: []
    // 行重建代次:rows 每次刷新 +1;延迟定位回调携带代次,过期即跳过
    // (防回调操作已重建的行,见 locateTimer)。
    property int loopGen: 0
    property int locateGen: 0
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
    property real scrollVelocity: Constants.scrollVelocityInitial
    // 滚轮速度记账窗口(首尾时间/累计步长):O(1) 更新,无数组 shift。
    property var wheelLog: ({ count: 0, total: 0, firstT: 0, lastT: 0 })

    // 平滑滚动动画对象:声明式复用(官方动画文档模式——stop 后重设
    // from/to/target 再 start 即可复用,无状态残留)。运行时设
    // target/from/to/duration,easing 按滚动类型切换。
    NumberAnimation {
        id: scrollAnim
        property: "contentY"
        running: false
        easing.type: Easing.OutCubic
    }
    // 横向条目滚动动画对象(普通滚轮驱动),模式同 scrollAnim。
    NumberAnimation {
        id: hAnim
        property: "contentX"
        running: false
        easing.type: Easing.OutCubic
    }

    // 选中块:焦点行(loopRows 索引,几何居中行)与列(-1=库海报,≥0=条目)。
    // 上下滚动后选中新居中行的库海报;左右键在可视区内移动列,
    // 到边缘滚动展示内容,内容到头做拉动画。
    property int focusRowIdx: 0
    property int focusCol: -1

    signal showDetail(string itemId, string posterId, string title, string serverUrl)
    // viewId 为被点击的媒体库 id,serverUrl 为其所在服务器:媒体库页直接
    // 按该服务器凭据浏览(无状态,无需切换会话)。viewName 为库名:首页
    // 海报本就携带,传给媒体库页供面包屑立即显示(不等视图拉取)。
    signal openLibrary(string viewId, string serverUrl, string viewName)
    // 打开服务器管理页(未登录提示条入口)。
    signal openServerManager()

    // 聚合拉取不依赖当前会话(每服用各自缓存的 token),有账号即拉;
    // 启动同时校验各服 token(/System/Info 轻量认证,401 即失效,见
    // AccountManager.validateTokens);账号增删/排序变化(accountsChanged)
    // 时按新顺序重拉。
    Component.onCompleted: {
        if (AccountManager.hasAccounts) {
            AccountManager.fetchHomeRows(Constants.homePerLibraryLimit)
            AccountManager.validateTokens()
        }
        root.forceActiveFocus()
    }
    onRowsChanged: if (root.rows.length > 0) root.rebuildLoop()
    Keys.onUpPressed: root.moveRow(-1)
    Keys.onDownPressed: root.moveRow(1)
    Keys.onLeftPressed: root.moveCol(-1)
    Keys.onRightPressed: root.moveCol(1)
    // Enter/回车:进入当前选中的块。
    Keys.onReturnPressed: root.activateFocus()
    Keys.onEnterPressed: root.activateFocus()
    // 页面回到前台时恢复键盘焦点。
    onVisibleChanged: if (root.visible) root.forceActiveFocus()

    // 记录滚轮事件步长并换算滚动速度(行/秒 → px/s,夹到合理范围)。
    function noteWheel(step) {
        const now = Date.now()
        const w = root.wheelLog
        if (w.count === 0 || now - w.firstT > Constants.wheelLogWindowMs) {
            // 窗口过期/空:重置窗口(单条)。
            root.wheelLog = { count: 1, total: step, firstT: now, lastT: now }
        } else {
            // 窗口内:累计步长,滑动 lastT(窗口内总和/跨度 = 速度)。
            root.wheelLog = { count: w.count + 1, total: w.total + step, firstT: w.firstT, lastT: now }
        }
        const span = root.wheelLog.lastT - root.wheelLog.firstT
        const rowsPerSec = span > 0 ? root.wheelLog.total * 1000 / span : 0
        root.scrollVelocity = Math.max(Constants.scrollVelocityMin, Math.min(Constants.scrollVelocityMax, rowsPerSec * root.rowStep))
    }

    // 几何居中行(loopRows 索引):负间距堆叠下视口中心的行。几何公式
    // 计算,不遍历/访问行 delegate——rows 重建时行 delegate 在销毁/孵化
    // 中,遍历访问其 y/height 会触发引擎 "invalid context" 错误。
    // 布局规则:相邻行距恒为 rowStep(实测,行高-重叠),行 i 的
    // y = i*rowStep(y0=0,y1=行高-重叠=rowStep);行高 = rowStep + overlap。
    // rowStep 未实测(重建中)时保持旧焦点,等行就绪后由 locateTimer
    // 重新实测并定位。
    function findCenterRowIndex() {
        const n = list.count
        if (n <= 0 || root.rowStep <= 0)
            return root.focusRowIdx
        const rowH = root.rowStep + Constants.rowOverlap
        const cy = list.contentY + list.height / 2
        // 行 i 中心 = i*rowStep + rowH/2 → 反解 i 取整。
        return Math.max(0, Math.min(n - 1, Math.round((cy - rowH / 2) / root.rowStep)))
    }

    // 焦点行 delegate(可能未实例化返回 null)。
    function focusRow() {
        return list.itemAtIndex(root.focusRowIdx)
    }

    // 焦点行横向条目视图的 contentX 动画(复用 hAnim,stop 后重设再 start)。
    function animateContentX(v, to, withBounce) {
        const from = v.contentX
        const dist = Math.abs(to - from)
        if (dist < 0.5)
            return
        hAnim.stop()
        hAnim.target = v
        hAnim.from = from
        hAnim.to = to
        hAnim.easing.type = withBounce ? Easing.OutBack : Easing.OutCubic
        hAnim.easing.overshoot = Constants.bounceOvershoot
        hAnim.duration = Math.max(Constants.animMinMs, Math.min(Constants.animMaxMs, dist / root.scrollVelocity * 1000))
        hAnim.start()
    }

    // 横向滚动展示当前焦点行(居中行)的条目:每次滚两卡,行首库海报
    // 固定不动,只移动剧集/电影的海报图。
    function scrollRow(step) {
        const row = root.focusRow()
        if (!row || !row.rowItemsView)
            return
        const v = row.rowItemsView
        // 每次滚一格(卡片宽+间距)。
        const cell = Constants.rowCellStep
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
        const cell = Constants.rowCellStep
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
        const over = Constants.pullOverrun
        pullSeq.stop()
        pullOut.target = v
        pullOut.from = v.contentX
        pullOut.to = direction > 0 ? maxX + over : -over
        pullBack.target = v
        pullBack.from = pullOut.to
        pullBack.to = direction > 0 ? maxX : 0
        pullSeq.start()
    }

    function rebuildLoop() {
        // 模型重建旧行销毁,横向动画若还在跑会写到已销毁的视图上,先停。
        hAnim.stop()
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
            // 行将重建:递增代次使 locateGen !== loopGen,重建期间的行遍历
            // (findCenterRowIndex/ensureRowStep)被代次守卫跳过,避免访问
            // 销毁/孵化中的 delegate 触发引擎 "invalid context" 错误。
            // 定位由"行 delegate 就绪"驱动:行实例化完成(Component.
            // onCompleted → rowReady)→ locateTimer → 实测行距并定位 →
            // locateGen 更新为本代,后续遍历恢复。
            ++root.loopGen
        }
    }

    // 行 delegate 实例化完成(rebuildLoop 后重建的行就绪)→ 触发定位,
    // 并记录就绪时刻供 rows 替换门控判定孵化稳定(见 rowsTimer)。
    // 虚拟化下每批实例化都会调用,locateTimer 重启合并,最后一次生效。
    function rowReady() {
        root.lastRowReady = Date.now()
        locateTimer.restart()
    }

    // 行距:行高(标题 24 + 卡片 172,行 delegate 显式约束)减重叠 44,
    // 常量布局公式即精确。不遍历行 delegate——rows 重建时行在销毁/
    // 孵化中,遍历访问会触发引擎 "invalid context" 错误。
    function ensureRowStep() {
        if (root.rowStep <= 0)
            root.rowStep = Constants.rowStepFallback
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
            scrollAnim.stop()
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
            scrollAnim.stop()
            list.contentY = mid * root.rowStep
            root.absRow += step
        }
        // 副本范围兜底 [0, 3n)。
        root.absRow = Math.max(0, Math.min(3 * n - 1, root.absRow))
        root.rowIndex = root.absRow % n
        const target = root.absRow * root.rowStep
        const dist = Math.abs(target - list.contentY)
        if (dist > 0.5) {
            // 复用动画对象:stop 停止写 contentY,重设 from/to 再 start,
            // 旧目标与新动画不打架(官方动画复用模式)。
            scrollAnim.stop()
            scrollAnim.target = list
            scrollAnim.from = list.contentY
            scrollAnim.to = target
            // 大幅滚动(单次≥2行)结尾超调目标再回弹:OutBack 是 boomerang
            // 曲线,末段越过终点再返回,overshoot 控制超调幅度(约 17%)。
            // 小幅滚动保持 OutCubic 平滑收尾,回弹会显得拖沓;快速连滚
            // 每步 1 行不弹,不打断节奏。超调期间仍在中间副本内不露边界。
            scrollAnim.easing.type = dist >= root.rowStep * 2 ? Easing.OutBack : Easing.OutCubic
            scrollAnim.easing.overshoot = Constants.bigBounceOvershoot
            // 动态时长:距离/滚轮速度(px/s)。慢速滚动长动画平滑,
            // 快速滚动动画更快,内容移动速度与滚轮一致,不丢动画。
            scrollAnim.duration = Math.max(Constants.animMinMs, Math.min(Constants.animMaxMs, dist / root.scrollVelocity * 1000))
            scrollAnim.start()
        } else {
            scrollAnim.stop()
            list.contentY = target
        }
    }

    // Enter/回车进入当前选中的块:库海报打开媒体库页,条目进详情。
    // 与卡片点击走同一路径(行数据带目标服务器,浏览无状态化后无需切会话)。
    function activateFocus() {
        const row = root.focusRow()
        if (!row || !row.rowData)
            return
        if (root.focusCol === -1) {
            root.openLibrary(row.rowData.viewId, row.rowData.serverUrl,
                             row.rowData.viewName)
            return
        }
        const items = row.rowData.items
        if (root.focusCol >= items.length)
            return
        const item = items[root.focusCol]
        root.showDetail(item.id, item.posterId || "", item.name, row.rowData.serverUrl)
    }

    // 鼠标按住拖动(跟手方向):上滑→媒体库行前进(内容上移,看到后面
    // 的库),下滑→行后退;左滑→条目向右浏览,右滑→向左。调用方
    // (卡片 MouseArea / 空白区 MouseArea)累计位移超阈值后调用,并
    // 重置起点以便连续拖动。
    function handleDrag(dx, dy) {
        if (Math.abs(dy) > Math.abs(dx))
            root.moveRow(dy < 0 ? 1 : -1)
        else
            root.moveCol(dx < 0 ? 1 : -1)
    }

    // 堆叠式竖向轮盘:行与行部分重叠(负间距),中间行最前最亮,
    // 上下行被相邻行覆盖一部分并逐级缩小变暗(类似应用库的堆叠效果,
    // 但间距更大,适合媒体库浏览)。
    // 键盘四向控制:上下切换媒体库行,左右移动选中块;与滚轮共用逻辑。
    focus: true

    Timer {
        id: rowsTimer
        onTriggered: {
            // 无行(空数据)或最近无行就绪(孵化稳定)→ 可替换;否则等稳定。
            if (list.count > 0
                && Date.now() - root.lastRowReady < root.rowsSettleMs) {
                root.pendingRows = AccountManager.homeRows // 取最新,继续等
                rowsTimer.restart()
                return
            }
            // 替换即孵化开始:立即刷新就绪时刻,孵化窗口内(新行尚未
            // 就绪)的再次替换被门控拦截,避免打断孵化触发引擎错误。
            root.lastRowReady = Date.now()
            root.rows = root.pendingRows
        }
        interval: 40
        repeat: false
    }

    // 拉动画两段:先冲出边界(约 24px),再弹回边界。
    SequentialAnimation {
        id: pullSeq
        NumberAnimation {
            id: pullOut
            property: "contentX"
            duration: Constants.pullOutMs
            easing.type: Easing.OutQuad
        }
        NumberAnimation {
            id: pullBack
            property: "contentX"
            duration: Constants.pullBackMs
            easing.type: Easing.OutBack
            easing.overshoot: Constants.pullOvershoot
        }
    }

    // 延迟定位(替代 Qt.callLater,见 rebuildLoop):事件循环级延迟,
    // rows 连续刷新时按代次丢弃过期回调;组件销毁即随 Timer 取消。
    Timer {
        id: locateTimer
        onTriggered: {
            const gen = root.loopGen
            if (root.locateGen === gen)
                return // 本代已定位(多批行就绪的重复触发)
            // 行就绪(行 delegate onCompleted 触发 rowReady)后实测行距
            // 并定位:此时遍历访问行是安全的;公式定位不访问行。
            root.ensureRowStep()
            list.contentY = root.absRow * root.rowStep
            // 初始 contentY 可能恰为 0(0→0 不触发 onContentYChanged),
            // 显式初始化焦点行为几何居中行;行位置下一帧才稳定,再查一次。
            root.focusRowIdx = root.findCenterRowIndex()
            root.locateGen = gen // 标记本代定位完成,恢复行遍历访问
            locateTimer2.restart()
        }
        interval: 0
        repeat: false
    }
    Timer {
        id: locateTimer2
        onTriggered: {
            if (root.locateGen !== root.loopGen)
                return // 定位未完成/已被新重建覆盖
            root.focusRowIdx = root.findCenterRowIndex()
        }
        interval: 0
        repeat: false
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
            AppText {
                anchors.verticalCenter: parent.verticalCenter
                text: "未添加服务器，添加后即可浏览媒体库"
                color: Theme.textPrimary
                font.pixelSize: 13
            }
            Button {
                onClicked: root.openServerManager()
                text: "服务器管理"
            }
        }
    }

    Connections {
        target: AccountManager
        function onHomeRowsReady() {
            root.pendingRows = AccountManager.homeRows
            rowsTimer.restart()
        }
        // 账号变化(拖拽排序/删除)不再触发网络重拉:数据拉取由 C++ 统一
        // 决定(排序/删除本地重排,添加/重登成功才重拉)。UI 操作若触发
        // fetchHomeRows,会撞上重登中的 token 失效 → 401 → 连锁重登。
    }

    // 每行条目卡片(库海报或媒体条目)。尺寸由调用处指定(cardW/cardH),
    // 有图时底部显示标题,无图时居中显示占位文字。
    component RowCard: Rectangle {
        id: rowCard
        // delegate 用法下由 Repeater/ListView 注入;required 声明让 qmllint
        // 静态识别(复杂文件内 delegate 作用域注入不可靠)。
        required property var modelData
        required property int index
        property string cardImage: ""
        property string cardText: ""
        property bool isLibrary: false
        property bool selected: false
        property int cardW: Constants.rowCardW
        property int cardH: Constants.rowCardH
        property alias cardArea: cardArea
        width: cardW
        height: cardH
        color: Theme.surface
        radius: 14
        // 选中块高亮(accent 边框);悬停次之。MouseArea 无 hovered 属性
        // (hovered 属 PointerHandler 体系),自 Qt5 起即用 containsMouse
        // 表示悬停态(需 hoverEnabled)。
        border.width: selected ? 3 : (cardArea.containsMouse ? 2 : 0)
        border.color: Theme.accent
        // CrossfadeImage:圆角在绘制层裁切(Item::clip 只裁矩形)。
        CrossfadeImage {
            anchors.fill: parent
            anchors.leftMargin: 5
            anchors.rightMargin: 5
            anchors.topMargin: 5
            anchors.bottomMargin: 22
            cornerRadius: 14
            // 行卡内容切换瞬时替换,不触发替换动画。
            duration: 0
            source: rowCard.cardImage !== "" ? "image://emby/" + rowCard.cardImage : ""
            fillMode: Image.PreserveAspectCrop
            cache: true
            // 异步解码:大量海报同时加载时避免阻塞 UI 线程导致滚动卡顿。
            asynchronous: true
        }
        AppText {
            visible: rowCard.cardImage === ""
            anchors.centerIn: parent
            text: rowCard.cardText
            color: Theme.textPrimary
            font.pixelSize: rowCard.isLibrary ? 16 : 13
            font.bold: rowCard.isLibrary
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            width: parent.width - 8
            wrapMode: Text.Wrap
        }
        AppText {
            visible: rowCard.cardImage !== ""
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            anchors.bottomMargin: 3
            text: rowCard.cardText
            color: Theme.textPrimary
            font.pixelSize: rowCard.isLibrary ? 13 : 12
            font.bold: rowCard.isLibrary
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
        }
        MouseArea {
            id: cardArea
            // 按住拖动:累计位移超阈值触发行列滚动(拖动与点击共存——
            // 移动后 release 不触发 clicked,Qt 自动处理)。
            property real pressX: 0
            property real pressY: 0
            onPressed: function (mouse) {
                pressX = mouse.x
                pressY = mouse.y
            }
            onPositionChanged: function (mouse) {
                // 仅按住左键时算拖动:hoverEnabled 使悬停移动也触发
                // onPositionChanged,不检查按下会"没按住也滚动"。
                if (!(mouse.buttons & Qt.LeftButton))
                    return
                const dx = mouse.x - pressX
                const dy = mouse.y - pressY
                if (Math.abs(dx) < Constants.dragThresholdCard && Math.abs(dy) < Constants.dragThresholdCard)
                    return
                root.handleDrag(dx, dy)
                pressX = mouse.x
                pressY = mouse.y
            }
            anchors.fill: parent
            hoverEnabled: true
        }
    }

    // 鼠标按住拖动滚动(空白区域):与卡片内拖拽共用 handleDrag。
    // 声明在 ListView 之前(z 在下层),卡片区域的事件先被卡片 MouseArea
    // 接收,空白区(行间缝隙/顶部)穿透到这里。
    MouseArea {
        property real dragX: 0
        property real dragY: 0
        onPressed: function (mouse) {
            if (mouse.button === Qt.LeftButton) {
                dragX = mouse.x
                dragY = mouse.y
            }
        }
        onPositionChanged: function (mouse) {
            // 仅按住左键时算拖动;按钮状态检查兜底 release 丢失。
            if (!(mouse.buttons & Qt.LeftButton))
                return
            const dx = mouse.x - dragX
            const dy = mouse.y - dragY
            if (Math.abs(dx) < Constants.dragThresholdBlank && Math.abs(dy) < Constants.dragThresholdBlank)
                return
            root.handleDrag(dx, dy)
            dragX = mouse.x
            dragY = mouse.y
        }
        anchors.fill: parent
    }

    // 滚动时实时更新焦点行(选中块跟随居中的无缩放行)。
    ListView {
        id: list
        onContentYChanged: root.focusRowIdx = root.findCenterRowIndex()
        // delegate 池化:模型替换时尽量复用实例,减少销毁/孵化打断面。
        reuseItems: true
        anchors.fill: parent
        clip: true
        model: root.loopRows
        spacing: -Constants.rowOverlap
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
            // Repeater/ListView 注入;required 声明让 qmllint 静态识别。
            required property var modelData
            required property int index
            // 行数据快照:modelData 是委托上下文变量,不能作为对象属性
            // (rowDelegate.modelData)访问;存入显式属性供嵌套卡片取行级信息。
            property var rowData: modelData
            // 供 scrollRow 访问横向条目视图(只移动条目海报)。
            property alias rowItemsView: rowItems
            // 本行在 loopRows 中的索引,供选中块高亮判定。
            property int rowIndex: index
            // 就绪通知:实例化完成(布局可用)后由 root 定位(见 rowReady)。
            Component.onCompleted: root.rowReady()
            // 行中心到视口中心的距离(随滚动变化)驱动缩放与透明度。
            // 属性绑定只算一次,scale/opacity/z 三处复用(原各自调函数
            // 重复求值);魔数集中在 Constants。
            readonly property real centerDist: Math.abs((rowDelegate.y + rowDelegate.height / 2 - list.contentY) - list.height / 2)
            width: list.width
            // 显式行高(标题 24 + 卡片 172):行距 = 行高 - 重叠 = 常量,
            // root 侧行几何可公式计算,无需遍历 delegate(重建中遍历会
            // 触发引擎 "invalid context" 错误)。
            height: Constants.rowTitleH + Constants.rowHeight
            transformOrigin: Item.Top
            // 堆叠层级:距视口中心越近越靠前(离散三档,滚动动画中跨档
            // 才重排场景图,比逐帧浮点 z 便宜得多);中间行最前可点,
            // 上下行被相邻行覆盖。
            z: rowDelegate.centerDist < Constants.rowZNear ? 3
               : (rowDelegate.centerDist < Constants.rowZMid ? 2 : 1)
            // 滚动动画中实时过渡:行随距中心距离连续缩放/变暗。
            scale: Math.max(Constants.rowMinScale,
                            1 - Constants.rowScaleFactor * rowDelegate.centerDist
                                / Math.max(1, list.height / 2 - Constants.rowCenterBand))
            opacity: Math.max(Constants.rowMinOpacity,
                              1 - Constants.rowOpacityFactor * rowDelegate.centerDist
                                  / Math.max(1, list.height / 2 - Constants.rowCenterBand))

            // 行标题:服务器名 - 媒体库名(同一服务器多库时区分来源)。
            AppText {
                height: Constants.rowTitleH
                anchors.horizontalCenter: parent.horizontalCenter
                verticalAlignment: Text.AlignVCenter
                text: rowDelegate.modelData.serverName !== ""
                        ? rowDelegate.modelData.serverName + " - " + rowDelegate.modelData.viewName
                        : rowDelegate.modelData.viewName
                color: Theme.textPrimary
                font.pixelSize: 17
                font.bold: true
            }
            // 行内容:宽度为视口宽,条目多时右侧裁剪(拉取数量保证
            // 首屏尽量填满)。条目用横向 ListView 虚拟化,只实例化
            // 可见卡片,避免每行 1 张海报全部加载拖慢滚动。
            Item {
                width: list.width
                height: Constants.rowHeight
                clip: true
                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Constants.rowLeftMargin
                    spacing: Constants.rowSpacing
                    // 库海报(行首):焦点在库海报且本行为居中行时高亮。
                    // z 置顶:左拉动画(contentX 负)时条目卡可能短暂越出
                    // ListView 边界,保证库海报始终在条目海报上层。
                    RowCard {
                        z: 1
                        // 本行 delegate 的模型元素(required 属性须显式传入)。
                        modelData: rowDelegate.modelData
                        index: rowDelegate.index
                        cardImage: modelData.posterId || ""
                        cardText: modelData.viewName
                        isLibrary: true
                        cardW: Constants.rowLibraryW
                        cardH: Constants.rowHeight
                        selected: rowDelegate.rowIndex === root.focusRowIdx && root.focusCol === -1
                        cardArea.onClicked: root.openLibrary(modelData.viewId, modelData.serverUrl,
                                                             modelData.viewName)
                    }
                    // 该库最近条目:横向滚动列表,虚拟化渲染。
                    ListView {
                        id: rowItems
                        reuseItems: true
                        width: list.width - Constants.rowLeftMargin - Constants.rowLibraryW - Constants.rowSpacing
                        height: Constants.rowHeight
                        orientation: ListView.Horizontal
                        spacing: Constants.rowSpacing
                        // 裁剪到自身边界:拉动画/回滚时 contentX 会短暂越界,
                        // 不裁剪则条目卡会覆盖到左侧库海报上。
                        clip: true
                        // 纯展示:滚轮由外层竖向处理,避免嵌套滚动冲突。
                        interactive: false
                        model: rowDelegate.modelData.items
                        delegate: RowCard {
                            cardImage: modelData.posterId || ""
                            cardText: modelData.name
                            cardW: Constants.rowCardW
                            cardH: Constants.rowHeight
                            // 内层 modelData 是条目,行级 accountId 从 rowData 取。
                            // 选中块高亮:本行为居中行且列索引匹配。
                            selected: rowDelegate.rowIndex === root.focusRowIdx && index === root.focusCol
                            cardArea.onClicked: function () {
                                // 点击即选中该卡,并保持行焦点同步。
                                root.focusRowIdx = rowDelegate.rowIndex
                                root.focusCol = index
                                root.showDetail(modelData.id, modelData.posterId || "",
                                                modelData.name, rowDelegate.rowData.serverUrl)
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
        anchors.fill: parent
        acceptedButtons: Qt.NoButton // 不拦截点击,只接收滚轮
    }
}
