pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import MoePlayer.Core

//! 全局搜索浮层(Ctrl+K 开关):按最近浏览的服务器搜索(主窗口注入 serverUrl),
//! 服务端搜索跨库递归(影片/剧集/单集),输入 300ms 防抖后请求。
//! 过滤区(类型/年份/已看状态)全部走服务端查询参数,客户端零过滤。
//! 分页:请求 Limit+1 探针,多出的 1 条由 C++ 截断并置 model.hasMore,
//! 滚动到底自动加载下一页。结果网格点击进详情;Esc / 点击背景关闭。
Item {
    id: root

    // 搜索目标服务器(serverUrl 数组;空 = 全部)。用户显式选择,不依赖页面
    // 上下文;与"全部"互斥由 UI 层保证(点全部清空选择,勾选取消全部)。
    property var selectedServers: []
    // 服务器可选项(按账号出现顺序去重,跳过失效账号):[{serverUrl, name},...]。
    readonly property var serverOptions: {
        const list = AccountManager.accounts
        const seen = []
        let out = []
        for (let i = 0; i < list.length; ++i) {
            const a = list[i]
            if (a.authStatus === "invalid")
                continue
            if (seen.indexOf(a.serverUrl) >= 0)
                continue
            seen.push(a.serverUrl)
            out.push({ serverUrl: a.serverUrl, name: a.name })
        }
        return out
    }
    // 目标账号集:selectedServers 空 = 全部可用账号;否则所选服务器的全部
    // 可用账号。同服务器多账号各一条——库权限/已看状态按用户上下文隔离,
    // 不可合并(官方 UserPolicy)。
    readonly property var aggTargets: {
        const list = AccountManager.accounts
        const out = []
        for (let i = 0; i < list.length; ++i) {
            const a = list[i]
            if (a.authStatus === "invalid")
                continue
            if (root.selectedServers.length > 0 && root.selectedServers.indexOf(a.serverUrl) < 0)
                continue
            const c = AccountManager.credsForAccount(a.id)
            if (c.token === "")
                continue
            out.push({ serverUrl: a.serverUrl, accountId: a.id, name: a.name,
                       userName: a.userName, token: c.token, userId: c.userId })
        }
        return out
    }
    // 目标 chip 摘要:全部 / 服务器名 / N 台。
    readonly property string targetLabel: {
        if (root.selectedServers.length === 0)
            return "全部"
        if (root.selectedServers.length === 1) {
            const opts = root.serverOptions
            for (let i = 0; i < opts.length; ++i)
                if (opts[i].serverUrl === root.selectedServers[0])
                    return opts[i].name
        }
        return root.selectedServers.length + " 台"
    }
    // 在途账号数(>0 显示"搜索中",归零 = 全部返回)。
    property int pendingAccounts: 0
    readonly property bool canSearch: root.aggTargets.length > 0
    readonly property int searchFilterCount: (root.yearFrom > 0 || root.yearTo > 0 ? 1 : 0) + root.activeFilters.length

    // ---- 过滤状态(直接映射 API 查询参数) ----
    // 类型多选(IncludeItemTypes):Movie/Series/Episode/Season/Video/BoxSet;
    // 默认电影+剧集;空数组 = 不传(服务器返回全部类型)。
    property var activeTypes: ["Movie", "Series"]
    // 年份范围(Years):0=不限;仅一端 = 精确单年;两端(起<=止)=
    // 区间展开为逗号年份列表(服务器不支持范围语法,实测 500)。
    property int yearFrom: 0
    property int yearTo: 0
    // 状态过滤(Filters,多选):已看/未看/收藏 的 "IsPlayed" 等值数组。
    property var activeFilters: []
    // 分页游标:下一页 StartIndex;0 表示替换结果。
    property int startIndex: 0
    // 首屏/过滤重搜进行中(状态行显示"搜索中")。
    property bool searching: false
    // 分页加载中(防并发翻页)。
    property bool loadingMore: false

    // 选中 chip 底色:accent 降饱和加深(H192° 100% → 35% 饱和)。
    // chip 选中是实心大面积背景,直接套 accent 太艳;边框/进度条等
    // 小面积场景仍用 Theme.accent。
    readonly property color chipActive: Qt.hsla(Theme.accent.hslHue, 0.35, 0.30, 1.0)
    // 选中 chip 悬停:同色相提亮一档。
    readonly property color chipActiveHover: Qt.hsla(Theme.accent.hslHue, 0.35, 0.38, 1.0)

    // 点击结果进详情(携带所在服务器)。
    signal showDetail(string itemId, string posterId, string title, string serverUrl, string accountId)

    // 需要模糊的背景内容(主窗口传入 StackView,避免把浮层自身也模糊)。
    property Item backgroundSource: null

    // 结果网格自适应卡宽(与 Library 同款):卡宽在 [cellMinW, cellMaxW]
    // 伸缩填满整行;cell = 卡 + gap,卡在 cell 内居中,gap/2(12px)即
    // hover 放大余量(1.06 溢出 <10.4px),首行顶/末行底/左右列不被裁。
    readonly property real cardW: Constants.gridCardW(Math.max(1, gridContainer.width), Constants.searchCellMinW, Constants.searchCellMaxW)
    readonly property int cardH: Constants.gridCardH(root.cardW)
    readonly property real cellW: Constants.gridCellW(Math.max(1, gridContainer.width), Constants.searchCellMinW, Constants.searchCellMaxW)
    readonly property int cellH: Constants.gridCellH(root.cardW)

    // 类型多选 → 逗号拼接的 IncludeItemTypes 参数(空 = 不传)。
    function typesParam() {
        return root.activeTypes.join(",")
    }

    // 年份范围 → Years 参数:两端 = 区间展开为逗号列表(起>止时取起端
    // 单值);仅一端 = 精确单年;都空 = 不传。
    function yearsParam() {
        if (root.yearFrom > 0 && root.yearTo > 0) {
            if (root.yearFrom <= root.yearTo) {
                let out = []
                for (let y = root.yearFrom; y <= root.yearTo; ++y)
                    out.push(String(y))
                return out.join(",")
            }
            return String(root.yearFrom)
        }
        if (root.yearFrom > 0)
            return String(root.yearFrom)
        if (root.yearTo > 0)
            return String(root.yearTo)
        return ""
    }

    // 状态过滤 → 逗号拼接的 Filters 参数。
    function filtersParam() {
        let out = []
        for (let i = 0; i < root.activeFilters.length; ++i)
            out.push(root.activeFilters[i])
        return out.join(",")
    }

    // 按当前过滤状态发起一次搜索:每账号一次请求(上限
    // ConfigManager.searchLimitPerAccount,不分页);全部在途返回后
    // searching=false(失败也发空结果,计数不悬)。
    function searchNow() {
        if (!root.canSearch)
            return
        root.searching = true
        console.info("Search: 发起", JSON.stringify(searchField.text), "目标", root.aggTargets.length, "个")
        root.pendingAccounts = root.aggTargets.length
        for (let i = 0; i < root.aggTargets.length; ++i) {
            const t = root.aggTargets[i]
            EmbyClient.search(t.serverUrl, t.token, t.userId, searchField.text,
                              root.typesParam(), root.yearsParam(), root.filtersParam(),
                              0, ConfigManager.searchLimitPerAccount, t.accountId)
        }
        if (root.aggTargets.length === 0) {
            root.searching = false
            root.pendingAccounts = 0
        }
    }

    // 打开:保留上次输入/过滤/目标与结果模型(不自动重搜);仅清理失效
    // 目标(所选服务器已不存在 → 回退"全部"并按当前关键词重搜)。
    // 目标下拉行:"" = 全部;无查询保持服务器顺序,有查询按匹配分降序。
    function serverRows(query) {
        const q = (query || "").trim()
        const out = []
        if (q === "" || FuzzyMatch.hit(q, "全部"))
            out.push({ url: "", name: "全部" })
        const opts = root.serverOptions
        const hits = []
        for (let i = 0; i < opts.length; ++i) {
            if (!FuzzyMatch.hit(q, opts[i].name))
                continue
            hits.push({ url: opts[i].serverUrl, name: opts[i].name,
                        score: Math.max(0, FuzzyMatch.score(q, opts[i].name)) })
        }
        if (q !== "")
            hits.sort((a, b) => b.score - a.score)
        return out.concat(hits)
    }
    // 勾选/取消一台服务器("" = 清空为全部),并按当前关键词立即重搜。
    function toggleServer(url) {
        if (url === "") {
            root.selectedServers = []
            root.searchNow()
            return
        }
        // 原地 splice/push 不触发 var 通知,整体重赋值。
        const a = root.selectedServers.slice()
        const i = a.indexOf(url)
        if (i >= 0)
            a.splice(i, 1)
        else
            a.push(url)
        root.selectedServers = a
        root.searchNow()
    }
    function open() {
        root.visible = true
        const opts = root.serverOptions
        if (root.selectedServers.length > 0) {
            const urls = []
            for (let i = 0; i < opts.length; ++i)
                urls.push(opts[i].serverUrl)
            const valid = []
            for (let i = 0; i < root.selectedServers.length; ++i)
                if (urls.indexOf(root.selectedServers[i]) >= 0)
                    valid.push(root.selectedServers[i])
            if (valid.length !== root.selectedServers.length) {
                root.selectedServers = valid
                root.searchNow()
            }
        }
        searchField.forceActiveFocus()
    }
    function close() {
        root.visible = false
    }

    // 搜索响应(主窗口内所有服务器的信号都经过这里,只处理本浮窗目标)。
    Connections {
        target: EmbyClient
        function onSearchResultsReady(serverUrl, accountId) {
            for (let i = 0; i < root.aggTargets.length; ++i) {
                const t = root.aggTargets[i]
                if (t.serverUrl === serverUrl && t.accountId === accountId) {
                    console.debug("Search: 响应", serverUrl, accountId)
                    root.pendingAccounts = Math.max(0, root.pendingAccounts - 1)
                    if (root.pendingAccounts === 0)
                        root.searching = false
                    return
                }
            }
        }
    }

    // 毛玻璃暗遮罩:模糊背景 + 半透明压暗,点击关闭。
    GlassPanel {
        anchors.fill: parent
        blurSource: root.backgroundSource
        fullSource: true
        blurRadius: 64
        glassColor: Qt.rgba(0.04, 0.05, 0.07, 0.55)
        border.width: 0
        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }
    }

    Rectangle {
        anchors.top: parent.top
        anchors.topMargin: 48
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width*0.8
        height: parent.height - 96
        radius: 16
        color: "transparent"
        border.width: 0

        // 毛玻璃面板底色。
        GlassPanel {
            anchors.fill: parent
            blurSource: root.backgroundSource
            fullSource: true
            blurRadius: 48
            glassColor: Qt.rgba(0.10, 0.11, 0.14, 0.72)
            borderColor: Qt.rgba(Constants.moePink.r, Constants.moePink.g, Constants.moePink.b, 0.35)
            radius: parent.radius
        }

        // 吞掉面板内空白处的点击,防止穿透到遮罩 MouseArea 误关闭;
        // z:-1 置于所有内容之下,GridView/按钮/输入框交互不受影响。
        // (Rectangle 自身不接收鼠标事件,点击其子控件间隙会落到遮罩。)
        MouseArea {
            anchors.fill: parent
            z: -1
            onClicked: { }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 10

            // 标题行:强化浮层身份,增加萌系粉色爱心。
            Row {
                Layout.fillWidth: true
                spacing: 8
                AppText {
                    text: "♥"
                    color: Constants.moePink
                    font.pixelSize: 20
                }
                AppText {
                    text: "全局搜索"
                    color: "white"
                    font.pixelSize: 18
                    font.bold: true
                }
                Item { Layout.fillWidth: true }
            }

            TextField {
                id: searchField
                Layout.fillWidth: true
                Layout.preferredHeight: 40
                leftPadding: 34
                rightPadding: 12
                placeholderText: root.canSearch ? "搜索…(Esc 关闭)"
                                                : "先在首页打开一个媒体库再搜索(Esc 关闭)"
                placeholderTextColor: Theme.textMuted
                color: "white"
                enabled: root.canSearch
                font.pixelSize: 15
                // 输入防抖:停止输入 300ms 后才发服务端搜索(过滤区即时触发)。
                onTextChanged: searchDebounce.restart()
                background: Rectangle {
                    radius: 20
                    color: Theme.bg
                    border.width: 1
                    border.color: searchField.activeFocus ? Constants.moePink : Theme.textMuted
                    // 聚焦时粉色柔光外圈。
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -3
                        radius: 23
                        color: "transparent"
                        border.color: Constants.moePink
                        border.width: searchField.activeFocus ? 2 : 0
                        opacity: searchField.activeFocus ? 0.35 : 0
                        Behavior on opacity { NumberAnimation { duration: 120 } }
                    }
                }
                AppText {
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: "♥"
                    color: searchField.activeFocus ? Constants.moePink : Theme.textMuted
                    font.pixelSize: 16
                }
            }

            // 筛选栏:左侧类型 chips,右侧年份 + 状态。
            RowLayout {
                Layout.fillWidth: true
                spacing: 14

                // 类型过滤(IncludeItemTypes,多选,默认电影+剧集)。
                Flow {
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        model: [
                            { label: "电影", value: "Movie" },
                            { label: "剧集", value: "Series" },
                            { label: "单集", value: "Episode" },
                            { label: "季", value: "Season" },
                            { label: "视频", value: "Video" },
                            { label: "合集", value: "BoxSet" },
                        ]
                        delegate: FilterChip {
                            required property var modelData
                            label: modelData.label
                            active: root.activeTypes.indexOf(modelData.value) >= 0
                            enabled: root.canSearch
                            onClicked: {
                                // 原地 splice/push 不触发 var 属性通知,
                                // 重新赋值整数组让选中态绑定重算。
                                const idx = root.activeTypes.indexOf(modelData.value)
                                let a = root.activeTypes.slice()
                                if (idx >= 0)
                                    a.splice(idx, 1)
                                else
                                    a.push(modelData.value)
                                root.activeTypes = a
                                root.searchNow()
                            }
                        }
                    }
                }

                // 右侧筛选入口:点击弹出面板,内含年份范围和状态筛选。
                // 与 Library 的 FilterPanel 风格保持一致。
                FilterChip {
                    id: filterPanelChip
                    label: root.searchFilterCount > 0 ? "筛选 · " + root.searchFilterCount : "筛选 ▾"
                    active: root.searchFilterCount > 0
                    enabled: root.canSearch
                    onClicked: filterPopup.open()

                    Popup {
                        id: filterPopup
                        parent: filterPanelChip
                        y: filterPanelChip.height + 4
                        x: -width + filterPanelChip.width
                        width: 200
                        padding: 10
                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                        enter: Transition {
                            NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 120 }
                        }
                        exit: Transition {
                            NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 120 }
                        }
                        background: Rectangle {
                            color: Qt.rgba(0.10, 0.11, 0.14, 0.78)
                            radius: 8
                            border.width: 1
                            border.color: Qt.rgba(Constants.moePink.r, Constants.moePink.g, Constants.moePink.b, 0.45)
                        }
                        contentItem: Column {
                            width: parent.width - 20
                            spacing: 12

                            // 状态筛选:单选,默认全部。
                            Column {
                                width: parent.width
                                spacing: 6
                                AppText {
                                    text: "状态"
                                    color: Theme.textMuted
                                    font.pixelSize: 11
                                }
                                Column {
                                    width: parent.width
                                    spacing: 2
                                    Repeater {
                                        model: [
                                            { label: "全部", filter: "" },
                                            { label: "已看", filter: "IsPlayed" },
                                            { label: "未看", filter: "IsUnplayed" },
                                            { label: "收藏", filter: "IsFavorite" },
                                            { label: "继续观看", filter: "IsResumable" },
                                        ]
                                        delegate: ItemDelegate {
                                            required property var modelData
                                            required property int index
                                            property bool isOn: modelData.filter === ""
                                                                  ? root.activeFilters.length === 0
                                                                  : (root.activeFilters.length === 1 && root.activeFilters[0] === modelData.filter)
                                            width: parent.width
                                            height: 30
                                            padding: 0
                                            contentItem: Item {
                                                AppText {
                                                    anchors.left: parent.left
                                                    anchors.leftMargin: 4
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: modelData.label
                                                    color: "white"
                                                    font.pixelSize: 13
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
                                            onClicked: {
                                                if (modelData.filter === "")
                                                    root.activeFilters = []
                                                else
                                                    root.activeFilters = [modelData.filter]
                                                root.searchNow()
                                            }
                                        }
                                    }
                                }
                            }

                            // 年份范围
                            Column {
                                width: parent.width
                                spacing: 6
                                AppText {
                                    text: "年份"
                                    color: Theme.textMuted
                                    font.pixelSize: 11
                                }
                                Row {
                                    spacing: 6
                                    TextField {
                                        id: yearFromField
                                        width: 60
                                        height: 30
                                        placeholderText: "起"
                                        placeholderTextColor: Theme.textMuted
                                        color: "white"
                                        enabled: root.canSearch
                                        font.pixelSize: 13
                                        validator: IntValidator { bottom: 1900; top: 2100 }
                                        onEditingFinished: {
                                            root.yearFrom = yearFromField.text.length > 0 ? parseInt(yearFromField.text) : 0
                                            root.searchNow()
                                        }
                                        background: Rectangle {
                                            radius: 6
                                            color: Theme.bg
                                            border.width: 1
                                            border.color: Theme.textMuted
                                        }
                                    }
                                    AppText {
                                        text: "至"
                                        color: "white"
                                        font.pixelSize: 13
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    TextField {
                                        id: yearToField
                                        width: 60
                                        height: 30
                                        placeholderText: "止"
                                        placeholderTextColor: Theme.textMuted
                                        color: "white"
                                        enabled: root.canSearch
                                        font.pixelSize: 13
                                        validator: IntValidator { bottom: 1900; top: 2100 }
                                        onEditingFinished: {
                                            root.yearTo = yearToField.text.length > 0 ? parseInt(yearToField.text) : 0
                                            root.searchNow()
                                        }
                                        background: Rectangle {
                                            radius: 6
                                            color: Theme.bg
                                            border.width: 1
                                            border.color: Theme.textMuted
                                        }
                                    }
                                }
                            }

                            // 清除筛选
                            ItemDelegate {
                                visible: root.searchFilterCount > 0
                                width: parent.width
                                height: 30
                                padding: 0
                                contentItem: AppText {
                                    text: "清除筛选"
                                    color: Constants.moePink
                                    font.pixelSize: 13
                                    leftPadding: 4
                                    verticalAlignment: Text.AlignVCenter
                                }
                                background: Rectangle {
                                    radius: 4
                                    color: parent.hovered
                                        ? Qt.rgba(Constants.moePink.r, Constants.moePink.g, Constants.moePink.b, 0.18)
                                        : "transparent"
                                }
                                onClicked: {
                                    yearFromField.text = ""
                                    yearToField.text = ""
                                    root.yearFrom = 0
                                    root.yearTo = 0
                                    root.activeFilters = []
                                    root.searchNow()
                                }
                            }
                        }
                    }
                }
                // 目标选择:服务器多选(与"全部"互斥)。切换目标按当前关键词
                // 立即重搜,不清输入;目标有效性由 open() 清理。
                FilterChip {
                    id: serverChip
                    label: "目标 · " + root.targetLabel
                    active: root.selectedServers.length > 0
                    enabled: root.canSearch
                    onClicked: serverPopup.open()

                    Popup {
                        id: serverPopup
                        parent: serverChip
                        y: serverChip.height + 4
                        x: -width + serverChip.width
                        width: 240
                        padding: 8
                            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                        enter: Transition {
                            NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 120 }
                        }
                        exit: Transition {
                            NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 120 }
                        }
                        onOpened: {
                            serverSearch.text = ""
                            // 延时取焦:等 popup 完成打开处理后再把焦点交给输入框。
                            serverFocusTimer.start()
                        }
                        Timer {
                            id: serverFocusTimer
                            interval: 60
                            onTriggered: serverSearch.forceActiveFocus()
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
                            // 服务器搜索:本地模糊匹配,服务器多时不必在长列表里翻。
                            TextField {
                                id: serverSearch
                                width: parent.width
                                height: 30
                                // 打开下拉即取焦(见 serverFocusTimer),可直接输入过滤。
                                focus: true
                                leftPadding: 10
                                rightPadding: 10
                                placeholderText: "搜索服务器"
                                placeholderTextColor: Theme.textMuted
                                color: "white"
                                font.pixelSize: 13
                                selectByMouse: true
                                background: Rectangle {
                                    radius: 6
                                    color: Qt.rgba(0, 0, 0, 0.25)
                                    border.width: 1
                                    border.color: serverSearch.activeFocus
                                                  ? Qt.rgba(Constants.moePink.r, Constants.moePink.g, Constants.moePink.b, 0.55)
                                                  : Qt.rgba(1, 1, 1, 0.10)
                                }
                                // 回车 = 勾选/取消首个匹配项(与点击首行等价)。
                                onAccepted: {
                                    const rows = serverList.model
                                    if (rows && rows.length > 0)
                                        root.toggleServer(rows[0].url)
                                }
                            }
                            // 行:"" = 全部,其余为服务器多选;高度按内容自适应、超出滚动。
                            ListView {
                                id: serverList
                                width: parent.width
                                height: Math.min(contentHeight, 252)
                                clip: true
                                model: root.serverRows(serverSearch.text)
                                delegate: ItemDelegate {
                                    required property var modelData
                                    readonly property bool isOn: modelData.url === ""
                                                                 ? root.selectedServers.length === 0
                                                                 : root.selectedServers.indexOf(modelData.url) >= 0
                                    width: serverList.width
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
                                    onClicked: root.toggleServer(modelData.url)
                                }
                            }
                        }
                    }
                }
            }

            // 状态行:搜索中 / 无结果 / 已加载计数。
            Row {
                Layout.fillWidth: true
                Layout.preferredHeight: 16
                spacing: 6
                visible: statusText.text !== ""
                AppText {
                    text: "♥"
                    color: Constants.moePink
                    font.pixelSize: 12
                    opacity: 0.75
                    anchors.verticalCenter: parent.verticalCenter
                }
                AppText {
                    id: statusText
                    color: searchField.text.length === 0 ? Theme.textMuted : "white"
                    font.pixelSize: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: {
                        if (!root.canSearch)
                            return ""
                        if (searchField.text.length === 0)
                            return root.selectedServers.length > 0 ? "输入关键词,搜索所选服务器"
                                                                   : "输入关键词,跨全部账号聚合搜索"
                        if (root.searching)
                            return "搜索中…"
                        let n = 0
                        for (let i = 0; i < root.aggTargets.length; ++i) {
                            const t = root.aggTargets[i]
                            n += EmbyClient.searchModelFor(t.serverUrl, t.accountId).count
                        }
                        return n === 0 ? "无匹配结果"
                                       : "已加载 " + n + " 条 · " + root.aggTargets.length + " 个账号"
                    }
                }
            }

            // 外层 Item 由 ColumnLayout 铺满(显式赋值宽度,无隐式依赖);
            // GridView 锚定 Item 计算列数。直接放 ColumnLayout 里时,
            // 布局按 implicitWidth 放置,显式 width 绑定被覆盖 → 只有 1 列。
            Item {
                id: gridContainer
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                // 聚合结果:每账号一组(组头 + 网格),外层 Flickable 整组滚动。
                // 组模型 = 该账号的搜索模型(复合键,同服多账号互不覆盖)。
                Flickable {
                    id: aggFlick
                    anchors.fill: parent
                    clip: true
                    contentHeight: aggCol.implicitHeight
                    WheelStepHandler {
                        targetItem: aggFlick
                        pageStep: ConfigManager.searchWheelStep
                    }
                    Column {
                        id: aggCol
                        width: parent.width
                        spacing: 16
                        Repeater {
                            model: root.aggTargets
                            delegate: Column {
                                id: aggGroup
                                required property var modelData
                                required property int index
                                readonly property var gmodel: EmbyClient.searchModelFor(
                                    modelData.serverUrl, modelData.accountId)
                                // 同服务器多账号时组头附加用户名区分。
                                readonly property bool multiAccount: {
                                    let n = 0
                                    for (let k = 0; k < root.aggTargets.length; ++k)
                                        if (root.aggTargets[k].serverUrl === modelData.serverUrl)
                                            ++n
                                    return n > 1
                                }
                                width: parent.width
                                visible: gmodel.count > 0
                                spacing: 8

                                // 组头:服务器/账号名 + 条数。
                                Row {
                                    width: parent.width
                                    spacing: 6
                                    AppText {
                                        text: "♥"
                                        color: Constants.moePink
                                        font.pixelSize: 14
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    AppText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: "white"
                                        font.pixelSize: 14
                                        font.bold: true
                                        text: aggGroup.multiAccount
                                              ? modelData.name + " · " + modelData.userName
                                              : modelData.name
                                    }
                                    AppText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: Theme.textMuted
                                        font.pixelSize: 12
                                        text: gmodel.count + " 条"
                                    }
                                }

                                // 网格:列数同根卡片计算(基于外层宽);高度 = 行数 ×
                                // cellH,固定高不滚动(整组随外层 Flickable 滚)。
                                GridView {
                                    id: aggGrid
                                    width: parent.width
                                    height: Math.max(root.cellH,
                                        Math.ceil(gmodel.count / Math.max(1, Math.floor(parent.width / root.cellW)))
                                        * root.cellH)
                                    cellWidth: root.cellW
                                    cellHeight: root.cellH
                                    clip: true
                                    reuseItems: true
                                    cacheBuffer: 600
                                    model: aggGroup.gmodel
                                    delegate: Item {
                                        required property var model
                                        required property int index
                                        width: aggGrid.cellWidth
                                        height: aggGrid.cellHeight
                                        z: card.hovered ? 2 : 0
                                        PosterCard {
                                            id: card
                                            anchors.centerIn: parent
                                            width: root.cardW
                                            height: root.cardH
                                            model: parent.model
                                            index: parent.index
                                            showActions: false
                                            itemId: model.id
                                            posterId: model.posterId
                                            title: model.name
                                            year: model.year
                                            rating: model.rating
                                            played: model.played
                                            favorite: model.favorite
                                            positionTicks: model.positionTicks
                                            runtimeTicks: model.runtimeTicks
                                            unplayedCount: model.unplayedCount
                                            itemType: model.type
                                            onClicked: root.showDetail(model.id, model.posterId,
                                                                       model.name, modelData.serverUrl,
                                                                       modelData.accountId)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }


            }
        }
    }

    // 输入防抖定时器。
    Timer {
        id: searchDebounce
        interval: Constants.searchDebounceMs
        onTriggered: {
            if (root.canSearch)
                root.searchNow()
        }
    }
}
