pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import MoePlayer.Core

//! 全局搜索浮层(Ctrl+K 开关):按最近浏览的服务器搜索(主窗口注入 serverUrl),
//! 服务端搜索跨库递归(影片/剧集/单集),输入 300ms 防抖后请求。
//! 过滤区(类型/年份/已看状态/排序)全部走服务端查询参数,客户端零过滤。
//! 分页:请求 Limit+1 探针,多出的 1 条由 C++ 截断并置 model.hasMore,
//! 滚动到底自动加载下一页。结果网格点击进详情;Esc / 点击背景关闭。
Item {
    id: root

    // 搜索目标服务器(主窗口按最近浏览的页面注入;空则不可搜索)。
    property string serverUrl: ""
    // 该服务器的搜索结果模型(serverUrl 就绪后一次性取引用)。
    property var sm: null
    readonly property bool canSearch: root.serverUrl !== "" && root.creds().token !== ""

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
    // 排序:""=相关度(不传 SortBy),否则 CommunityRating/ProductionYear/SortName。
    property string sortBy: ""
    // 排序方向(SortOrder);"" = 不传(服务器默认)。
    property string sortOrder: ""
    // 分页游标:下一页 StartIndex;0 表示替换结果。
    property int startIndex: 0
    // 首屏/过滤重搜进行中(状态行显示"搜索中")。
    property bool searching: false
    // 分页加载中(防并发翻页)。
    property bool loadingMore: false

    // 点击结果进详情(携带所在服务器)。
    signal showDetail(string itemId, string posterId, string title, string serverUrl)

    onServerUrlChanged: {
        if (root.serverUrl !== "")
            root.sm = EmbyClient.searchModelFor(root.serverUrl)
    }

    function creds() {
        return AccountManager.credsForServer(root.serverUrl)
    }

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

    // 按当前过滤状态发起(或重置后发起)一次搜索;resetPage 为真时从头翻页。
    function searchNow(resetPage) {
        if (!root.canSearch)
            return
        if (resetPage)
            root.startIndex = 0
        root.searching = resetPage
        root.loadingMore = !resetPage
        const c = root.creds()
        EmbyClient.search(root.serverUrl, c.token, c.userId, searchField.text,
                          root.typesParam(),
                          root.yearsParam(),
                          root.filtersParam(),
                          root.sortBy, root.sortOrder,
                          root.startIndex, Constants.searchPageSize)
    }

    // 加载下一页(滚动到底触发;hasMore/loadingMore/searching 守卫)。
    function loadMore() {
        if (!root.canSearch || !root.sm || !root.sm.hasMore)
            return
        if (root.loadingMore || root.searching || searchField.text.length === 0)
            return
        root.startIndex += Constants.searchPageSize
        root.searchNow(false)
    }

    // 打开:重置过滤为默认,清空结果并聚焦输入框。
    function open() {
        root.visible = true
        root.activeTypes = ["Movie", "Series"]
        root.yearFrom = 0
        root.yearTo = 0
        root.activeFilters = []
        yearFromField.text = ""
        yearToField.text = ""
        sortBox.currentIndex = 0
        root.sortBy = ""
        root.sortOrder = ""
        root.startIndex = 0
        root.loadingMore = false
        searchField.text = ""
        if (root.canSearch) {
            const c = root.creds()
            EmbyClient.search(root.serverUrl, c.token, c.userId, "",
                              "", "", "", "", "", 0, Constants.searchPageSize)
        }
        searchField.forceActiveFocus()
    }
    function close() {
        root.visible = false
    }

    // 搜索响应(主窗口内所有服务器的信号都经过这里,只处理本浮窗目标)。
    Connections {
        target: EmbyClient
        function onSearchResultsReady(serverUrl) {
            if (serverUrl !== root.serverUrl)
                return
            root.searching = false
            root.loadingMore = false
            // 结果不足一屏且还有更多时自动补页(与滚动到底等价,逐页
            // 加载直到填满或 hasMore=false,安全终止)。
            if (resultGrid.atYEnd && root.sm && root.sm.hasMore && root.sm.count > 0)
                root.loadMore()
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }
    }

    Rectangle {
        anchors.top: parent.top
        anchors.topMargin: 48
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(760, parent.width - 64)
        height: parent.height - 96
        radius: 12
        color: Theme.surface

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 10

            TextField {
                id: searchField
                Layout.fillWidth: true
                Layout.preferredHeight: 40
                placeholderText: root.canSearch ? "搜索影片 / 剧集 / 单集(Esc 关闭)"
                                                : "先在首页打开一个媒体库再搜索(Esc 关闭)"
                placeholderTextColor: "white"
                color: "white"
                enabled: root.canSearch
                font.pixelSize: 15
                // 输入防抖:停止输入 300ms 后才发服务端搜索(过滤区即时触发)。
                onTextChanged: searchDebounce.restart()
                background: Rectangle {
                    radius: 8
                    color: Theme.bg
                    border.width: 1
                    border.color: Theme.textMuted
                }
            }

            // 行1:类型过滤(IncludeItemTypes,多选,默认电影+剧集)。Flow
            // 是 Positioner,自动布局/换行 Repeater 的 delegates(RowLayout
            // 不布局);宽度按文字自适应。类型集合为服务器实测可过滤的
            // 影视/媒体类型(排除 trailer;排除未知类型——服务器对未知
            // IncludeItemTypes 忽略参数返回全量,加入会污染结果)。
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
                    delegate: Button {
                        required property var modelData
                        height: 30
                        padding: 14
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
                            root.searchNow(true)
                        }
                        background: Rectangle {
                            radius: 15
                            color: root.activeTypes.indexOf(modelData.value) >= 0
                                   ? Theme.accent : Theme.bg
                            border.width: root.activeTypes.indexOf(modelData.value) >= 0
                                          ? 0 : 1
                            border.color: Theme.textMuted
                        }
                        contentItem: AppText {
                            text: modelData.label
                            color: "white"
                            font.pixelSize: 13
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }

            // 行2:年份 + 已看状态(多选)+ 排序。
            RowLayout {
                Layout.fillWidth: true
                spacing: 14

                // 年份范围(Years):单端 = 精确单年,双端 = 区间展开;
                // 空 = 不限。服务器不支持范围语法(实测 500),展开逗号列表。
                RowLayout {
                    spacing: 4
                    AppText {
                        text: "年份"
                        color: "white"
                        font.pixelSize: 13
                    }
                    TextField {
                        id: yearFromField
                        Layout.preferredWidth: 60
                        Layout.preferredHeight: 30
                        placeholderText: "起"
                        placeholderTextColor: "white"
                        color: "white"
                        enabled: root.canSearch
                        font.pixelSize: 13
                        validator: IntValidator { bottom: 1900; top: 2100 }
                        // 回车 / 失焦提交;非法文本回退 0(不限)。
                        onEditingFinished: {
                            root.yearFrom = yearFromField.text.length > 0 ? parseInt(yearFromField.text) : 0
                            root.searchNow(true)
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
                    }
                    TextField {
                        id: yearToField
                        Layout.preferredWidth: 60
                        Layout.preferredHeight: 30
                        placeholderText: "止"
                        placeholderTextColor: "white"
                        color: "white"
                        enabled: root.canSearch
                        font.pixelSize: 13
                        validator: IntValidator { bottom: 1900; top: 2100 }
                        onEditingFinished: {
                            root.yearTo = yearToField.text.length > 0 ? parseInt(yearToField.text) : 0
                            root.searchNow(true)
                        }
                        background: Rectangle {
                            radius: 6
                            color: Theme.bg
                            border.width: 1
                            border.color: Theme.textMuted
                        }
                    }
                    Button {
                        Layout.preferredWidth: 24
                        Layout.preferredHeight: 30
                        visible: yearFromField.text.length > 0 || yearToField.text.length > 0
                        enabled: root.canSearch
                        text: "✕"
                        onClicked: {
                            yearFromField.text = ""
                            yearToField.text = ""
                            root.yearFrom = 0
                            root.yearTo = 0
                            root.searchNow(true)
                        }
                        background: Rectangle {
                            radius: 6
                            color: Theme.bg
                        }
                        contentItem: AppText {
                            text: parent.text
                            color: "white"
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                // 已看/未看/收藏(Filters,多选)。
                Row {
                    spacing: 8
                    Repeater {
                        model: [
                            { label: "已看", filter: "IsPlayed" },
                            { label: "未看", filter: "IsUnplayed" },
                            { label: "进行中", filter: "IsResumable" },
                            { label: "收藏", filter: "IsFavorite" },
                        ]
                        delegate: Button {
                            required property var modelData
                            width: 52
                            height: 30
                            enabled: root.canSearch
                            onClicked: {
                                // 原地 splice/push 不触发 var 属性通知,
                                // 重新赋值整数组让选中态绑定重算。
                                const idx = root.activeFilters.indexOf(modelData.filter)
                                let a = root.activeFilters.slice()
                                if (idx >= 0)
                                    a.splice(idx, 1)
                                else
                                    a.push(modelData.filter)
                                root.activeFilters = a
                                root.searchNow(true)
                            }
                            background: Rectangle {
                                radius: 15
                                color: root.activeFilters.indexOf(modelData.filter) >= 0
                                       ? Theme.accent : Theme.bg
                                border.width: root.activeFilters.indexOf(modelData.filter) >= 0
                                              ? 0 : 1
                                border.color: Theme.textMuted
                            }
                            contentItem: AppText {
                                text: modelData.label
                                color: "white"
                                font.pixelSize: 13
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }
                }

                // 排序(SortBy + SortOrder;相关度 = 不传)。
                RowLayout {
                    spacing: 4
                    AppText {
                        text: "排序"
                        color: "white"
                        font.pixelSize: 13
                    }
                    ComboBox {
                        id: sortBox
                        Layout.preferredWidth: 110
                        Layout.preferredHeight: 30
                        enabled: root.canSearch
                        textRole: "label"
                        // 名称/时间 + 评分/热度全量 SortBy;相关度 = 不传
                        // (服务器默认匹配度)。方向默认:片名升序,其余降序。
                        model: [
                            { label: "相关度", sortBy: "", order: "" },
                            { label: "片名", sortBy: "SortName", order: "Ascending" },
                            { label: "年份", sortBy: "ProductionYear", order: "Descending" },
                            { label: "首映", sortBy: "PremiereDate", order: "Descending" },
                            { label: "入库时间", sortBy: "DateCreated", order: "Descending" },
                            { label: "时长", sortBy: "Runtime", order: "Descending" },
                            { label: "最近播放", sortBy: "DatePlayed", order: "Descending" },
                            { label: "评分", sortBy: "CommunityRating", order: "Descending" },
                            { label: "专业评分", sortBy: "CriticRating", order: "Descending" },
                            { label: "播放次数", sortBy: "PlayCount", order: "Descending" },
                        ]
                        onActivated: (index) => {
                            const it = sortBox.model[index]
                            root.sortBy = it.sortBy
                            root.sortOrder = it.order
                            root.searchNow(true)
                        }
                        background: Rectangle {
                            radius: 6
                            color: Theme.bg
                            border.width: 1
                            border.color: Theme.textMuted
                        }
                        contentItem: AppText {
                            text: sortBox.displayText
                            color: "white"
                            font.pixelSize: 13
                            leftPadding: 8
                            verticalAlignment: Text.AlignVCenter
                        }
                        indicator: AppText {
                            text: "▾"
                            color: "white"
                            font.pixelSize: 11
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            verticalAlignment: Text.AlignVCenter
                        }
                        delegate: ItemDelegate {
                            required property var modelData
                            // Qt 6 delegate 上下文经 required 属性注入:
                            // 不声明则 index 不存在(旧式注入已移除)。
                            required property int index
                            width: sortBox.width
                            height: 30
                            // index 经 required 注入后,嵌套的 contentItem/
                            // background 作用域仍不可见,顶层捕获为属性。
                            readonly property bool _hl: sortBox.highlightedIndex === index
                            contentItem: AppText {
                                text: modelData.label
                                color: "white"
                                font.pixelSize: 13
                                leftPadding: 8
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                color: parent._hl ? Theme.accent : "transparent"
                            }
                        }
                        popup: Popup {
                            y: sortBox.height + 4
                            width: sortBox.width
                            padding: 0
                            background: Rectangle {
                                color: Theme.surface
                                radius: 6
                                border.width: 1
                                border.color: Theme.textMuted
                            }
                            contentItem: ListView {
                                clip: true
                                implicitHeight: contentHeight
                                model: sortBox.popup.visible ? sortBox.delegateModel : null
                                currentIndex: sortBox.highlightedIndex
                            }
                        }
                    }
                    // 排序方向:相关度时禁用(无方向)。
                    Button {
                        Layout.preferredWidth: 30
                        Layout.preferredHeight: 30
                        enabled: root.canSearch && sortBox.currentIndex !== 0
                        onClicked: {
                            root.sortOrder = root.sortOrder === "Ascending" ? "Descending" : "Ascending"
                            root.searchNow(true)
                        }
                        background: Rectangle {
                            radius: 6
                            color: Theme.bg
                            border.width: 1
                            border.color: Theme.textMuted
                        }
                        contentItem: AppText {
                            text: root.sortOrder === "Ascending" ? "↑" : "↓"
                            color: parent.enabled ? "white" : Theme.textMuted
                            font.pixelSize: 13
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }

            // 状态行:搜索中 / 无结果 / 已加载计数。
            AppText {
                id: statusLine
                Layout.fillWidth: true
                Layout.preferredHeight: 16
                font.pixelSize: 12
                color: "white"
                text: {
                    if (!root.canSearch)
                        return ""
                    if (searchField.text.length === 0)
                        return "输入关键词,搜索当前服务器的全部媒体库"
                    if (root.searching && (!root.sm || root.sm.count === 0))
                        return "搜索中…"
                    if (!root.sm || root.sm.count === 0)
                        return "无匹配结果"
                    return "已加载 " + root.sm.count + " 条"
                           + (root.sm.hasMore ? " · 上滑加载更多" : "")
                }
            }

            GridView {
                id: resultGrid
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                cellWidth: Constants.cellW
                cellHeight: Constants.cellH
                model: root.sm
                // 滚动到底自动加载下一页(内容不满一屏时持续加载直到填满或到底)。
                onAtYEndChanged: {
                    if (atYEnd)
                        root.loadMore()
                }
                // 搜索结果轻量卡片:无需悬停操作按钮,点击进详情。
                delegate: PosterCard {
                    width: 152
                    height: 236
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
                    onClicked: root.showDetail(model.id, model.posterId, model.name, root.serverUrl)
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
                root.searchNow(true)
        }
    }

    // Esc 关闭。
    Shortcut {
        sequences: ["Esc"]
        onActivated: root.close()
    }
}
