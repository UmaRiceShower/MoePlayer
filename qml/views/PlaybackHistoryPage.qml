pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import MoePlayer.Core

//! 播放历史页:按条目聚合的"最近播放"时间轴。
//! 数据来自本地播放历史(PlaybackHistory,详见该类注释),进入页面即渲染,
//! 不等待网络;点条目进详情页(多账号必须带结果所属服务器与账号)。
//! 结构遵循 Qt QML Coding Conventions:属性 → 信号 → 函数 → 子对象。
Item {
    id: root

    // ============================= 属性 =============================

    // 行模型:分组头与条目行交替(见 rebuildRows)。行字段:
    // header → {kind:"header", label, count};;item → {kind:"item", ...}
    property var rows: []
    // 条目行数(不含分组头),顶部条展示用。
    property int itemCount: 0

    readonly property int headerH: 36
    readonly property int rowH: 94
    readonly property int rowGap: 8
    readonly property int thumbW: 152
    readonly property int thumbH: 86
    readonly property int pageMargin: 24
    readonly property int topBarH: 44
    // 视图与聚合:直接读写 ConfigManager(持久化在 config.toml,可热重载)。
    readonly property string viewMode: ConfigManager.historyView
    readonly property bool aggregate: ConfigManager.historyAggregate
    // 网格:卡宽/卡高/行高与列数(列数变化才重建行,见 onColumnsChanged)。
    readonly property real cardW: Constants.gridCardW(Math.max(1, list.width),
                                                      Constants.cellMinW, Constants.cellMaxW)
    readonly property int cardH: Constants.gridCardH(root.cardW)
    readonly property int gridRowH: root.cardH + 12
    readonly property int columns: Math.max(1, Math.floor(
        Math.max(1, list.width) / Constants.gridCellW(Math.max(1, list.width),
                                                      Constants.cellMinW, Constants.cellMaxW)))

    // 宽度变化时立即捕获的锚点(见 onColumnsChanged):交给去抖后的重建使用。
    property var pendingAnchor: null

    // 账号过滤:空 = 全部。页面级状态(不持久化)。
    property string filterAccountId: ""
    // chip 选项:按账号出现顺序,跳过凭据失效的账号。
    readonly property var accountOptions: {
        const list = AccountManager.accounts
        const out = []
        for (let i = 0; i < list.length; ++i) {
            if (list[i].authStatus === "invalid")
                continue
            out.push({ id: list[i].id, name: list[i].name })
        }
        return out
    }
    // 账号筛选标签:当前账号名;未过滤(或该账号已删除)显示"全部"。
    readonly property string filterLabel: {
        const opts = root.accountOptions
        for (let i = 0; i < opts.length; ++i) {
            if (opts[i].id === root.filterAccountId)
                return opts[i].name
        }
        return "全部"
    }

    // ============================= 信号 =============================

    signal showDetail(string itemId, string posterId, string title, string serverUrl, string accountId)

    // ============================= 函数 =============================

    // 时间桶:0=今天 1=昨天 2=本周(近 7 天) 3=更早。无时间戳(0)归"更早":
    // 列表端点不返回上次播放时间,未补明细的条目只有服务器给的顺序。
    function dayBucket(ts) {
        const now = new Date()
        const startToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
        if (ts >= startToday)
            return 0
        if (ts >= startToday - 86400000)
            return 1
        if (ts >= startToday - 6 * 86400000)
            return 2
        return 3
    }
    function bucketLabel(b) {
        return ["今天", "昨天", "本周", "更早"][b]
    }
    function timeText(ts, bucket) {
        if (ts <= 0)
            return ""
        const d = new Date(ts)
        if (bucket <= 1)
            return Qt.formatDateTime(d, "HH:mm")
        if (bucket === 2)
            return Qt.formatDateTime(d, "M/d HH:mm")
        return Qt.formatDateTime(d, "yyyy/M/d")
    }
    function pad2(n) {
        return ("0" + n).slice(-2)
    }
    // 主标题:分集显示"剧名 · SxxExx",影片显示片名(详情页加载期也用它)。
    function itemTitle(it) {
        if (it.type === "Episode" && (it.seriesName || "") !== "")
            return it.seriesName + " · S" + pad2(it.seasonNo || 0) + "E" + pad2(it.episodeNo || 0)
        return it.name || ""
    }
    // 副标题:分集显示集名,影片显示年份。
    function itemSub(it) {
        if (it.type === "Episode")
            return it.name || ""
        return (it.year || 0) > 0 ? String(it.year) : ""
    }
    function accountName(it) {
        const list = AccountManager.accounts
        for (let i = 0; i < list.length; ++i)
            if (list[i].id === it.accountId)
                return list[i].name
        return ""
    }
    // 条目是否命中搜索(查询为空即全命中)。匹配对象 = 剧名 + 集名 + 账号名 +
    // "SxxExx" 记号 + 年份,并附拼音(全拼/首字母简拼)—— 汉字、拼音、数字记号都能搜;
    // 大小写不敏感,填账号名即可按服务器筛。
    function itemHaystack(it) {
        let h = (it.seriesName || "") + " " + (it.name || "") + " " + root.accountName(it)
        if ((it.seasonNo || 0) > 0)
            h += " S" + root.pad2(it.seasonNo || 0) + "E" + root.pad2(it.episodeNo || 0)
        if ((it.year || 0) > 0)
            h += " " + it.year
        return h
    }
    function matchesQuery(it) {
        return FuzzyMatch.hit(searchField.text, root.itemHaystack(it))
    }
    // 账号下拉行:"" = 全部;无查询保持账号顺序,有查询按匹配分降序。
    function accountRows(query) {
        const q = (query || "").trim()
        const out = []
        if (q === "" || FuzzyMatch.hit(q, "全部"))
            out.push({ id: "", name: "全部" })
        const opts = root.accountOptions
        const hits = []
        for (let i = 0; i < opts.length; ++i) {
            if (!FuzzyMatch.hit(q, opts[i].name))
                continue
            // 排序仍按原文模糊分:拼音命中但原文不中的并列在 0(列表本身很短)。
            hits.push({ id: opts[i].id, name: opts[i].name, score: Math.max(0, FuzzyMatch.score(q, opts[i].name)) })
        }
        if (q !== "")
            hits.sort((a, b) => b.score - a.score)
        return out.concat(hits)
    }
    // 选中账号(空 = 全部)并收起下拉。
    function selectAccount(id) {
        root.filterAccountId = id
        accountPopup.close()
    }

    // 缩略图:行内是 16:9 框,优先取 16:9 图源 —— backdropId 对分集是父剧背景、
    // 对影片是自身背景;两者都没有时回退自身 posterId(2:3 海报会裁切)。
    function thumbSource(it) {
        const key = (it.backdropId || "") !== "" ? it.backdropId : (it.posterId || "")
        return key === "" ? "" : "image://emby/" + key
    }
    // 网格卡的图键:**裸键**(PosterCard 内部自行拼 image://emby/,与 Home/Library
    // 一致;传整 URL 会拼成 image://emby/image://emby/… 报"图片地址无效")。
    // 剧集海报(2:3,分集实测响应均带)→ 自身海报(影片即 2:3)→ 16:9 背景(裁切)。
    function cardKey(it) {
        return (it.seriesPosterId || "") !== "" ? it.seriesPosterId
             : ((it.posterId || "") !== "" ? it.posterId : (it.backdropId || ""))
    }
    function statusText(it) {
        if (it.played)
            return "已看完"
        if (it.positionTicks > 0 && it.runtimeTicks > 0)
            return Math.round(100 * it.positionTicks / it.runtimeTicks) + "%"
        return ""
    }
    function progressRatio(it) {
        if (it.positionTicks <= 0 || it.runtimeTicks <= 0 || it.played)
            return 0
        return Math.min(1, it.positionTicks / it.runtimeTicks)
    }
    // 进页面刷新:列表(全账号,内部有在途保护)+ 每账号继续观看列表;结果经
    // PlaybackHistory::historyChanged 回来,去抖后重建(见 rebuildTimer)。
    function refresh() {
        AccountManager.refreshPlaybackHistory()
        const list = AccountManager.accounts
        for (let i = 0; i < list.length; ++i) {
            if (list[i].authStatus === "invalid")
                continue
            if (AccountManager.credsForAccount(list[i].id).token === "")
                continue
            AccountManager.refreshAccountHistory(list[i].id)
        }
    }
    // 滚动锚点:首个可见条目行的行键与相对偏移(重建前记、重建后恢复)。
    function currentAnchor() {
        const y = list.contentY
        for (let i = Math.max(0, list.indexAt(0, y)); i < list.count; ++i) {
            const it = list.itemAtIndex(i)
            if (!it || !it.modelData || it.modelData.kind === "header")
                continue
            if (it.y + it.height > y)
                return { key: it.modelData.key, delta: y - it.y }
        }
        return null
    }
    function restoreAnchor(anchor) {
        if (!anchor)
            return
        // 用户正在滚动时不抢视口:分页在底部追加行不会移动已有行,不需要回位。
        if (list.moving || list.flicking)
            return
        for (let i = 0; i < root.rows.length; ++i) {
            const r = root.rows[i]
            if (r.kind === "header")
                continue
            // 网格行按"行内含该条目"命中:列数变化会重新分桶,行首键不再对齐。
            const hit = r.kind === "cards" ? r.items.some(c => c.key === anchor.key)
                                           : (r.key === anchor.key)
            if (!hit)
                continue
            list.positionViewAtIndex(i, ListView.Beginning)
            list.contentY = Math.max(0, list.contentY + anchor.delta)
            return
        }
    }
    // 聚合:分集按(账号 + 剧 id)合并,取最近一条为代表(输入本身按时间倒序);
    // 影片与无剧 id 的条目各自独立。同一剧在两个库各有一份时天然合并为一。
    function aggregateItems(items) {
        const out = []
        const seen = {}
        for (const it of items) {
            const sid = it.seriesId || ""
            if (it.type !== "Episode" || sid === "") {
                out.push(it)
                continue
            }
            const k = (it.accountId || "") + "|" + sid
            if (seen[k])
                continue
            seen[k] = true
            const copy = Object.assign({}, it)
            copy.aggregated = true
            out.push(copy)
        }
        return out
    }
    // 时间轴行记录。
    function timelineRecord(it, b) {
        return {
            kind: "item",
            key: it.scope + "|" + it.id,
            itemId: it.id || "",
            posterId: it.posterId || "",
            serverUrl: it.serverUrl || "",
            accountId: it.accountId || "",
            title: root.itemTitle(it),
            sub: root.itemSub(it),
            account: root.accountName(it),
            time: root.timeText(it.lastPlayedAt || 0, b),
            status: root.statusText(it),
            progress: root.progressRatio(it),
            thumb: root.thumbSource(it)
        }
    }
    // 网格卡记录:聚合行为剧集(点击进剧集详情,标题「剧名 · SxxExx」),
    // 其余为条目自身(点击进条目详情)。
    function cardRecord(it) {
        const agg = it.aggregated === true && (it.seriesId || "") !== ""
        return {
            key: (it.scope || "") + "|" + (it.id || ""),
            itemId: agg ? it.seriesId : (it.id || ""),
            posterId: root.cardKey(it),
            title: agg ? ((it.seriesName || it.name || "")
                          + ((it.seasonNo || 0) > 0
                             ? " · S" + root.pad2(it.seasonNo || 0) + "E" + root.pad2(it.episodeNo || 0)
                             : ""))
                        : root.itemTitle(it),
            year: it.year || 0,
            rating: it.rating || 0,
            played: it.played === true,
            favorite: it.favorite === true,
            positionTicks: it.positionTicks || 0,
            runtimeTicks: it.runtimeTicks || 0,
            unplayedCount: it.unplayedCount || 0,
            itemType: it.type || "",
            serverUrl: it.serverUrl || "",
            accountId: it.accountId || ""
        }
    }
    // 重建行模型:allItems() 已按(上次播放时间倒序, 服务器顺序)排好,
    // 故同桶条目连续,扫一遍即可分组;重建前记锚点、重建后恢复滚动位置。
    // keepPosition=false:条目集合整体变化(如切换账号过滤),不沿用锚点、由调用方回顶。
    // anchorOverride:调用方在几何变化前已捕获的锚点(见 onColumnsChanged)。
    function rebuildRows(keepPosition, anchorOverride) {
        const anchor = (anchorOverride !== undefined && anchorOverride !== null)
                       ? anchorOverride
                       : (keepPosition ? root.currentAnchor() : null)
        const out = []
        let bucket = -1
        let header = null
        const source = []
        for (const it of PlaybackHistory.allItems()) {
            if (root.filterAccountId !== "" && (it.accountId || "") !== root.filterAccountId)
                continue
            if (!root.matchesQuery(it))
                continue
            source.push(it)
        }
        const items = root.aggregate ? root.aggregateItems(source) : source
        let chunk = null
        for (const it of items) {
            const b = root.dayBucket(it.lastPlayedAt || 0)
            if (b !== bucket) {
                bucket = b
                chunk = null
                header = { kind: "header", label: root.bucketLabel(b), count: 0, key: "h" + b }
                out.push(header)
            }
            ++header.count
            if (root.viewMode === "grid") {
                if (!chunk || chunk.items.length >= root.columns) {
                    chunk = { kind: "cards", key: "", items: [] }
                    out.push(chunk)
                }
                if (chunk.key === "")
                    chunk.key = it.scope + "|" + it.id
                chunk.items.push(root.cardRecord(it))
            } else {
                out.push(root.timelineRecord(it, b))
            }
        }
        root.rows = out
        root.itemCount = items.length
        Qt.callLater(() => root.restoreAnchor(anchor))
    }

    // 账号过滤变化:条目集合整体变化,重建并回到列表顶部(不沿用锚点)。
    onFilterAccountIdChanged: {
        root.rebuildRows(false)
        list.positionViewAtBeginning()
    }

    Component.onCompleted: {
        root.rebuildRows(false)
        root.refresh()
    }

    // 后台明细合并会连续触发 historyChanged:去抖后重建,重建时按锚点恢复滚动位置
    // (避免"刷新一次跳一次")。
    Connections {
        target: PlaybackHistory
        function onHistoryChanged() {
            rebuildTimer.restart()
        }
    }

    // 账号增删后 chip 选项变化:重建一次(过滤账号被删则回到"全部")。
    Connections {
        target: AccountManager
        function onAccountsChanged() {
            if (root.filterAccountId !== "" && !root.accountOptions.some(a => a.id === root.filterAccountId))
                root.filterAccountId = ""
            rebuildTimer.restart()
        }
    }
    Timer {
        id: rebuildTimer
        interval: 800
        onTriggered: root.rebuildRows(true)
    }
    // 视图/聚合切换:条目集合与布局整体变化,重建并回顶。
    Connections {
        target: ConfigManager
        function onHistoryViewChanged() {
            root.rebuildRows(false)
            list.positionViewAtBeginning()
        }
        function onHistoryAggregateChanged() {
            root.rebuildRows(false)
            list.positionViewAtBeginning()
        }
    }
    // 窗口宽变化 → 算出的列数变化才重建(仅网格;时间轴与宽度无关)。
    // 锚点在宽度变化的当下立即捕获(onWidthChanged):此时 delegate 还是旧布局,
    // 而宽度变化会先改卡宽/行高,ListView 保持像素 contentY 重排 ⇒ 视口逻辑位置在
    // 去抖期间就漂移了,重建时再取会记下漂移后的位置。
    onWidthChanged: {
        if (root.viewMode !== "grid")
            return
        root.pendingAnchor = root.currentAnchor()
    }
    onColumnsChanged: {
        if (root.viewMode === "grid")
            columnTimer.restart()
    }
    Timer {
        id: columnTimer
        interval: 150
        onTriggered: {
            const a = root.pendingAnchor
            root.pendingAnchor = null
            root.rebuildRows(true, a)
        }
    }


    // ============================= 子对象 =============================

    // ---- 顶部条:标题 + 条数(左)、账号筛选与视图/聚合(右)----
    // 无底色与描边:直接浮在页面背景上,控件自带视觉边界。
    Item {
        id: topBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: root.pageMargin
        height: root.topBarH

        Row {
            id: titleRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            AppText {
                text: "♥"
                color: Constants.moePink
                font.pixelSize: 18
            }
            AppText {
                text: "播放历史"
                color: "white"
                font.pixelSize: 17
                font.bold: true
            }
            AppText {
                anchors.verticalCenter: parent.verticalCenter
                text: "· " + root.itemCount + " 条"
                color: Theme.textMuted
                font.pixelSize: 12
            }
        }

        // 搜索框:模糊匹配剧名/集名/账号/SxxExx,本地即时过滤;宽度取标题与右侧
        // 控件之间的空档(窄窗下不小于 0,避免负宽度)。
        TextField {
            id: searchField
            anchors.left: titleRow.right
            anchors.leftMargin: 20
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, controlRow.x - titleRow.x - titleRow.width - 40)
            height: 28
            leftPadding: 30
            rightPadding: 26
            placeholderText: "搜索剧名 / 集名 / 账号"
            placeholderTextColor: Theme.textMuted
            color: "white"
            font.pixelSize: 13
            selectByMouse: true
            // 与右侧控件同一视觉语言:半透明底 + 细边,聚焦时细边转粉。
            background: Rectangle {
                radius: height / 2
                color: Qt.rgba(0.07, 0.08, 0.11, 0.45)
                border.width: 1
                border.color: searchField.activeFocus
                              ? Qt.rgba(Constants.moePink.r, Constants.moePink.g, Constants.moePink.b, 0.55)
                              : Qt.rgba(1, 1, 1, 0.10)
            }
            AppText {
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: "♥"
                color: searchField.activeFocus ? Constants.moePink : Theme.textMuted
                font.pixelSize: 13
            }
            // 清除:有内容时可点;Esc 同样清除(焦点在框内时)。
            AppText {
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: "✕"
                visible: searchField.text !== ""
                color: clearHover.hovered ? "white" : Theme.textMuted
                font.pixelSize: 12
                HoverHandler {
                    id: clearHover
                    cursorShape: Qt.PointingHandCursor
                }
                TapHandler {
                    onTapped: searchField.text = ""
                }
            }
            // 本地数据,直接过滤不防抖;过滤后回到列表顶部(与切账号一致)。
            onTextChanged: {
                root.rebuildRows(false)
                list.positionViewAtBeginning()
            }
            Keys.onEscapePressed: searchField.text = ""
        }

        // 右侧控件(自左向右):账号筛选 → 视图 → 聚合。
        Row {
            id: controlRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            // 账号筛选:单账号过滤,下拉列出账号(与全局搜索的目标选择同一交互约定)。
            PillTrigger {
                id: accountChip
                label: "账号 · " + root.filterLabel
                active: root.filterAccountId !== ""
                onClicked: accountPopup.open()

                Popup {
                    id: accountPopup
                    parent: accountChip
                    y: accountChip.height + 4
                    x: -width + accountChip.width
                    width: 240
                    padding: 8
                    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                    Timer {
                        id: accountFocusTimer
                        interval: 60
                        onTriggered: accountSearch.forceActiveFocus()
                    }
                    enter: Transition {
                        NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 120 }
                    }
                    exit: Transition {
                        NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 120 }
                    }
                    onOpened: {
                        accountSearch.text = ""
                        // 延时取焦:等 popup 完成打开处理后再把焦点交给输入框。
                        accountFocusTimer.start()
                    }
                    background: Rectangle {
                        color: Qt.rgba(0.10, 0.11, 0.14, 0.78)
                        radius: 8
                        border.width: 1
                        border.color: Qt.rgba(Constants.moePink.r, Constants.moePink.g, Constants.moePink.b, 0.45)
                    }
                    contentItem: Column {
                        width: parent.width - 16
                        spacing: 6
                        // 账号搜索:本地模糊匹配,账号多时不必在长列表里翻。
                        TextField {
                            id: accountSearch
                            width: parent.width
                            height: 30
                            // 打开下拉即取焦(见 accountFocusTimer),可直接输入过滤。
                            focus: true
                            leftPadding: 10
                            rightPadding: 10
                            placeholderText: "搜索账号"
                            placeholderTextColor: Theme.textMuted
                            color: "white"
                            font.pixelSize: 13
                            selectByMouse: true
                            background: Rectangle {
                                radius: 6
                                color: Qt.rgba(0, 0, 0, 0.25)
                                border.width: 1
                                border.color: accountSearch.activeFocus
                                              ? Qt.rgba(Constants.moePink.r, Constants.moePink.g, Constants.moePink.b, 0.55)
                                              : Qt.rgba(1, 1, 1, 0.10)
                            }
                            // Esc 关下拉(焦点在输入框,按键由这里收口)。
                            Keys.onEscapePressed: accountPopup.close()
                            // 回车 = 选中首个匹配项(与点击首行等价)。
                            onAccepted: {
                                const rows = accountList.model
                                if (rows && rows.length > 0)
                                    root.selectAccount(rows[0].id)
                            }
                        }
                        // 行:"" = 全部,其余为单账号;列表高度按内容自适应、超出滚动。
                        ListView {
                            id: accountList
                            width: parent.width
                            height: Math.min(contentHeight, 252)
                            clip: true
                            model: root.accountRows(accountSearch.text)
                            delegate: ItemDelegate {
                                required property var modelData
                                readonly property bool isOn: root.filterAccountId === modelData.id
                                width: accountList.width
                                height: 30
                                padding: 0
                                contentItem: Item {
                                    AppText {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 4
                                        anchors.right: parent.right
                                        anchors.rightMargin: 16
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.name
                                        color: "white"
                                        font.pixelSize: 13
                                        elide: Text.ElideRight
                                    }
                                    Rectangle {
                                        anchors.right: parent.right
                                        anchors.rightMargin: 4
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 6
                                        height: 6
                                        radius: 3
                                        color: Constants.moePink
                                        visible: parent.parent.isOn
                                    }
                                }
                                background: Rectangle {
                                    radius: 4
                                    color: parent.hovered
                                        ? Qt.rgba(Constants.moePink.r, Constants.moePink.g, Constants.moePink.b, 0.18)
                                        : "transparent"
                                }
                                onClicked: root.selectAccount(modelData.id)
                            }
                        }
                    }
                }
            }

            // 视图:时间轴 / 网格(取值持久化在 config.toml,可热重载)
            SegmentedControl {
                options: [{ value: "timeline", label: "时间轴" }, { value: "grid", label: "网格" }]
                currentValue: root.viewMode
                onActivated: (value) => ConfigManager.historyView = value
            }

            // 聚合:逐条 / 按剧聚合
            SegmentedControl {
                options: [{ value: false, label: "逐条" }, { value: true, label: "聚合" }]
                currentValue: root.aggregate
                onActivated: (value) => ConfigManager.historyAggregate = value
            }
        }
    }

    // ---- 主体:分组时间轴(单容器虚拟化,行内自带分组头)----
    ListView {
        id: list
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: topBar.bottom
        anchors.bottom: parent.bottom
        anchors.margins: root.pageMargin
        anchors.topMargin: 12
        clip: true
        reuseItems: true
        cacheBuffer: 800
        model: root.rows
        spacing: 0

        delegate: Item {
            id: rowItem
            required property var modelData
            required property int index
            width: list.width
            height: modelData.kind === "header" ? root.headerH
                  : (modelData.kind === "cards" ? root.gridRowH : root.rowH + root.rowGap)

            // 分组头:今天 / 昨天 / 本周 / 更早 + 条数
            Item {
                anchors.fill: parent
                visible: rowItem.modelData.kind === "header"
                Row {
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 6
                    spacing: 8
                    AppText {
                        text: rowItem.modelData.label || ""
                        color: Constants.moePink
                        font.pixelSize: 14
                        font.bold: true
                    }
                    AppText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: (rowItem.modelData.count || 0) + " 条"
                        color: Theme.textMuted
                        font.pixelSize: 12
                    }
                }
            }

            // 网格行:一行 N 张卡(列数随窗口宽变化,见 columns)
            Row {
                anchors.left: parent.left
                anchors.top: parent.top
                spacing: Constants.cellGap
                visible: rowItem.modelData.kind === "cards"
                Repeater {
                    model: rowItem.modelData.kind === "cards" ? rowItem.modelData.items : []
                    delegate: PosterCard {
                        required property var modelData
                        width: root.cardW
                        height: root.cardH
                        z: hovered ? 2 : 0
                        showActions: false
                        itemId: modelData.itemId
                        posterId: modelData.posterId
                        title: modelData.title
                        year: modelData.year
                        rating: modelData.rating
                        played: modelData.played
                        favorite: modelData.favorite
                        positionTicks: modelData.positionTicks
                        runtimeTicks: modelData.runtimeTicks
                        unplayedCount: modelData.unplayedCount
                        itemType: modelData.itemType
                        onClicked: root.showDetail(modelData.itemId, modelData.posterId,
                                                   modelData.title, modelData.serverUrl,
                                                   modelData.accountId)
                    }
                }
            }

            // 条目行
            Rectangle {
                id: card
                width: parent.width
                height: root.rowH
                visible: rowItem.modelData.kind === "item"
                radius: 14
                color: rowHover.hovered ? Qt.rgba(0.16, 0.10, 0.14, 0.85)
                                        : Qt.rgba(0.08, 0.09, 0.12, 0.62)
                border.width: rowHover.hovered ? 1 : 0
                border.color: Qt.rgba(Constants.moePink.r, Constants.moePink.g, Constants.moePink.b, 0.45)
                Behavior on color { ColorAnimation { duration: 120 } }

                // 16:9 缩略图(无图时露出深色底 + 播放三角)
                Rectangle {
                    id: thumbBox
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.thumbW
                    height: root.thumbH
                    radius: 10
                    color: Theme.bg
                    clip: true
                    CrossfadeImage {
                        id: thumb
                        anchors.fill: parent
                        cornerRadius: 10
                        source: rowItem.modelData.thumb || ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        duration: 400
                        cache: true
                    }
                    Canvas {
                        anchors.centerIn: parent
                        width: 26
                        height: 26
                        property color iconColor: Theme.textMuted
                        onIconColorChanged: requestPaint()
                        visible: (rowItem.modelData.thumb || "") === "" || thumb.status === Image.Error
                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            ctx.fillStyle = iconColor
                            ctx.beginPath()
                            ctx.moveTo(8, 5)
                            ctx.lineTo(22, 14)
                            ctx.lineTo(8, 23)
                            ctx.closePath()
                            ctx.fill()
                        }
                    }
                }

                // 文本区:主标题 + 副标题 + 进度条
                Item {
                    id: textArea
                    anchors.left: thumbBox.right
                    anchors.leftMargin: 14
                    anchors.right: meta.left
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    height: titleText.implicitHeight + 6 + subText.implicitHeight + 10 + 4

                    AppText {
                        id: titleText
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        text: rowItem.modelData.title || ""
                        color: "white"
                        font.pixelSize: 15
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    AppText {
                        id: subText
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: titleText.bottom
                        anchors.topMargin: 6
                        text: rowItem.modelData.sub || ""
                        color: Theme.textMuted
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }
                    // 观看进度:未看完才显示(已看完由右侧状态文字表达)。
                    Item {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: subText.bottom
                        anchors.topMargin: 10
                        height: 4
                        visible: (rowItem.modelData.progress || 0) > 0
                        Rectangle {
                            anchors.fill: parent
                            radius: 2
                            color: Qt.rgba(0, 0, 0, 0.45)
                        }
                        Rectangle {
                            width: parent.width * (rowItem.modelData.progress || 0)
                            height: parent.height
                            radius: 2
                            color: Constants.moePink
                        }
                    }
                }

                // 右侧:时间 / 状态 / 账号
                Column {
                    id: meta
                    anchors.right: parent.right
                    anchors.rightMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    width: Math.max(timeText.implicitWidth, accountText.implicitWidth, statusText.implicitWidth)
                    AppText {
                        id: timeText
                        anchors.right: parent.right
                        text: rowItem.modelData.time || ""
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                    AppText {
                        id: statusText
                        anchors.right: parent.right
                        text: rowItem.modelData.status || ""
                        color: rowItem.modelData.status === "已看完" ? Theme.success : Constants.moePinkText
                        font.pixelSize: 12
                        visible: (rowItem.modelData.status || "") !== ""
                    }
                    AppText {
                        id: accountText
                        anchors.right: parent.right
                        text: rowItem.modelData.account || ""
                        color: Theme.textMuted
                        font.pixelSize: 11
                        visible: (rowItem.modelData.account || "") !== ""
                    }
                }

                HoverHandler {
                    id: rowHover
                    cursorShape: Qt.PointingHandCursor
                }
                // 点击进详情(默认手势策略:按下不抢占,拖动滚动时不会误判成点击)。
                TapHandler {
                    onTapped: root.showDetail(rowItem.modelData.itemId, rowItem.modelData.posterId,
                                              rowItem.modelData.title, rowItem.modelData.serverUrl,
                                              rowItem.modelData.accountId)
                }
            }
        }
    }

    // ---- 空态 ----
    Column {
        anchors.centerIn: parent
        spacing: 8
        visible: root.rows.length === 0
        AppText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "还没有播放记录"
            color: "white"
            font.pixelSize: 16
        }
        AppText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: searchField.text !== ""
                  ? "没有匹配的记录"
                  : (root.filterAccountId !== ""
                     ? "该账号还没有播放记录"
                     : (AccountManager.accounts.length === 0
                        ? "先在「服务器管理」里添加 Emby 服务器"
                        : "播放过的条目会出现在这里"))
            color: Theme.textMuted
            font.pixelSize: 12
        }
    }

    // 下拉触发器:与右侧分段控件同一视觉语言 —— 同高(28)、同半透明底、同细边;
    // 选中(有筛选)时用粉色细边标示,不填充实心色。点击开下拉,故不共用 FilterChip
    // (后者是"开关/筛选"语义,且在 Library 与 SearchOverlay 共享)。
    component PillTrigger: Button {
        id: trigger
        property string label: ""
        property bool active: false

        height: 28
        topPadding: 0
        bottomPadding: 0
        leftPadding: 14
        rightPadding: 14
        background: Rectangle {
            radius: height / 2
            color: Qt.rgba(0.07, 0.08, 0.11, 0.45)
            border.width: 1
            border.color: trigger.active
                          ? Qt.rgba(Constants.moePink.r, Constants.moePink.g, Constants.moePink.b, 0.55)
                          : (trigger.hovered ? Qt.rgba(1, 1, 1, 0.22) : Qt.rgba(1, 1, 1, 0.10))
        }
        contentItem: AppText {
            text: trigger.label
            color: trigger.active ? Constants.moePinkText : "white"
            font.pixelSize: 13
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }
}
