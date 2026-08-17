pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes
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
    // 上次离开时的浏览状态(viewId/排序/滚动位置),恢复用。
    property var restore: null
    // 首屏数据就绪后要恢复的滚动位置(恢复时 onItemsReceived 消费一次)。
    property real pendingRestoreY: 0

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
    // 类型单选(Genres 多值实测为 AND 语义,单选安全):Genre 名称。
    property string currentGenres: ""
    // 年份单选(Years 单值):年份字符串;空 = 全部年份。
    property string currentYear: ""
    // 评分下限(MinCommunityRating):"6".."9";空 = 不限。
    property string currentMinRating: ""
    // 状态过滤(Filters):""|IsUnplayed|IsPlayed|IsFavorite。
    property string currentFilter: ""
    // 子文件夹下钻路径(元素为文件夹 id;空数组 = 库根)。进文件夹 push,
    // 下钻路径(元素 {id, name},按层序;空=库根)。头部面包屑逐段显示,
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

    // --- chip 样式(与搜索浮窗一致) ---
    // 选中 chip 底色:accent 降饱和加深(大色块不用纯 accent)。
    readonly property color chipActive: Qt.hsla(Theme.accent.hslHue, 0.35, 0.30, 1.0)
    // 选中 chip 悬停:同色相提亮一档。
    readonly property color chipActiveHover: Qt.hsla(Theme.accent.hslHue, 0.35, 0.38, 1.0)
    // 文件夹面包屑段配色(surface 系渐进:上级暗 → 当前亮,均弱于媒体库 accent 段)。
    readonly property color crumb: Qt.hsla(Theme.surface.hslHue, 0.15, 0.17, 1.0)
    readonly property color crumbHover: Qt.hsla(Theme.surface.hslHue, 0.15, 0.22, 1.0)
    readonly property color crumbCurrent: Qt.hsla(Theme.surface.hslHue, 0.15, 0.26, 1.0)
    readonly property color crumbCurrentHover: Qt.hsla(Theme.surface.hslHue, 0.15, 0.31, 1.0)
    // 头部面包屑尖角水平长度(服名框右尖/媒体库框左缺口共用)。
    readonly property int bcTip: 14

    // ============================= 信号 =============================

    // 请求播放(携带完整播放地址/头/元数据)。
    signal playRequested(string url, var headers, var meta)
    // 点击条目进入详情页(携带所在服务器)。
    signal showDetail(string itemId, string posterId, string title, string serverUrl)
    // 离开页面时保存浏览状态(由主窗口存下,再次进入经 restore 恢复)。
    signal libraryStateSaved(var state)

    // ===================== 内部组件与数据 =====================

    // 分类筛选 chip(选中实心/未选描边,与搜索浮窗类型 chips 同风格)。
    component FilterChip: Button {
        property string label: ""
        property bool active: false

        height: 30
        // RowLayout 会用 implicitHeight 覆盖显式 height(Button 默认约 45px),
        // 声明 preferredHeight 让 Layout 容器按 30 布局;ListView 场景用显式 height。
        Layout.preferredHeight: 30
        padding: 14
        background: Rectangle {
            radius: 10
            color: parent.active
                   ? (parent.hovered ? root.chipActiveHover : root.chipActive)
                   : (parent.hovered ? Theme.surface : Theme.bg)
            border.width: parent.active ? 0 : 1
            border.color: parent.hovered ? Theme.textPrimary : Theme.textMuted
        }
        contentItem: AppText {
            text: label
            color: "white"
            font.pixelSize: 13
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    // 分类筛选下拉(年份/评分/状态):暗色圆角底(crumb 系,同面包屑配色),
    // hover 提亮;弹出层与面包屑下拉同款(暗色 surface/圆角/描边/
    // hover accent 高亮/选中圆点)。model 统一为 ListModel(label/value)。
    component FilterCombo: ComboBox {
        id: fcombo
        height: 30
        // 同 FilterChip:RowLayout 覆盖显式 height,声明 preferredHeight 保持 30。
        Layout.preferredHeight: 30
        padding: 0
        background: Rectangle {
            radius: 6
            color: fcombo.hovered ? root.crumbHover : root.crumb
            border.color: "transparent"
        }
        contentItem: Item {
            AppText {
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.right: fcomboArrow.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                text: fcombo.displayText
                color: "white"
                font.pixelSize: 13
                elide: Text.ElideRight
            }
            AppText {
                id: fcomboArrow
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: fcombo.popup.opened ? "▴" : "▾"
                color: "white"
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
                color: Theme.surface
                radius: 8
                border.color: Qt.rgba(Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 0.4)
                border.width: 1
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
                    color: "white"
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

    // 排序档位:label 展示,key 为 Emby SortBy 值(服务端排序,切了即重查)。
    // ListModel(而非 JS 对象数组):ComboBox model/textRole 官方标准模型。
    ListModel {
        id: sortOptions
        ListElement { label: "加入时间"; key: "DateCreated" }
        ListElement { label: "修改时间"; key: "DateModified" }
        ListElement { label: "上映日期"; key: "PremiereDate" }
        ListElement { label: "年份"; key: "ProductionYear" }
        ListElement { label: "评分"; key: "CommunityRating" }
        ListElement { label: "名称"; key: "SortName" }
    }

    // 头部面包屑标签形状(QtQuick.Shapes 矢量多边形,右向尖角 ▸):
    // leftNotch=false(服名)= 左直右尖五边形;
    // leftNotch=true(媒体库)= 左边缘保留竖边、中点向内凹 V 槽(顶点 x=tip)
    // + 右尖;服名尖角(凸 tip)插入槽内,仅余 2px 间隙,紧密咬合。
    // 用 Shape 而非 Canvas:属性绑定(fill/尺寸)由场景图自动重新三角化,
    // 无 Canvas 手动 requestPaint 的时序问题。ShapePath 自动闭合填充;
    // 末段落在槽顶点,leftNotch=false 时与左直边共线退化为五边形。
    component BreadcrumbShape: Shape {
        id: shape
        property color fillColor: "transparent"
        property color borderColor: "transparent"
        property bool leftNotch: false
        property int tip: root.bcTip

        ShapePath {
            fillColor: shape.fillColor
            strokeColor: shape.borderColor
            strokeWidth: 1
            joinStyle: ShapePath.MiterJoin
            startX: 0
            startY: 0
            PathLine { x: shape.width - shape.tip; y: 0 }
            PathLine { x: shape.width; y: shape.height / 2 }
            PathLine { x: shape.width - shape.tip; y: shape.height }
            PathLine { x: 0; y: shape.height }
            PathLine { x: shape.leftNotch ? shape.tip : 0; y: shape.height / 2}
        }
    }

    // ============================= 函数 =============================

    // --- 基础 ---
    // 该服务器凭据(账号缺失/失效返回空 map → 显示连接表单)。
    function creds() {
        return AccountManager.credsForServer(root.serverUrl)
    }
    // 服务器显示名:账号名/用户名,未匹配回退地址。
    function serverLabel() {
        const accs = AccountManager.accounts
        for (const a of accs)
            if (a.serverUrl === root.serverUrl)
                return a.name !== "" ? a.name : a.userName
        return root.serverUrl
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
        const c = root.creds()
        EmbyClient.fetchItems(root.serverUrl, c.token, c.userId, root.currentParentId(),
                              startIndex, Constants.pageSize,
                              root.currentSortBy, root.currentSortOrder,
                              root.currentGenres, root.currentYear,
                              root.currentMinRating, root.currentFilter)
    }
    // 重拉条目 + 分类(类型/年份/子文件夹):切库与下钻时调用。
    function reloadAll() {
        if (!root.browseReady || root.currentViewId === "")
            return
        root.fetchPage(0)
        const c = root.creds()
        EmbyClient.fetchGenres(root.serverUrl, c.token, c.userId, root.currentParentId())
        EmbyClient.fetchYears(root.serverUrl, c.token, c.userId, root.currentParentId())
        EmbyClient.fetchFolders(root.serverUrl, c.token, c.userId, root.currentParentId())
    }
    // 筛选变化:仅重拉条目第一页(分类栏本身不变)。
    function refetch() {
        root.fetchPage(0)
    }

    // --- 筛选与下钻 ---
    // 重置全部筛选(切库/进文件夹时),下拉同步回"全部"档。
    // 注意:不清 folderPath——下钻路径由 enterFolder/goToLevel 各自
    // 维护,仅切库(applyView/onActivated)显式清空。
    function resetFilters() {
        root.currentGenres = ""
        root.currentYear = ""
        root.currentMinRating = ""
        root.currentFilter = ""
        yearSelector.currentIndex = 0
        ratingSelector.currentIndex = 0
        filterSelector.currentIndex = 0
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
        viewSelector.currentIndex = idx
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
                if (AccountManager.credsForServer(a.serverUrl).token !== "") {
                    root.serverUrl = a.serverUrl
                    break
                }
            }
        }
        if (root.browseReady) {
            root.vm = EmbyClient.viewsModelFor(root.serverUrl)
            root.im = EmbyClient.itemsModelFor(root.serverUrl)
            root.gm = EmbyClient.genresModelFor(root.serverUrl)
            root.fm = EmbyClient.foldersModelFor(root.serverUrl)
            // 无状态化后视图不会预载,主动拉取(onViewsReceived 后应用目标库)。
            const c = root.creds()
            // 置 busy:fetchViews 返回前视图未就绪、applyView 尚未执行,
            // 此时 busy 若为 false,加载期间会误显"该媒体库暂无条目"空提示
            // (空提示条件 !busy)。清除由 onViewsReceived → applyView →
            // fetchPage(置 busy 保持)或 onErrorOccurred 负责。
            root.busy = true
            EmbyClient.fetchViews(root.serverUrl, c.token, c.userId)
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
        font.pixelSize: 13
    }
    // 子文件夹模型最长名文本宽(popup 宽度下限,防长名被截断)。
    function maxFolderTextWidth() {
        const m = root.fm
        let w = 0
        for (let i = 0; m && i < m.count; ++i) {
            const n = m.nameAt(i)
            if (n)
                w = Math.max(w, fmMetrics.advanceWidth(n))
        }
        return w
    }
    // 媒体库模型最长名文本宽(媒体库下拉同理)。
    function maxViewTextWidth() {
        const m = root.vm
        let w = 0
        for (let i = 0; m && i < m.count; ++i) {
            const n = m.nameAt(i)
            if (n)
                w = Math.max(w, fmMetrics.advanceWidth(n))
        }
        return w
    }

    // --- 头部:服名 + 媒体库选择 ---
    Column {
        id: headerCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 12
        padding: 24
        // 头部面包屑链(已连接时):[服名▸][媒体库▸][文件夹₁▸]…[当前文件夹▸]。
        // 各段自绘 Shape、显式尺寸,Row 负间距咬合(后段左缺口吞前段尖角,
        // 2px 重叠防接缝);媒体库段/当前文件夹段为透明交互层+暗色下拉。
        Row {
            visible: root.browseReady
            height: 34
            spacing: -root.bcTip + 2

            // 服名:左直右尖五边形(静态展示,宽度随文字自适应)。
            Item {
                id: serverTab
                width: serverTabLabel.implicitWidth + 16 + root.bcTip
                height: 34
                BreadcrumbShape {
                    anchors.fill: parent
                    fillColor: Theme.surface
                    borderColor: "transparent"
                }
                AppText {
                    id: serverTabLabel
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.serverLabel()
                    color: "white"
                    font.pixelSize: 13
                    elide: Text.ElideMiddle
                }
            }

            // 媒体库:左缺口右尖,点击弹下拉切库(选中态 accent 高亮)。
            // 宽度自适应:文字完整宽 + 左 16 + 间隔 6 + ▾ 宽 10 + ▾ 右距(尖角 14 + 4),
            // 最小 150 防初始空名/短名过窄;文字锚定到 ▾ 左侧,极端长名 elide 兜底。
            Item {
                id: viewTab
                width: Math.max(150, viewTabText.implicitWidth + 50)
                height: 34

                BreadcrumbShape {
                    id: viewTabShape
                    anchors.fill: parent
                    leftNotch: true
                    // Shape 属性绑定自动重绘,hover 提亮无需手动触发。
                    fillColor: viewSelector.hovered ? root.chipActiveHover : root.chipActive
                    borderColor: "transparent"
                }
                // 媒体库名:anchors.left+right 提供显式宽度(AlignHCenter 生效,
                // elide 生效);垂直用 anchors.verticalCenter 而非 fill——
                // Text 默认 AlignTop,fill 到容器会以顶部为基线导致文字偏下。
                AppText {
                    id: viewTabText
                    anchors.left: parent.left
                    anchors.leftMargin: 16
                    anchors.right: viewTabArrow.left
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.currentViewName
                    color: "white"
                    font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                }
                AppText {
                    id: viewTabArrow
                    anchors.right: parent.right
                    anchors.rightMargin: root.bcTip + 4
                    anchors.verticalCenter: parent.verticalCenter
                    text: viewSelector.popup.opened ? "▴" : "▾"
                    color: "white"
                    font.pixelSize: 10
                }
                // 透明交互层:整块可点击弹出下拉,hover 驱动形状提亮。
                ComboBox {
                    id: viewSelector
                    anchors.fill: parent
                    padding: 0
                    background: null
                    contentItem: null
                    indicator: null
                    model: root.vm
                    textRole: "name"
                    // 弹出列表项:与面包屑两段同文字风格(白字 13px),
                    // 悬停半透明 accent 高亮,当前选中项右侧 accent 圆点。
                    delegate: ItemDelegate {
                        // Qt6 delegate 上下文(Bound 模式):index 与 model 均须
                        // required 声明;contentItem 委托作用域独立,经根属性转发。
                        required property int index
                        required property var model
                        property string itemText: model[viewSelector.textRole]
                        width: ListView.view.width
                        height: 32
                        padding: 0
                        contentItem: Item {
                            AppText {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: parent.parent.itemText
                                color: "white"
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
                                visible: viewSelector.currentIndex === parent.parent.index
                            }
                        }
                        highlighted: viewSelector.highlightedIndex === index
                        background: Rectangle {
                            radius: 4
                            color: parent.highlighted || parent.hovered
                                ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                                : "transparent"
                        }
                    }
                    // 弹出层:暗色 surface 底 + 描边,与服名框同底色同描边语言,
                    // 替换 QQC2 默认浅色弹出列表。
                    popup: Popup {
                        id: viewPopup
                        y: viewSelector.height + 4
                        // 自适应宽度:max(段宽, 最长库名文本宽 + 32),上限防超窗口。
                        // opened 依赖:JS 函数体内访问的模型内容不建立绑定依赖,
                        // 每次打开时按当前层最长名重算(下钻后 fm 已更新)。
                        width: opened
                               ? Math.min(root.width - 48,
                                          Math.max(viewSelector.width, root.maxViewTextWidth() + 32))
                               : viewSelector.width
                        implicitHeight: contentItem.implicitHeight
                        padding: 6
                        enter: Transition {
                            NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 120 }
                        }
                        exit: Transition {
                            NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 120 }
                        }
                        background: Rectangle {
                            color: Theme.surface
                            radius: 8
                            border.color: Qt.rgba(Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 0.4)
                            border.width: 1
                        }
                        contentItem: ListView {
                            clip: true
                            implicitHeight: contentHeight
                            model: viewSelector.delegateModel
                            currentIndex: viewSelector.highlightedIndex
                            highlightMoveDuration: 0
                        }
                    }
                    onActivated: function (index) {
                        if (root.currentViewId === root.vm.idAt(index))
                            return
                        root.currentViewId = root.vm.idAt(index)
                        root.folderPath = []
                        root.resetFilters()
                        root.reloadAll()
                    }
                }
            }

            // 文件夹层级段(Repeater,model = 库根段 + folderPath 各层):
            // 库根段("全部")常驻链首——未下钻时是当前段(弹顶层子文件夹),
            // 下钻后变为回根入口;上级段点击跳回该层(goToLevel),
            // 当前段点击弹该层子文件夹下拉。段数随层级动态增减。
            Repeater {
                model: [{ id: root.currentViewId, name: "全部" }]
                       .concat(root.folderPath)
                delegate: Item {
                    // Qt6 delegate 上下文(Bound 模式):required 声明注入属性。
                    required property var modelData
                    required property int index
                    // model 下标比 folderPath 下标多 1(链首为库根段)。
                    property bool isCurrent: index === root.folderPath.length
                    width: isCurrent
                           ? Math.max(120, crumbText.implicitWidth + 50)
                           : crumbText.implicitWidth + 16 + root.bcTip + 8
                    height: 34

                    BreadcrumbShape {
                        anchors.fill: parent
                        leftNotch: true
                        fillColor: crumbBtn.hovered
                            ? (parent.isCurrent ? root.crumbCurrentHover : root.crumbHover)
                            : (parent.isCurrent ? root.crumbCurrent : root.crumb)
                        borderColor: "transparent"
                    }
                    AppText {
                        id: crumbText
                        anchors.left: parent.left
                        anchors.leftMargin: 16
                        anchors.right: parent.isCurrent ? crumbArrow.left : parent.right
                        anchors.rightMargin: parent.isCurrent ? 6 : 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.name
                        color: "white"
                        font.pixelSize: 13
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideMiddle
                    }
                    AppText {
                        id: crumbArrow
                        visible: parent.isCurrent
                        anchors.right: parent.right
                        anchors.rightMargin: root.bcTip + 4
                        anchors.verticalCenter: parent.verticalCenter
                        text: crumbPopup.opened ? "▴" : "▾"
                        color: "white"
                        font.pixelSize: 10
                    }
                    // 透明交互层:上级段点击跳回(库根段=回根),当前段点击弹子文件夹下拉。
                    MouseArea {
                        id: crumbBtn
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            if (parent.isCurrent) {
                                if (crumbPopup.opened)
                                    crumbPopup.close()
                                else
                                    crumbPopup.open()
                            } else if (index === 0) {
                                root.goToLevel(-1)
                            } else {
                                root.goToLevel(index - 1)
                            }
                        }
                    }
                    // 当前段弹出:该层子文件夹列表(与媒体库下拉同样式)。
                    Popup {
                        id: crumbPopup
                        y: parent.height + 4
                        // 自适应宽度:max(段宽, 最长子文件夹名文本宽 + 32),上限防超窗口。
                        // opened 依赖:每次打开时按当前层重算(见 viewPopup 注释)。
                        width: opened
                               ? Math.min(root.width - 48,
                                          Math.max(parent.width, root.maxFolderTextWidth() + 32))
                               : parent.width
                        implicitHeight: contentItem.implicitHeight
                        padding: 6
                        enter: Transition {
                            NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 120 }
                        }
                        exit: Transition {
                            NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 120 }
                        }
                        background: Rectangle {
                            color: Theme.surface
                            radius: 8
                            border.color: Qt.rgba(Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 0.4)
                            border.width: 1
                        }
                        contentItem: ListView {
                            clip: true
                            implicitHeight: contentHeight
                            model: root.fm
                            delegate: ItemDelegate {
                                required property int index
                                required property var model
                                property string itemText: model.name
                                width: ListView.view.width
                                height: 32
                                padding: 0
                                contentItem: Item {
                                    AppText {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: parent.parent.itemText
                                        color: "white"
                                        font.pixelSize: 13
                                        elide: Text.ElideRight
                                    }
                                }
                                highlighted: ListView.view.currentIndex === index
                                background: Rectangle {
                                    radius: 4
                                    color: parent.highlighted || parent.hovered
                                        ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                                        : "transparent"
                                }
                                onClicked: {
                                    root.enterFolder(model.id, model.name)
                                    crumbPopup.close()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // --- 分类栏(已连接时):子文件夹下钻 + 类型/年份/评分/状态筛选 ---
    Column {
        id: filterCol
        visible: root.browseReady
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: headerCol.bottom
        anchors.leftMargin: 24
        anchors.rightMargin: 24
        spacing: 8

        // 类型分类(Genres,横向滚动,单选;"全部类型"清选)。
        RowLayout {
            width: parent.width
            spacing: 8
            FilterChip {
                label: "全部类型"
                active: root.currentGenres === ""
                onClicked: {
                    if (root.currentGenres !== "") {
                        root.currentGenres = ""
                        root.refetch()
                    }
                }
            }
            ListView {
                Layout.fillWidth: true
                Layout.preferredHeight: 30
                orientation: ListView.Horizontal
                spacing: 8
                clip: true
                model: root.gm
                delegate: FilterChip {
                    required property string name
                    required property string id
                    label: name
                    active: root.currentGenres === name
                    onClicked: {
                        root.currentGenres = (root.currentGenres === name ? "" : name)
                        root.refetch()
                    }
                }
            }
        }

        // 筛选行:年份(服务端 Years 枚举)/评分下限/状态过滤 下拉(左)
        // + 排序(右):SortBy 下拉 + 升降序切换按钮(仅两态,无需下拉)。
        RowLayout {
            width: parent.width
            spacing: 12
            AppText {
                text: "年份"
                color: "white"
                font.pixelSize: 13
            }
            FilterCombo {
                id: yearSelector
                width: 130
                model: ListModel {
                    id: yearModel
                    ListElement { label: "全部年份"; value: "" }
                }
                textRole: "label"
                onActivated: function (index) {
                    root.currentYear = yearModel.get(index).value
                    root.refetch()
                }
            }
            AppText {
                text: "评分"
                color: "white"
                font.pixelSize: 13
            }
            FilterCombo {
                id: ratingSelector
                width: 110
                model: ListModel {
                    ListElement { label: "不限"; value: "" }
                    ListElement { label: "≥ 6"; value: "6" }
                    ListElement { label: "≥ 7"; value: "7" }
                    ListElement { label: "≥ 8"; value: "8" }
                    ListElement { label: "≥ 9"; value: "9" }
                }
                textRole: "label"
                onActivated: function (index) {
                    root.currentMinRating = ratingSelector.model.get(index).value
                    root.refetch()
                }
            }
            AppText {
                text: "状态"
                color: "white"
                font.pixelSize: 13
            }
            FilterCombo {
                id: filterSelector
                width: 110
                model: ListModel {
                    ListElement { label: "全部"; value: "" }
                    ListElement { label: "未看"; value: "IsUnplayed" }
                    ListElement { label: "已看"; value: "IsPlayed" }
                    ListElement { label: "收藏"; value: "IsFavorite" }
                }
                textRole: "label"
                onActivated: function (index) {
                    root.currentFilter = filterSelector.model.get(index).value
                    root.refetch()
                }
            }
            // 弹性空隙:排序区靠右。
            Item {
                Layout.fillWidth: true
            }
            AppText {
                text: "排序"
                color: "white"
                font.pixelSize: 13
            }
            // SortBy:服务端排序键下拉(与 fetchItems 默认一致,切换即重查)。
            FilterCombo {
                id: sortSelector
                width: 130
                model: sortOptions
                textRole: "label"
                currentIndex: 1
                onActivated: function (index) {
                    root.changeSort(sortOptions.get(index).key)
                }
            }
            // SortOrder:仅升/降两态,单按钮切换。
            FilterChip {
                label: root.currentSortOrder === "Ascending" ? "↑ 升序" : "↓ 降序"
                active: true
                onClicked: {
                    root.currentSortOrder = (root.currentSortOrder === "Ascending")
                            ? "Descending" : "Ascending"
                    root.fetchPage(0)
                }
            }
        }
    }

    // 状态/错误提示条(加载进度/请求失败):位于筛选行与网格之间,
    // 贴近内容区(浏览/筛选操作的视线焦点);空状态隐藏、零空间占用。
    // 样式:正常态透明底 textMuted 文字;错误态浅 danger 底 + 描边 + danger 文字。
    Item {
        id: statusBar
        anchors.left: parent.left
        anchors.leftMargin: 24
        anchors.right: parent.right
        anchors.rightMargin: 24
        anchors.top: filterCol.bottom
        height: statusText.text === "" ? 0 : 30
        visible: statusText.text !== ""
        Rectangle {
            anchors.fill: parent
            radius: 6
            color: statusText.isError
                   ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.12)
                   : "transparent"
            border.color: statusText.isError
                          ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.5)
                          : "transparent"
            border.width: 1
        }
        AppText {
            id: statusText
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            // 错误态显式状态,不嗅探文案(原 indexOf("失败") 脆弱)。
            property bool isError: false
            text: ""
            color: statusText.isError ? Theme.danger : Theme.textMuted
        }
    }

    // --- 主体:选中媒体库的条目网格(填充头部以下空间) ---
    GridView {
        id: grid
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
        anchors.top: statusBar.bottom
        anchors.topMargin: 12
        anchors.bottom: parent.bottom
        anchors.leftMargin: 24
        anchors.rightMargin: 24
        anchors.bottomMargin: 24
        cellWidth: Constants.cellW
        cellHeight: Constants.cellH
        clip: true
        model: root.im

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
            spacing: 16
            Repeater {
                model: 24
                Rectangle {
                    width: Constants.cardW
                    height: Constants.cardH
                    radius: 8
                    color: Theme.surface
                }
            }
        }
        BusyIndicator {
            anchors.centerIn: parent
            running: root.busy && grid.visible
        }
        delegate: PosterCard {
            onClicked: root.showDetail(model.id, model.posterId, model.name, root.serverUrl)
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
            width: Constants.cardW
            height: Constants.cardH
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

    // ========================= 异步结果 =========================

    // 浏览结果:按服务器路由(仅处理本页服务器的响应)。
    Connections {
        target: EmbyClient
        function onViewsReceived(serverUrl) {
            if (serverUrl !== root.serverUrl)
                return
            if (root.vm && root.vm.count > 0)
                root.applyView(root.initialViewId)
            // 注意:此处不设 busy=false——applyView → reloadAll → fetchPage
            // 已置 busy=true,由 onItemsReceived/onErrorOccurred 清除;
            // 曾在此清空导致加载期间 busy=false 误显"暂无条目"。
        }
        function onItemsReceived(serverUrl) {
            if (serverUrl !== root.serverUrl)
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
        function onGenresReceived(serverUrl) {
            if (serverUrl !== root.serverUrl)
                return
            // 类型 chips 自动随模型刷新;当前选中的类型不在新库/新文件夹
            // 分类中时清选(如切换媒体库)。
            if (root.currentGenres !== "" && root.gm
                    && root.gm.count > 0 && !root.gmContains(root.currentGenres)) {
                root.currentGenres = ""
            }
        }
        function onYearsReceived(serverUrl, names) {
            if (serverUrl !== root.serverUrl)
                return
            // 过滤脏年份(实测 nayo 返回 "1"),倒序展示;选中项失效则重置。
            let arr = []
            for (const n of names) {
                const y = parseInt(n, 10)
                if (y >= 1900 && y <= 2100)
                    arr.push(String(y))
            }
            arr.sort((a, b) => parseInt(b, 10) - parseInt(a, 10))
            // 同步下拉模型(FilterCombo 用 ListModel)。
            yearModel.clear()
            yearModel.append({ label: "全部年份", value: "" })
            for (const y of arr)
                yearModel.append({ label: y, value: y })
            if (root.currentYear !== "" && arr.indexOf(root.currentYear) < 0) {
                root.currentYear = ""
                root.refetch()
            }
            // 模型 clear+append 会重置 currentIndex(-1)导致 displayText 为空,
            // 显式恢复:未选年份回"全部年份",已选则定位回该年份。
            if (root.currentYear === "") {
                yearSelector.currentIndex = 0
            } else {
                for (let i = 1; i < yearModel.count; ++i)
                    if (yearModel.get(i).value === root.currentYear) {
                        yearSelector.currentIndex = i
                        break
                    }
            }
        }
        function onFoldersReceived(serverUrl) {
            if (serverUrl !== root.serverUrl)
                return
            // 当前段下拉的子文件夹列表随 fm 模型自动刷新,无额外动作。
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
            root.busy = false
            statusText.text = "失败：" + message
            statusText.isError = true
        }
    }
}
