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

    function rebuildLoop() {
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

    // 平滑滚动动画对象:每次滚动新建(见 scrollBy)——QML 动画对象复用
    // 有状态残留导致 start() 偶发无效,新对象保证动画必然执行。
    property var scrollAnim: null

    // 循环滚动:绝对行索引推进,contentY = 绝对行位置。
    // 单步走动画(contentY 连续变化驱动行的缩放/透明实时过渡);
    // 回绕(超出可达范围/副本边界)时跳回与 absRow 同逻辑行的副本,
    // 逻辑位置连续。大步/回绕瞬间定位避免拖沓。
    function scrollBy(step) {
        const n = root.rows.length
        if (n === 0)
            return
        root.ensureRowStep()
        // 首次/模型重建后 contentY 可能停在 0(第一副本起点,定位未生效):
        // 中间副本及之后的滚动瞬间校正到对应行,避免首滚跳变。
        if (root.absRow >= n && list.contentY < n * root.rowStep)
            list.contentY = root.absRow * root.rowStep
        root.absRow += step
        const maxY = list.contentHeight - list.height
        // 回绕:先把 contentY 传送到"当前视觉行"的中间副本——逻辑行
        // 相同、内容一致,视觉无感(不可见传送);absRow 同步后再按
        // step 正常步进,dist 回到 1 行,回绕那格就是普通一格的
        // 平滑动画,不再瞬间跳。
        if (root.absRow * root.rowStep > maxY || root.absRow < 0) {
            let curAbs = Math.max(0, Math.floor(list.contentY / root.rowStep))
            let mid = curAbs
            if (curAbs >= 2 * n)
                mid = curAbs - n
            else if (curAbs < n)
                mid = curAbs + n
            root.absRow = mid
            list.contentY = mid * root.rowStep
            root.absRow += step
        }
        // 副本范围兜底 [0, 3n)。
        root.absRow = Math.max(0, Math.min(3 * n - 1, root.absRow))
        root.rowIndex = root.absRow % n
        const target = root.absRow * root.rowStep
        const dist = Math.abs(target - list.contentY)
        if (dist <= root.rowStep * 3 && dist > 0.5) {
            // 每次新建动画对象:QML 动画对象复用(先 stop 再 start)时有
            // 状态残留——已知行为是 start() 可能无效、属性停在旧值,后续
            // 距离累积到阈值外就瞬间跳;新对象保证 start 必然生效。
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
            // 时长按距离自适应(约 8 行/秒):滚动越快单步越远动画越快。
            root.scrollAnim.duration = Math.max(60, Math.min(200, dist / root.rowStep * 120))
            root.scrollAnim.start()
        } else {
            // 回绕/大步:先停动画再赋值,避免旧动画把 contentY 拉回。
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
        property int cardW: 112
        property int cardH: 168
        property alias cardArea: cardArea
        width: cardW
        height: cardH
        color: Theme.surface
        radius: 10
        border.width: cardArea.hovered ? 2 : 0
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
    ListView {
        id: list
        anchors.fill: parent
        clip: true
        model: root.loopRows
        spacing: -44
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
                    // 库海报(行首)
                    RowCard {
                        cardImage: modelData.posterId || ""
                        cardText: modelData.viewName
                        isLibrary: true
                        cardW: 124
                        cardH: 172
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
                        // 纯展示:滚轮由外层竖向处理,避免嵌套滚动冲突。
                        interactive: false
                        model: modelData.items
                        delegate: RowCard {
                            cardImage: modelData.posterId || ""
                            cardText: modelData.name
                            cardW: 112
                            cardH: 172
                            // 内层 modelData 是条目,行级 accountId 从 rowData 取。
                            cardArea.onClicked: root.ensureAccount(rowDelegate.rowData.accountId,
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

    // 滚轮无缝循环:每格按一个"可见行"滚动,回绕跳回同逻辑行
    // (视觉内容不变)。向上滚上移,向下滚下移。
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton // 不拦截点击,只接收滚轮
        onWheel: function (wheel) {
            // angleDelta.y 向上为正:向上滚(正)则逻辑行减,向下滚(负)则加。
            const delta = Math.round(wheel.angleDelta.y / 120)
            if (delta !== 0)
                root.scrollBy(-delta)
            wheel.accepted = true
        }
    }
}
