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

    // 搜索目标服务器(主窗口按最近浏览的页面注入;空则不可搜索)。
    property string serverUrl: ""
    // 该服务器的搜索结果模型(serverUrl 就绪后一次性取引用)。
    property var sm: null
    readonly property bool canSearch: root.serverUrl !== "" && root.creds().token !== ""
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
    signal showDetail(string itemId, string posterId, string title, string serverUrl)

    // 需要模糊的背景内容(主窗口传入 StackView,避免把浮层自身也模糊)。
    property Item backgroundSource: null

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
        root.startIndex = 0
        root.loadingMore = false
        searchField.text = ""
        if (root.canSearch) {
            const c = root.creds()
            EmbyClient.search(root.serverUrl, c.token, c.userId, "",
                              "", "", "", 0, Constants.searchPageSize)
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
                                root.searchNow(true)
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
                                                root.searchNow(true)
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
                                            root.searchNow(true)
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
                                    root.searchNow(true)
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
                            return "输入关键词,搜索当前服务器的全部媒体库"
                        if (root.searching && (!root.sm || root.sm.count === 0))
                            return "搜索中…"
                        if (!root.sm || root.sm.count === 0)
                            return "无匹配结果"
                        return "已加载 " + root.sm.count + " 条"
                               + (root.sm.hasMore ? " · 上滑加载更多" : "")
                    }
                }
            }

            // 外层 Item 由 ColumnLayout 铺满(显式赋值宽度,无隐式依赖);
            // GridView 锚定 Item 计算列数。直接放 ColumnLayout 里时,
            // 布局按 implicitWidth 放置,显式 width 绑定被覆盖 → 只有 1 列。
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                GridView {
                    id: resultGrid
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    // 宽度 = 整数列 × cellW 并水平居中:结果不满一行时
                    // 内容居中显示,而非左贴边;满行时与容器等宽。
                    width: Math.max(1, Math.floor((parent.width - 4) / Constants.cellW))
                           * Constants.cellW
                    cellWidth: Constants.cellW
                    cellHeight: Constants.cellH
                    model: root.sm
                    // 结果项入场动画:淡入 + 轻微缩放,萌系轻盈感。
                    add: Transition {
                        NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 180 }
                        NumberAnimation { property: "scale"; from: 0.92; to: 1.0; duration: 180; easing.type: Easing.OutQuad }
                    }
                    // 滚动到底自动加载下一页(内容不满一屏时持续加载直到填满或到底)。
                    onAtYEndChanged: {
                        if (atYEnd)
                            root.loadMore()
                    }
                    // 搜索结果轻量卡片:无需悬停操作按钮,点击进详情。
                    delegate: PosterCard {
                        // delegate 根即本卡,兄弟间 z 直接生效(放大浮起
                        // 盖住相邻结果)。
                        z: hovered ? 2 : 0
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
