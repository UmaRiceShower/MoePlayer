pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import MoePlayer.Core

//! 媒体库主界面:专注展示某服务器的指定媒体库条目(分页网格)。
//! 浏览无状态化:serverUrl 为目标服务器,所有请求经
//! AccountManager.credsForServer 取凭据按服务器路由,不依赖任何会话;
//! 无账号/凭据失效时页面不可浏览,账号由主界面(ServerManager)管理。
//! 顶部一行选择媒体库(下拉),主体为条目网格;播放/详情经信号交给主窗口。
//! 结构遵循 Qt QML Coding Conventions:属性 → 信号 → 函数 → 子对象。
Item {
    id: root

    // ============================= 属性 =============================

    // --- 浏览目标与恢复 ---
    // 进入页面时选中的媒体库 id(首页点某库海报时传入;空则默认第一个)。
    property string initialViewId: ""
    // 进入页面时选中的媒体库名(首页海报携带,面包屑立即显示,不等视图
    // 拉取;空则待 applyView 从模型取)。
    property string initialViewName: ""
    // 浏览目标服务器(从首页/主窗口传入;空则默认第一个有效账号)。
    property string serverUrl: ""
    // 浏览用账号 id(主窗口导航时注入)。
    property string accountId: ""
    // 上次离开时的浏览状态(viewId/排序/滚动位置),恢复用。
    property var restore: null
    // 首屏数据就绪后要恢复的滚动位置(恢复时 onItemsReceived 消费一次)。
    property real pendingRestoreY: 0

    // --- 网格尺寸(弹性列数) ---
    // 可用宽 = 网格宽(anchors 左右各 24 margin)。卡宽随窗口在
    // [cellMinW, cellMaxW] 区间伸缩填满整行(见 Constants.gridCardW)。
    // cell = 卡宽 + cellGap(GridView 无 gap 语义,delegate 取卡宽在 cell
    // 内留右/下缘 → 卡间距 = cellGap);cellW 已含 1e-6 下偏,保证
    // GridView 内部列数截断恰为 n,整行铺满无右侧空白(见 gridCellW)。
    readonly property real cardW: Constants.gridCardW(Math.max(1, root.width - 48), Constants.cellMinW, Constants.cellMaxW)
    readonly property int cardH: Constants.gridCardH(root.cardW)
    readonly property real cellW: Constants.gridCellW(Math.max(1, root.width - 48), Constants.cellMinW, Constants.cellMaxW)
    // gridCellH 参数是**卡宽**(内部按 2:3 转卡高再 +gap);传卡高会把
    // cell 高算成 cardH×1.5+gap → 行间距 ≈ 半卡高(上下间距过大)。
    readonly property int cellH: Constants.gridCellH(root.cardW)

    // --- 当前浏览上下文 ---
    // 当前浏览的视图 id(分页加载用)。
    property string currentViewId: ""
    // 当前视图显示名(面包屑媒体库段):初始 = 首页传入的 initialViewName,
    // applyView 后与模型实际选中同步(initialViewId 未匹配回退第一库时校正)。
    property string currentViewName: ""
    // 当前服务端排序(DateLastMediaAdded 在 4.9.5 条目级查询报错,不在档位内)。
    // 默认值来自用户配置(ConfigManager);restore 恢复时会覆盖。
    property string currentSortBy: ConfigManager.librarySortBy
    property string currentSortOrder: ConfigManager.librarySortOrder

    // --- 库内筛选状态(直接映射 API 查询参数,空 = 不传) ---
    // 类型单选(Genres 多值为 AND 语义,单选安全):Genre 名称。
    property string currentGenres: ""
    // 年份区间(Years 多值 OR 语义 = 区间):"1999,2000,2001,2002" 逗号
    // 列表;由输入框 "起始-终止" 解析生成;空 = 全部年份。
    property string currentYears: ""
    // 评分下限(MinCommunityRating):"6".."9";空 = 不限。
    property string currentMinRating: ""
    // 状态过滤(Filters):""|IsUnplayed|IsPlayed|IsFavorite。
    property string currentFilter: ""
    // 库内搜索关键词(SearchTerm,空 = 不传)。与 ParentId/筛选/排序/分页
    // 正交;带词时服务端固定相关度排序(SortBy 忽略),UI 置灰排序控件。
    property string currentSearchTerm: ""
    // 子文件夹下钻路径(元素 {id, name},按层序;空 = 库根)。进文件夹 push,
    // 上级 pop、根清空;查询 ParentId = 末元素 id 或库视图 id。
    property var folderPath: []

    // --- 模型引用(浏览绑定,页面生命周期内一次性取引用) ---
    property var vm: null
    property var im: null
    property var gm: null
    property var fm: null

    // --- 派生态 ---
    property bool busy: false
    // 可浏览 = 有服务器且凭据有效。
    readonly property bool browseReady: root.serverUrl !== "" && root.creds().token !== ""

    // --- 筛选下拉底色(与面包屑链同风格) ---
    readonly property color crumb: Qt.rgba(Theme.scrim.r, Theme.scrim.g, Theme.scrim.b, 1.0)
    readonly property color crumbHover: Theme.tint
    // ============================= 信号 =============================
    // 点面包屑服务器段:回首页并把该服显示名注入首页过滤框。
    signal browseHome(string name)

    // 请求播放(携带完整播放地址/头/元数据)。
    signal playRequested(string url, var headers, var meta)
    // 点击条目进入详情页(携带所在服务器与账号)。
    signal showDetail(string itemId, string posterId, string title, string serverUrl, string accountId)
    // 离开页面时保存浏览状态(由主窗口存下,再次进入经 restore 恢复)。
    signal libraryStateSaved(var state)

    // ===================== 内部组件与数据 =====================

    // 分类筛选下拉(年份/评分/状态):暗色圆角底(crumb 系,同面包屑配色),
    // hover 提亮;弹出层与面包屑下拉同款(暗色 surface/圆角/描边/
    // hover accent 高亮/选中圆点)。model 统一为 ListModel(label/value)。
    component FilterCombo: ComboBox {
        id: fcombo
        height: 32
        // 同 FilterChip:RowLayout 覆盖显式 height,声明 preferredHeight 保持 32。
        Layout.preferredHeight: 32
        padding: 0
        background: Rectangle {
            radius: 16
            color: fcombo.hovered ? root.crumbHover : root.crumb
            border.width: 1
            border.color: fcombo.hovered ? Theme.accent : Theme.textMuted
        }
        contentItem: Item {
            AppText {
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.right: fcomboArrow.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                text: fcombo.displayText
                font.pixelSize: 13
                elide: Text.ElideRight
            }
            AppText {
                id: fcomboArrow
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: fcombo.popup.opened ? "▴" : "▾"
                font.pixelSize: 10
            }
        }
        indicator: null
        popup: Popup {
            id: fcomboPopup
            y: fcombo.height + 4
            width: fcombo.width
            implicitHeight: contentItem.implicitHeight
            padding: 6
            enter: Transition {
                NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 120 }
            }
            exit: Transition {
                NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 120 }
            }
            background: Rectangle {
                color: Qt.rgba(Theme.scrim.r, Theme.scrim.g, Theme.scrim.b, 0.78)
                radius: 8
                border.width: 1
                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
            }
            contentItem: ListView {
                clip: true
                implicitHeight: contentHeight
                model: fcombo.delegateModel
                currentIndex: fcombo.highlightedIndex
                highlightMoveDuration: 0
            }
        }
        delegate: ItemDelegate {
            // Qt6 delegate 上下文(Bound 模式):required 声明注入属性。
            required property int index
            required property var model
            property string itemText: model[fcombo.textRole]
            width: ListView.view.width
            height: 30
            padding: 0
            contentItem: Item {
                AppText {
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: parent.parent.itemText
                    font.pixelSize: 13
                    elide: Text.ElideRight
                }
                Rectangle {
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    width: 6
                    height: 6
                    radius: 3
                    color: Theme.accent
                    visible: fcombo.currentIndex === parent.parent.index
                }
            }
            highlighted: fcombo.highlightedIndex === index
            background: Rectangle {
                radius: 4
                color: parent.highlighted || parent.hovered
                    ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                    : "transparent"
            }
        }
    }

    // 筛选面板选项行(单选):文本 + 右侧选中圆点。isOn 由调用方绑定
    // root 的 QML 属性(可追踪,点击后即时刷新);onClicked 调用方直接写。
    component FilterOption: ItemDelegate {
        id: fopt
        required property string itemLabel
        required property string itemValue
        property bool isOn: false
        property int optionWidth: 200
        width: optionWidth
        height: 30
        padding: 0
        contentItem: Item {
            AppText {
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.right: mark.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                text: fopt.itemLabel
                font.pixelSize: 13
                elide: Text.ElideRight
            }
            Rectangle {
                id: mark
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                width: 6
                height: 6
                radius: 3
                color: fopt.isOn ? Theme.accent : "transparent"
                border.width: 1
                border.color: fopt.isOn
                        ? Theme.accent
                        : Qt.rgba(Theme.textMuted.r, Theme.textMuted.g,
                                  Theme.textMuted.b, 0.6)
            }
        }
        background: Rectangle {
            radius: 4
            color: fopt.hovered
                ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                : "transparent"
        }
    }

    // 聚合筛选入口:类型/评分/状态/年份做进一个控件,面板内分面小节
    // 分组,激活计数显示在按钮上。面板固定四节直接渲染——全部引用
    // root 的 QML 对象(ListModel/属性/函数),不用 JS 数组作 model:
    // 数组元素经模型系统包装后函数属性丢失(inputText 非函数)。
    // 选项节单选,点击即应用并保持面板打开(便于连续调整多节);年份
    // = 输入区间节(枚举年份传服务端)。激活时 accent 描边 + "筛选 · N",
    // 底部"清除筛选"一键归零;Esc/点外部关闭。
    // 外壳用 Item + MouseArea + Popup:Button 无普通 popup 属性(attached
    // Button.popup 语义不同),ComboBox 语义不合(强制 currentIndex/
    // delegateModel)。
    component FilterPanel: Item {
        id: fpanel
        height: 30
        // 宽度由标签文本驱动(文本 + 左右内边距 + ▾ 箭头 + 间距),最小
        // 78 保证可点击区域。
        width: Math.max(78, fpanelLabel.implicitWidth + 36)
        property int activeCount: 0
        property string labelText: activeCount > 0 ? "筛选 · " + activeCount : "筛选"
        Rectangle {
            anchors.fill: parent
            radius: 16
            color: fpanelHover.containsMouse ? root.crumbHover : root.crumb
            border.color: fpanel.activeCount > 0 ? Theme.accent : Theme.textMuted
            border.width: 1
        }
        AppText {
            id: fpanelLabel
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.right: fpanelArrow.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            text: fpanel.labelText
            font.pixelSize: 13
            elide: Text.ElideRight
        }
        AppText {
            id: fpanelArrow
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: fpanelPopup.opened ? "▴" : "▾"
            font.pixelSize: 10
        }
        MouseArea {
            id: fpanelHover
            anchors.fill: parent
            hoverEnabled: true
            onClicked: {
                if (fpanelPopup.opened)
                    fpanelPopup.close()
                else
                    fpanelPopup.open()
            }
        }
        Popup {
            id: fpanelPopup
            y: fpanel.height + 4
            // 打开前刷新 sections(current 最新)与宽度(最长文本 + 32,
            // 上限防超窗);JS 赋值不建绑定依赖,每次打开重算。
            onAboutToShow: {
                width = Math.min(root.width - 48,
                                 Math.max(fpanel.width, root.maxFilterTextWidth() + 32))
            }
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
            implicitHeight: contentItem.implicitHeight
            padding: 6
            enter: Transition {
                NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 120 }
            }
            exit: Transition {
                NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 120 }
            }
            background: Rectangle {
                color: Qt.rgba(Theme.scrim.r, Theme.scrim.g, Theme.scrim.b, 0.78)
                radius: 8
                border.width: 1
                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
            }
            // 面板固定四节:类型/评分/状态(选项单选)+ 年份(输入区间)。
            // 宽度引用 popup id(组件内 id 无时序问题;ListView.view attached
            // 只注入 ListView 直接 delegate,parent 构造期可能 null)。
            contentItem: Flickable {
                id: fpanelFlick
                clip: true
                contentHeight: fpanelCol.implicitHeight
                // 面板整体滚动(类型分面可上百项),上限半窗高。
                implicitHeight: Math.min(contentHeight, Math.max(240, root.height * 0.5))
                Column {
                    id: fpanelCol
                    width: fpanelPopup.width - 12
                    // --- 类型(单选,分面动态) ---
                    AppText {
                        text: "类型"
                        color: Theme.textMuted
                        font.pixelSize: 11
                        topPadding: 8
                        bottomPadding: 2
                        leftPadding: 10
                    }
                    Repeater {
                        model: genreFilterModel
                        delegate: FilterOption {
                            required property int index
                            required property var model
                            itemLabel: model.label
                            itemValue: model.value
                            optionWidth: fpanelPopup.width - 12
                            isOn: root.currentGenres === itemValue
                            onClicked: {
                                root.currentGenres = itemValue
                                root.refetch()
                            }
                        }
                    }
                    // --- 评分(单选,固定档位,大的在前) ---
                    AppText {
                        text: "评分"
                        color: Theme.textMuted
                        font.pixelSize: 11
                        topPadding: 8
                        bottomPadding: 2
                        leftPadding: 10
                    }
                    Repeater {
                        model: ratingFilterModel
                        delegate: FilterOption {
                            required property int index
                            required property var model
                            itemLabel: model.label
                            itemValue: model.value
                            optionWidth: fpanelPopup.width - 12
                            isOn: root.currentMinRating === itemValue
                            onClicked: {
                                root.currentMinRating = itemValue
                                root.refetch()
                            }
                        }
                    }
                    // --- 状态(单选,固定档位) ---
                    AppText {
                        text: "状态"
                        color: Theme.textMuted
                        font.pixelSize: 11
                        topPadding: 8
                        bottomPadding: 2
                        leftPadding: 10
                    }
                    Repeater {
                        model: statusFilterModel
                        delegate: FilterOption {
                            required property int index
                            required property var model
                            itemLabel: model.label
                            itemValue: model.value
                            optionWidth: fpanelPopup.width - 12
                            isOn: root.currentFilter === itemValue
                            onClicked: {
                                root.currentFilter = itemValue
                                root.refetch()
                            }
                        }
                    }
                    // --- 年份(输入区间,放最后):"起始-终止",回车/失焦提交,
                    // 客户端枚举区间年份为逗号列表(Years 多值 OR 语义) ---
                    AppText {
                        text: "年份"
                        color: Theme.textMuted
                        font.pixelSize: 11
                        topPadding: 8
                        bottomPadding: 2
                        leftPadding: 10
                    }
                    TextField {
                        x: 6
                        width: fpanelPopup.width - 24
                        height: 30
                        text: root.yearInputText()
                        placeholderText: "如 1999-2002"
                        placeholderTextColor: Theme.textMuted
                        color: Theme.textPrimary
                        font.pixelSize: 13
                        padding: 8
                        background: Rectangle {
                            radius: 6
                            color: root.crumb
                            border.color: parent.activeFocus ? Theme.accent : Theme.textMuted
                            border.width: 1
                        }
                        onEditingFinished: root.applyYearRange(text)
                    }
                    // --- 底部:一键清除全部筛选(仅激活时显示) ---
                    ItemDelegate {
                        visible: fpanel.activeCount > 0
                        width: fpanelPopup.width - 12
                        height: 30
                        padding: 0
                        contentItem: AppText {
                            text: "清除筛选"
                            color: Theme.accentText
                            font.pixelSize: 13
                            leftPadding: 10
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            radius: 4
                            color: parent.hovered
                                ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                                : "transparent"
                        }
                        onClicked: {
                            root.resetFilters()
                            root.refetch()
                            fpanelPopup.close()
                        }
                    }
                }
            }
        }
    }

    // 排序档位:label 展示,key 为 Emby SortBy 值(服务端排序,切了即重查)。
    // ListModel(而非 JS 对象数组):ComboBox model/textRole 官方标准模型。
    ListModel {
        id: sortOptions
        ListElement { label: "更新日期"; key: "DateLastContentAdded" }
        ListElement { label: "加入时间"; key: "DateCreated" }
        ListElement { label: "首映日期"; key: "PremiereDate" }
        ListElement { label: "名称"; key: "SortName" }
        ListElement { label: "出品年份"; key: "ProductionYear" }
        ListElement { label: "社区评分"; key: "CommunityRating" }
        ListElement { label: "影评评分"; key: "CriticRating" }
        ListElement { label: "随机"; key: "Random" }
        ListElement { label: "修改时间"; key: "DateModified" }
    }

    // ============================= 函数 =============================

    // --- 基础 ---
    // 该服务器凭据:按账号 id 精确定位(多账号不串)。
    function creds() {
        return AccountManager.credsForAccount(root.accountId)
    }
    // 服务器显示名:账号名/用户名,未匹配回退地址。
    function serverLabel() {
        const accs = AccountManager.accounts
        for (const a of accs)
            if (a.serverUrl === root.serverUrl)
                return a.name !== "" ? a.name : a.userName
        return root.serverUrl
    }

    // 媒体库下拉模型(JS 快照,模糊搜索过滤)。
    function filteredViews(q) {
        const rows = []
        const m = root.vm
        for (let i = 0; m && i < m.count; ++i) {
            const n = m.nameAt(i) || ""
            if (q !== "" && !FuzzyMatch.hit(q, n))
                continue
            rows.push({ id: m.idAt(i), name: n })
        }
        return rows
    }
    // 切库(下拉选中):重置下钻路径与筛选,重拉。
    function selectView(id) {
        if (root.currentViewId === id)
            return
        root.currentViewId = id
        root.folderPath = []
        root.resetFilters()
        root.reloadAll()
    }
    // 文件夹下拉模型:库根 + 祖先链(当前层 kind=current)+ 当前层子文件夹。
    function folderTreeRows() {
        const rows = [{ name: "全部", level: 0,
                        kind: root.folderPath.length === 0 ? "current" : "root" }]
        for (let i = 0; i < root.folderPath.length; ++i) {
            const f = root.folderPath[i]
            rows.push({ name: f.name, level: i + 1, idx: i,
                        kind: i === root.folderPath.length - 1 ? "current" : "ancestor" })
        }
        const m = root.fm
        for (let i = 0; m && i < m.count; ++i) {
            const n = m.nameAt(i)
            if (n)
                rows.push({ name: n, level: root.folderPath.length + 1,
                            kind: "child", id: m.idAt(i) })
        }
        return rows
    }

    // --- 请求核心 ---
    // 当前查询的 ParentId:下钻到子文件夹则用文件夹 id,否则库视图 id。
    function currentParentId() {
        return root.folderPath.length > 0
               ? root.folderPath[root.folderPath.length - 1].id
               : root.currentViewId
    }
    // 统一条目请求(筛选/排序随页面状态;startIndex=0 替换模型,>0 分页追加)。
    function fetchPage(startIndex) {
        if (!root.browseReady || root.currentViewId === "")
            return
        // 置 busy:首屏加载期间不显示"暂无条目"空提示(空提示条件 !busy),
        // 由 onItemsReceived/onErrorOccurred 清除。
        root.busy = true
        console.debug("Library: fetchPage", startIndex, "parent", root.currentParentId())
        const c = root.creds()
        EmbyClient.fetchItems(root.serverUrl, root.accountId, c.token, c.userId, root.currentParentId(),
                              startIndex, Constants.pageSize,
                              root.currentSortBy, root.currentSortOrder,
                              root.currentGenres, root.currentYears,
                              root.currentMinRating, root.currentFilter,
                              root.currentSearchTerm)
    }
    // 重拉条目 + 分类(类型/年份/子文件夹):切库与下钻时调用。
    function reloadAll() {
        if (!root.browseReady || root.currentViewId === "")
            return
        root.fetchPage(0)
        const c = root.creds()
        EmbyClient.fetchGenres(root.serverUrl, root.accountId, c.token, c.userId, root.currentParentId())
        EmbyClient.fetchYears(root.serverUrl, root.accountId, c.token, c.userId, root.currentParentId())
        EmbyClient.fetchFolders(root.serverUrl, root.accountId, c.token, c.userId, root.currentParentId())
    }
    // 筛选变化:仅重拉条目第一页(分类栏本身不变)。
    function refetch() {
        root.fetchPage(0)
    }

    // --- 筛选与下钻 ---
    // 重置全部筛选(切库/进文件夹时),筛选面板计数自动归零。
    // 注意:不清 folderPath——下钻路径由 enterFolder/goToLevel 各自
    // 维护,仅切库(applyView/onActivated)显式清空。
    function resetFilters() {
        root.currentGenres = ""
        root.currentYears = ""
        root.currentMinRating = ""
        root.currentFilter = ""
    }
    // 进入子文件夹:下钻一层,重置筛选并按新 ParentId 重拉四件套。
    function enterFolder(id, name) {
        let p = root.folderPath.slice()
        p.push({ id: id, name: name })
        root.folderPath = p
        root.resetFilters()
        root.reloadAll()
    }
    // 跳回第 i 层(0-based;该段成为当前层,其后截断)。
    // 头部面包屑点击任意上级段调用;i=-1 即回库根。
    function goToLevel(i) {
        if (i < -1 || i >= root.folderPath.length)
            return
        let p = i < 0 ? [] : root.folderPath.slice(0, i + 1)
        root.folderPath = p
        root.resetFilters()
        root.reloadAll()
    }
    // 当前分类模型中是否含指定类型名(切换库/文件夹后清失效选中)。
    function gmContains(name) {
        for (let i = 0; i < root.gm.count; ++i) {
            if (root.gm.nameAt(i) === name)
                return true
        }
        return false
    }

    // --- 交互入口 ---
    // 选中媒体库并加载条目:优先匹配 preferredId,未匹配(视图未就绪/不存在)
    // 回退第一个;视图未就绪时保持待选,onViewsReceived 到达后再应用。
    // 切换库即重置全部筛选与下钻路径,分类栏随新库重拉。
    function applyView(preferredId) {
        if (!root.vm || root.vm.count === 0)
            return
        let idx = 0
        for (let i = 0; i < root.vm.count; ++i) {
            if (root.vm.idAt(i) === preferredId) {
                idx = i
                break
            }
        }
        root.currentViewId = root.vm.idAt(idx)
        root.currentViewName = root.vm.nameAt(idx)
        root.folderPath = []
        root.resetFilters()
        root.reloadAll()
    }
    // 切换排序:服务端重查第一页(无 SearchTerm 时 SortBy 生效)。
    function changeSort(sortBy) {
        root.currentSortBy = sortBy
        root.fetchPage(0)
    }
    // 播放结束(主窗口通知)后重拉当前库第一页:刷新已看/进度角标,
    // 恢复滚动位置(onItemsReceived 消费 pendingRestoreY)。
    function refreshAfterPlayback() {
        if (!root.browseReady || root.currentViewId === "")
            return
        root.pendingRestoreY = grid.contentY
        root.fetchPage(0)
    }

    // --- 生命周期 ---
    // 进入页面:有服务器则拉取;未指定时默认第一个有效账号;无账号则表单。
    Component.onCompleted: {
        // 面包屑媒体库段立即显示首页传入的库名(视图拉取前的等待期)。
        root.currentViewName = root.initialViewName
        if (root.serverUrl === "") {
            const accs = AccountManager.accounts
            for (const a of accs) {
                if (!AccountManager.accountVisible(a.id))
                    continue // 隐藏服务器不参与"未指定服务器"的默认选择
                if (AccountManager.credsForAccount(a.id).token !== "") {
                    root.serverUrl = a.serverUrl
                    root.accountId = a.id
                    break
                }
            }
        }
        if (root.browseReady) {
            root.vm = EmbyClient.viewsModelFor(root.serverUrl, root.accountId)
            root.im = EmbyClient.itemsModelFor(root.serverUrl, root.accountId)
            root.gm = EmbyClient.genresModelFor(root.serverUrl, root.accountId)
            root.fm = EmbyClient.foldersModelFor(root.serverUrl, root.accountId)
            // 无状态化后视图不会预载,主动拉取(onViewsReceived 后应用目标库)。
            const c = root.creds()
            // 置 busy:fetchViews 返回前视图未就绪、applyView 尚未执行,
            // 此时 busy 若为 false,加载期间会误显"该媒体库暂无条目"空提示
            // (空提示条件 !busy)。清除由 onViewsReceived → applyView →
            // fetchPage(置 busy 保持)或 onErrorOccurred 负责。
            root.busy = true
            EmbyClient.fetchViews(root.serverUrl, root.accountId, c.token, c.userId)
            if (root.restore && root.restore.viewId !== "") {
                // 恢复上次浏览状态:视图/排序/滚动位置,重拉后定位。
                root.currentSortBy = root.restore.sortBy
                root.currentSortOrder = root.restore.sortOrder
                for (let i = 0; i < sortOptions.count; ++i) {
                    if (sortOptions.get(i).key === root.restore.sortBy) {
                        sortSelector.currentIndex = i
                        break
                    }
                }
                root.pendingRestoreY = root.restore.contentY || 0
                root.applyView(root.restore.viewId)
            } else {
                // 无恢复状态:按配置默认排序(非默认值时下拉须同步到对应档位)。
                root.applyView(root.initialViewId)
                for (let i = 0; i < sortOptions.count; ++i) {
                    if (sortOptions.get(i).key === root.currentSortBy) {
                        sortSelector.currentIndex = i
                        break
                    }
                }
            }
        } else {
            // 无账号/凭据失效:页面不可浏览,账号由主界面(ServerManager)管理,
            // 此处无直连表单(旧框架残留已移除)。
        }
    }
    // 离开页面(pop 销毁)前保存浏览状态:视图/排序/滚动位置。
    Component.onDestruction: {
        if (root.currentViewId !== "")
            root.libraryStateSaved({
                viewId: root.currentViewId,
                sortBy: root.currentSortBy,
                sortOrder: root.currentSortOrder,
                contentY: grid.contentY
            })
    }

    // ============================= 界面 =============================

    // 文本宽度度量(popup 自适应宽度:垂直 ListView 不计算 contentWidth,
    // 需按模型最长项文本宽计算)。
    FontMetrics {
        id: fmMetrics
        font.pixelSize: 16
    }

    // --- 聚合筛选面板(FilterPanel)数据 ---
    // 已激活筛选维度数(按钮计数徽标:"筛选 · N")。
    property int filterCount: (root.currentGenres !== "" ? 1 : 0)
                              + (root.currentYears !== "" ? 1 : 0)
                              + (root.currentMinRating !== "" ? 1 : 0)
                              + (root.currentFilter !== "" ? 1 : 0)
    // 评分下限档(MinCommunityRating 服务端参数值,固定档位;
    // 大的在前,常用高门槛优先)。
    ListModel {
        id: ratingFilterModel
        ListElement { label: "不限"; value: "" }
        ListElement { label: "≥ 9"; value: "9" }
        ListElement { label: "≥ 8"; value: "8" }
        ListElement { label: "≥ 7"; value: "7" }
        ListElement { label: "≥ 6"; value: "6" }
    }
    // 观看状态过滤(Filters 服务端参数值)。
    ListModel {
        id: statusFilterModel
        ListElement { label: "全部"; value: "" }
        ListElement { label: "未看"; value: "IsUnplayed" }
        ListElement { label: "已看"; value: "IsPlayed" }
        ListElement { label: "收藏"; value: "IsFavorite" }
        ListElement { label: "继续观看"; value: "IsResumable" }
    }
    // 类型分面模型(动态,onGenresReceived 填充;"全部类型"首项)。
    ListModel {
        id: genreFilterModel
        ListElement { label: "全部类型"; value: "" }
    }
    // 面板四节固定渲染(见 FilterPanel contentItem):类型/评分/状态
    // 选项单选,年份输入区间。选中态绑定 root 的 QML 属性,天然可追踪。
    // 年份区间展示:currentYears(逗号列表) ↔ "起始-终止" 输入串。
    function yearInputText() {
        if (root.currentYears === "")
            return ""
        const ys = root.currentYears.split(",").map((s) => parseInt(s, 10))
        return Math.min(...ys) + "-" + Math.max(...ys)
    }
    // 解析 "1999-2002" → currentYears = "1999,2000,2001,2002"(枚举区间
    // 内所有年份,逗号拼接;Years 多值 OR 语义 = 区间,与预期一致)。
    // 空串 = 清空(恢复全部年份);非法输入(非年份/起>止/越界)忽略。
    function applyYearRange(text) {
        if (/^\s*$/.test(text)) {
            root.currentYears = ""
            root.refetch()
            return
        }
        const m = /^\s*(\d{4})\s*[-–—]+\s*(\d{4})\s*$/.exec(text)
        if (!m)
            return
        const a = parseInt(m[1], 10)
        const b = parseInt(m[2], 10)
        if (a < 1900 || b > 2100 || a > b)
            return
        const list = []
        for (let y = a; y <= b; ++y)
            list.push(String(y))
        root.currentYears = list.join(",")
        root.refetch()
    }
    // 面板内最长文本宽(popup 宽度下限;垂直 Flickable 不计算 contentWidth)。
    function maxFilterTextWidth() {
        let w = 0
        for (const m of [genreFilterModel, ratingFilterModel, statusFilterModel]) {
            for (let i = 0; m && i < m.count; ++i) {
                const l = m.get(i).label
                if (l)
                    w = Math.max(w, fmMetrics.advanceWidth(l))
            }
        }
        return w
    }

    // --- 头部单行:面包屑链(左)+ 搜索栏(中)+ 筛选控件(右) ---
    // 搜索栏 x 经 clamp 居中:宽窗严格居中;窄窗被两侧内容夹住(右侧
    // 筛选组优先,链随窗截断)。链宽 = 搜索栏左缘,超长 clip 截断。
    Item {
        id: headerRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: 24
        anchors.rightMargin: 24
        anchors.topMargin: 24
        height: 42
        visible: root.browseReady

        // 可见返回钮(面包屑链行首):鼠标路径返回。
        BackCircleButton {
            id: libBackBtn
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
        }
        // 面包屑链(扁平文本式):服务器 / 库名 ▾ / 文件夹 ▾。
        // 服务器段点击 = 回首页并注入该服显示名到首页过滤框(与管理页卡片同机制);
        // 库名段下拉带模糊搜索;文件夹段下拉 = 缩进祖先链 + 当前层子文件夹
        // (纯缩进表意,无引导线;当前层高亮)。
        Row {
            id: crumbChain
            anchors.left: libBackBtn.right
            anchors.leftMargin: 10
            anchors.right: searchBox.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            clip: true

            // 段按钮:透明底,hover tint 圆角片;当前段 accent 加粗。
            component CrumbSeg: Item {
                id: seg
                property alias text: segText.text
                property bool arrow: false
                property bool current: false
                property alias hovered: segMa.containsMouse
                signal clicked()
                width: Math.min(segText.implicitWidth + (seg.arrow ? 18 : 0) + 16, 220)
                height: 30
                Rectangle {
                    anchors.fill: parent
                    radius: 6
                    // 只动 opacity:ColorAnimation 在 transparent(0,0,0,0)↔tint 间
                    // 插值会扫过暗色中间带(观感=颜色变两次)。
                    color: Theme.tint
                    opacity: seg.hovered ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 100 } }
                }
                AppText {
                    id: segText
                    anchors.left: parent.left
                    anchors.leftMargin: 8
                    anchors.right: parent.right
                    anchors.rightMargin: 8 + (seg.arrow ? 14 : 0)
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: 15
                    font.bold: seg.current
                    color: seg.current ? Theme.accent : Theme.textPrimary
                    elide: Text.ElideRight
                }
                AppText {
                    visible: seg.arrow
                    anchors.right: parent.right
                    anchors.rightMargin: 7
                    anchors.verticalCenter: parent.verticalCenter
                    text: "▾"
                    font.pixelSize: 11
                    color: Theme.textMuted
                }
                MouseArea {
                    id: segMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: seg.clicked()
                }
            }
            component CrumbSep: AppText {
                text: "/"
                color: Theme.textMuted
                font.pixelSize: 13
                height: 30
                verticalAlignment: Text.AlignVCenter
            }

            CrumbSeg {
                text: root.serverLabel()
                onClicked: root.browseHome(root.serverLabel())
            }
            CrumbSep {}
            CrumbSeg {
                id: viewSeg
                text: root.currentViewName
                arrow: true
                current: root.folderPath.length === 0
                onClicked: viewPopup.opened ? viewPopup.close() : viewPopup.open()
            }
            // 文件夹段常驻:库根时显示"全部",是根层下钻的唯一入口
            // (网格委托点文件夹卡走详情不下钻)。
            CrumbSep { visible: folderSeg.visible }
            CrumbSeg {
                id: folderSeg
                visible: root.folderPath.length > 0 || (root.fm ? root.fm.count > 0 : false)
                text: root.folderPath.length > 0
                      ? root.folderPath[root.folderPath.length - 1].name : "全部"
                arrow: true
                current: root.folderPath.length > 0
                onClicked: folderPopup.opened ? folderPopup.close() : folderPopup.open()
            }
        }

        // 媒体库下拉:顶部模糊搜索(FuzzyMatch 含拼音)+ 库列表,当前项高亮;
        // 回车 = 首个匹配。Popup.Item 模式(场景内 overlay,宽度同帧生效)。
        Popup {
            id: viewPopup
            parent: viewSeg
            popupType: Popup.Item
            y: parent.height + 6
            width: 260
            padding: 8
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
            enter: Transition {
                NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 120 }
            }
            exit: Transition {
                NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 120 }
            }
            background: Rectangle {
                color: Qt.rgba(Theme.scrim.r, Theme.scrim.g, Theme.scrim.b, 0.78)
                radius: 8
                border.width: 1
                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
            }
            onOpened: {
                viewSearch.text = ""
                viewList.model = root.filteredViews("")
                viewFocusTimer.start()
            }
            Timer {
                id: viewFocusTimer
                interval: 60
                onTriggered: viewSearch.forceActiveFocus()
            }
            contentItem: Column {
                spacing: 6
                TextField {
                    id: viewSearch
                    width: parent.width
                    height: 30
                    leftPadding: 10
                    rightPadding: 10
                    placeholderText: "搜索媒体库"
                    placeholderTextColor: Theme.textMuted
                    color: Theme.textPrimary
                    font.pixelSize: 13
                    selectByMouse: true
                    background: Rectangle {
                        radius: 6
                        color: ThemeStore.isLight ? Qt.rgba(0, 0, 0, 0.06)
                                                  : Qt.rgba(0, 0, 0, 0.25)
                        border.width: 1
                        border.color: viewSearch.activeFocus
                                      ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55)
                                      : Theme.borderSoft
                    }
                    onTextChanged: if (viewPopup.opened) viewList.model = root.filteredViews(text)
                    Keys.onEscapePressed: viewPopup.close()
                    onAccepted: {
                        const rows = root.filteredViews(text)
                        if (rows.length > 0)
                            root.selectView(rows[0].id)
                        viewPopup.close()
                    }
                }
                ListView {
                    id: viewList
                    width: parent.width
                    height: Math.min(contentHeight, 252)
                    // Popup 按 contentItem 隐高定尺寸,Flickable 隐高默认 0(弹层会只剩 padding)。
                    implicitHeight: contentHeight
                    clip: true
                    // 命令式赋值(非活绑定):页面销毁中途活绑定重算会读半死
                    // 对象(setModel→DelegateModel 读 NULL 崩溃)。
                    model: []
                    delegate: ItemDelegate {
                        required property var modelData
                        width: viewList.width
                        height: 32
                        padding: 0
                        contentItem: Item {
                            AppText {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.right: dot.left
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.name
                                font.pixelSize: 14
                                elide: Text.ElideRight
                            }
                            Rectangle {
                                id: dot
                                anchors.right: parent.right
                                anchors.rightMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                width: 6
                                height: 6
                                radius: 3
                                color: Theme.accent
                                visible: root.currentViewId === modelData.id
                            }
                        }
                        background: Rectangle {
                            radius: 4
                            color: parent.hovered
                                ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                                : "transparent"
                        }
                        onClicked: {
                            root.selectView(modelData.id)
                            viewPopup.close()
                        }
                    }
                }
            }
        }

        // 文件夹下拉:缩进树(库根 → 祖先链 → 当前层子文件夹)。
        // 当前层高亮;点库根/祖先 = 跳回该层,点子文件夹 = 下钻。
        Popup {
            id: folderPopup
            onAboutToShow: folderList.model = root.folderTreeRows()
            parent: folderSeg
            popupType: Popup.Item
            y: parent.height + 6
            width: 260
            padding: 8
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
            enter: Transition {
                NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 120 }
            }
            exit: Transition {
                NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 120 }
            }
            background: Rectangle {
                color: Qt.rgba(Theme.scrim.r, Theme.scrim.g, Theme.scrim.b, 0.78)
                radius: 8
                border.width: 1
                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
            }
            contentItem: ListView {
                id: folderList
                width: parent.width
                height: Math.min(contentHeight, 300)
                implicitHeight: contentHeight
                clip: true
                model: [] // 命令式赋值(同 viewList 注释)
                Component.onCompleted: model = root.folderTreeRows()
                delegate: ItemDelegate {
                    required property var modelData
                    width: folderList.width
                    height: 30
                    padding: 0
                    contentItem: Item {
                        AppText {
                            anchors.left: parent.left
                            anchors.leftMargin: 10 + modelData.level * 16
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.name
                            font.pixelSize: 14
                            font.bold: modelData.kind === "current"
                            color: modelData.kind === "current" ? Theme.accent : Theme.textPrimary
                            elide: Text.ElideRight
                        }
                    }
                    background: Rectangle {
                        radius: 4
                        color: parent.hovered
                            ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                            : "transparent"
                    }
                    onClicked: {
                        folderPopup.close()
                        if (modelData.kind === "root")
                            root.goToLevel(-1)
                        else if (modelData.kind === "child")
                            root.enterFolder(modelData.id, modelData.name)
                        else if (modelData.kind === "ancestor")
                            root.goToLevel(modelData.idx)
                        // kind === "current":本层,无需跳转
                    }
                }
            }
        }

        // 库内搜索栏(中):SearchTerm 与当前上下文(ParentId/筛选)正交,
        // 防抖 300ms 后重查第一页;清空(空串不传)恢复完整列表。
        TextField {
            id: searchBox
            y: (parent.height - height) / 2
            x: {
                const cx = (parent.width - width) / 2
                const lo = 160 + 12          // 左限:链最小可视区 + 间距
                const hi = parent.width - 12 - filterRow.width - width
                return Math.max(lo, Math.min(cx, hi))
            }
            // 基础宽度缩短,聚焦时通过宽度变化来强化视觉反馈。
            width: searchBox.activeFocus
                   ? (root.width > 1400 ? 420 : (root.width > 1150 ? 360 : 280))
                   : (root.width > 1400 ? 320 : (root.width > 1150 ? 260 : 200))
            height: 40
            Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.InOutQuad } }
            leftPadding: 34
            rightPadding: 12
            placeholderText: "搜索当前媒体库…"
            placeholderTextColor: ThemeStore.isLight ? Theme.textMuted
                                                     : Qt.lighter(Theme.textMuted, 1.2)
            color: Theme.textPrimary
            font.pixelSize: 14
            background: Rectangle {
                radius: 20
                color: root.crumb
                border.color: searchBox.activeFocus ? Theme.accent : Theme.textMuted
                border.width: 1
            }
            onTextChanged: searchDebounce.restart()
            // 防抖:停止输入 300ms 后才重查(与全局搜索浮层同阈值)。
            Timer {
                id: searchDebounce
                interval: Constants.searchDebounceMs
                onTriggered: {
                    const t = searchBox.text.trim()
                    if (t === root.currentSearchTerm)
                        return
                    root.currentSearchTerm = t
                    root.fetchPage(0)
                }
            }
        }

        // 筛选控件组(右):聚合筛选面板 + 排序 + 升降序(类型/年份/评分/
        // 状态做进一个控件,激活计数徽标);搜索激活时排序组置灰(服务端
        // 固定相关度排序)。
        Row {
            id: filterRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10

            // 状态/错误提示:已加载计数或失败信息,集成在顶部栏右侧。
            AppText {
                id: statusText
                anchors.verticalCenter: parent.verticalCenter
                property bool isError: false
                text: ""
                color: statusText.isError ? Theme.danger : Theme.textMuted
                font.pixelSize: 12
                visible: text !== ""
                rightPadding: 6
            }

            // 筛选:四维单选聚合入口(面板内分面小节,onAboutToShow 刷新)。
            FilterPanel {
                activeCount: root.filterCount
            }
            // SortBy:服务端排序键下拉(与 fetchItems 默认一致,切换即重查)。
            // 搜索激活(有词)时服务端固定相关度排序,置灰禁用避免"选了
            // 不生效"的困惑。
            FilterCombo {
                id: sortSelector
                width: 110
                model: sortOptions
                textRole: "label"
                currentIndex: 1
                enabled: root.currentSearchTerm === ""
                opacity: root.currentSearchTerm === "" ? 1 : 0.5
                onActivated: function (index) {
                    root.changeSort(sortOptions.get(index).key)
                }
            }
            // SortOrder:仅升/降两态,单按钮切换。
            FilterChip {
                label: root.currentSortOrder === "Ascending" ? "↑ 升序" : "↓ 降序"
                active: true
                enabled: root.currentSearchTerm === ""
                opacity: root.currentSearchTerm === "" ? 1 : 0.5
                onClicked: {
                    root.currentSortOrder = (root.currentSortOrder === "Ascending")
                            ? "Descending" : "Ascending"
                    root.fetchPage(0)
                }
            }
        }
    }

    // --- 主体:选中媒体库的条目网格(填充头部以下空间) ---
    GridView {
        id: grid
        // 复用 cell 避免滚动时销毁/重建;cacheBuffer 预备离屏项减少抖动。
        reuseItems: true
        cacheBuffer: 800
        // 滚动到底部且还有未加载条目时,加载下一页(Emby 单页上限 200)。
        onAtYEndChanged: {
            if (!atYEnd)
                return
            if (root.currentViewId !== "" && root.im.count < root.im.totalCount && !root.busy) {
                root.busy = true
                root.fetchPage(root.im.count)
            }
        }
        visible: root.browseReady
        anchors.left: parent.left
        anchors.right: parent.right
        // 与分类栏保持间距(视觉分组)。
        anchors.top: headerRow.bottom
        anchors.topMargin: 24
        anchors.bottom: parent.bottom
        anchors.leftMargin: 24
        anchors.rightMargin: 24
        cellWidth: root.cellW
        cellHeight: root.cellH
        clip: true
        model: root.im
        keyNavigationEnabled: true
        activeFocusOnTab: true
        highlightFollowsCurrentItem: false

        // 空库提示。
        AppText {
            visible: root.im && root.im.count === 0 && !root.busy
            anchors.centerIn: parent
            text: "该媒体库暂无条目"
            color: Theme.textMuted
            font.pixelSize: 16
        }
        // 加载骨架:首屏数据未到前铺占位卡,避免转圈引起布局跳动。
        Flow {
            visible: root.busy && root.im && root.im.count === 0
            anchors.fill: parent
            // 首卡与真实网格对齐:delegate 卡居中于 cell,首卡 x = gap/2。
            leftPadding: Constants.cellGap / 2
            spacing: Constants.cellGap
            Repeater {
                model: 24
                Rectangle {
                    width: root.cardW
                    height: root.cardH
                    radius: 8
                    color: Theme.surface
                }
            }
        }
        BusyIndicator {
            anchors.centerIn: parent
            running: root.busy && grid.visible
        }
        delegate: Item {
            // 视图只注入 delegate **根** 的 model/index 上下文;根声明
            // required 让 qmllint 静态识别(官方 delegate 写法)。
            // PosterCard 是嵌套子项,其 required model/index 须经 parent
            // 引用根注入值——不能写 `model: model`:PosterCard 自身有
            // 同名 required 属性,绑定右值解析到自身(undefined)→
            // TypeError: Cannot read property 'id' of undefined。
            required property var model
            required property int index
            // GridView 按 cell 定位但不改 delegate 尺寸(官方文档示例
            // delegate 显式 width: grid.cellWidth; height: grid.cellHeight):
            // 根须铺满 cell,否则隐式 0×0。PosterCard 在 cell 内居中:
            // 卡两侧各留 gap/2 → 卡间距 = cellGap、行首尾留白对称
            // (左 24+8 = 右 24+8);直接左对齐会让行尾 gap 全留在右侧
            // (左 24、右 40)。
            width: grid.cellWidth
            height: grid.cellHeight
            // hover 放大卡置顶:PosterCard 是 cell 子项,自身 z 只在自己
            // cell 内排前,盖不过兄弟 cell;必须提升 delegate 根(cell)的
            // z(兄弟间比较),放大溢出才能正确覆盖相邻卡。
            z: card.hovered ? 2 : 0
            Keys.onReturnPressed: root.showDetail(model.id, model.posterId, model.name, root.serverUrl, root.accountId)
            Keys.onEnterPressed: root.showDetail(model.id, model.posterId, model.name, root.serverUrl, root.accountId)
            PosterCard {
                id: card
                anchors.centerIn: parent
                width: root.cardW
                height: root.cardH
                model: parent.model
                index: parent.index
                current: GridView.isCurrentItem
                onClicked: root.showDetail(model.id, model.posterId, model.name, root.serverUrl, root.accountId)
                onFavoriteRequested: function (id, fav) {
                    const c = root.creds()
                    EmbyClient.setFavorite(root.serverUrl, c.token, c.userId, id, fav)
                    root.im.setFavoriteById(id, fav)
                }
                onWatchedRequested: function (id, played) {
                    const c = root.creds()
                    EmbyClient.setWatched(root.serverUrl, c.token, c.userId, id, played)
                    root.im.setPlayedById(id, played)
                }
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
            }
        }
    }
    // 贴边滚动条:视图有内缩边距,attached 会随之内缩;
    // 条作页面级兄弟锚到窗口右缘,手动绑定驱动。
    MoeScrollBar {
        view: grid
        anchors.right: parent.right
        anchors.top: grid.top
        anchors.bottom: grid.bottom
    }


    // 回顶浮钮:滚动超过约一屏后出现在右下,点击平滑回顶。
    // 玻璃源 = grid(兄弟内容,不自采样);按钮固定、映射恒定 ⇒
    // liveCapture:false + 滚动事件驱动刷新。
    FrostedGlass {
        id: topBtn
        width: 40
        height: 40
        radius: 20
        anchors.right: parent.right
        anchors.rightMargin: 28
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 24
        blurSource: grid
        liveCapture: false
        blurRadius: 5
        thickness: 14
        visible: opacity > 0
        opacity: grid.contentY > grid.height * 0.8 ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }
        hoverGlow: topBtnArea.hovered ? 0.35 : 0.0
        onVisibleChanged: if (visible) refresh()
        NavGlyph {
            anchors.centerIn: parent
            dir: 2
            width: 16
            height: 16
        }
        MouseArea {
            id: topBtnArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                topAnim.stop()
                topAnim.start()
            }
        }
        NumberAnimation {
            id: topAnim
            target: grid
            property: "contentY"
            to: 0
            duration: 350
            easing.type: Easing.OutCubic
        }
    }
    Connections {
        target: grid
        function onContentYChanged() { if (topBtn.visible) topBtn.refresh() }
    }

    // ========================= 异步结果 =========================

    // 浏览结果:按服务器路由(仅处理本页服务器的响应)。
    Connections {
        target: EmbyClient
        function onViewsReceived(serverUrl, accountId) {
            if (serverUrl !== root.serverUrl || accountId !== root.accountId)
                return
            if (root.vm && root.vm.count > 0)
                root.applyView(root.initialViewId)
            // 注意:此处不设 busy=false——applyView → reloadAll → fetchPage
            // 已置 busy=true,由 onItemsReceived/onErrorOccurred 清除;
            // 曾在此清空导致加载期间 busy=false 误显"暂无条目"。
        }
        function onItemsReceived(serverUrl, accountId) {
            if (serverUrl !== root.serverUrl || accountId !== root.accountId)
                return
            statusText.text = "已加载 " + root.im.count + " / "
                              + root.im.totalCount + " 个条目"
            statusText.isError = false
            root.busy = false
            // 恢复浏览位置:重拉完成后定位到上次离开处(clamp 到可滚范围),
            // 后续触底自动补页。仅消费一次。
            if (root.pendingRestoreY > 0) {
                const y = Math.min(root.pendingRestoreY, grid.contentHeight - grid.height)
                if (y > 0)
                    grid.contentY = y
                root.pendingRestoreY = 0
            }
        }
        function onGenresReceived(serverUrl, accountId) {
            if (serverUrl !== root.serverUrl || accountId !== root.accountId)
                return
            // 同步类型分面模型(FilterPanel 用 ListModel;"全部类型"为首项)。
            genreFilterModel.clear()
            genreFilterModel.append({ label: "全部类型", value: "" })
            for (let i = 0; root.gm && i < root.gm.count; ++i)
                genreFilterModel.append({ label: root.gm.nameAt(i), value: root.gm.nameAt(i) })
            // 当前选中的类型不在新库/新文件夹分类中时清选(如切换媒体库)。
            if (root.currentGenres !== "" && root.gm
                    && root.gm.count > 0 && !root.gmContains(root.currentGenres)) {
                root.currentGenres = ""
            }
        }
        function onYearsReceived(serverUrl, accountId, names) {
            if (serverUrl !== root.serverUrl || accountId !== root.accountId)
                return
            // 过滤脏年份(nayo 返回 "1"),只用于区间有效性校验。
            const set = new Set()
            for (const n of names) {
                const y = parseInt(n, 10)
                if (y >= 1900 && y <= 2100)
                    set.add(String(y))
            }
            // 已选区间与库年份分面无交集时清选(切库/下钻后旧区间失效)。
            if (root.currentYears !== "") {
                const sel = root.currentYears.split(",")
                if (!sel.some((y) => set.has(y))) {
                    root.currentYears = ""
                    root.refetch()
                }
            }
        }
        function onErrorOccurred(serverUrl, message) {
            if (serverUrl !== root.serverUrl)
                return
            // 只处理本页请求的错误(message 以请求描述前缀开头)。首页聚合
            // (获取服务器信息/获取首页行)等其它请求的错误会在本页停留期间
            // 触发,显示会误导,且若落在 busy 等待窗口内会误清 busy 导致
            // "暂无条目"闪现。fetchServerViews 与本页 fetchViews 同端点同
            // 描述("获取媒体库视图"),失败同样说明视图拉取问题,予以保留。
            const ours = message.startsWith("获取媒体库视图")
                || message.startsWith("获取媒体库条目")
                || message.startsWith("获取类型分类")
                || message.startsWith("获取年份分类")
                || message.startsWith("获取子文件夹")
            if (!ours)
                return
            console.warn("Library: 页面请求失败", message, "on", root.serverUrl)
            root.busy = false
            statusText.text = "失败：" + message
            statusText.isError = true
        }
    }

    // 点击非输入区时搜索框失焦(Qt Quick 点击不自动转移键盘焦点):
    // 透明垫底层,z:-1 只接收未被上层控件消费的点击(网格空白/卡片
    // 间隙/头部空隙);仅搜索框聚焦时启用,不干扰其它交互。
    MouseArea {
        anchors.fill: parent
        z: -1
        enabled: searchBox.activeFocus
        onClicked: searchBox.focus = false
    }
}
