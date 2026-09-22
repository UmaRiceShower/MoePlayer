pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import MoePlayer.Core

//! 首页:pageList Flickable+Column 精确高度滚动(hero + 媒体库卡条为首节);
//! 行壳高度由公式定死,卡片近视口才实例化;行内自适应网格。
//! 内容 = hero 轮播 + 每库网格行(条目卡铺满宽度,不横滚)。
Item {
    id: root

    // hero 轮播数据源:ListModel(原位 set/append/remove),不用 JS 数组——
    // 整块换数组会销毁重建全部委托、图片重新装载,视觉上"闪一下"。
    property var heroWant: []
    property double heroPendingSince: 0
    property int heroCenter: 0   // 当前中心索引镜像(根级函数读不到 header 里的 id)
    readonly property int heroKeepRadius: 1   // 前排除 = 当前中心 ±1(pathItemCount 3)
    property bool heroHovered: false            // heroHover 的镜像(见 HoverHandler)
    ListModel { id: heroModel }
    readonly property real navH: Constants.homeNavH
    // hero 高按应用宽度计算(横向海报比例):首页可滚动,视图高度不构成约束;
    // 窄窗随宽度收缩,卡片保持满带宽。
    // 用窗口宽度而非父宽:页面首帧布局时父宽度尚未赋值,避免首帧 0 高布局。
    readonly property real heroH: (root.Window && root.Window.width > 0
                                   ? root.Window.width : 1280) * Constants.homeHeroWidthRatio

    // ---- 行几何单一来源:委托高度与滚动条精确跨度同用这一套公式 ----
    readonly property int homeLines: Math.max(1, Math.min(5, ConfigManager.homeRowLines))
    function gridCols(rowW) {
        const gap = Constants.cellGap
        const availW = rowW - Constants.homeRowHoverPad
        // 列数按卡宽下限取(保 minW),超上限时 +1 列回收
        let n = Math.max(1, Math.floor((availW + gap) / (Constants.rowCardMinW + gap)))
        let w = (availW - (n - 1) * gap) / n
        while (w > Constants.rowCardMaxW && n < 24) { n += 1; w = (availW - (n - 1) * gap) / n }
        return n
    }
    function gridCardW(rowW) {
        return (rowW - Constants.homeRowHoverPad) / gridCols(rowW) - Constants.cellGap
    }
    function gridVPad(cardH) {
        // hover 放大溢出(卡高×3%)+ 光晕外探(2.5×1.06)+ 1px 余量
        return Math.ceil(cardH * 0.03 + 2.5 * 1.06 + 1)
    }
    function gridShownLines(itemCount, rowW) {
        const cols = gridCols(rowW)
        return Math.max(1, Math.ceil(Math.min(itemCount, homeLines * cols) / cols))
    }

    signal showDetail(string itemId, string posterId, string title, string serverUrl, string accountId)
    signal openLibrary(string viewId, string serverUrl, string viewName, string accountId)
    signal openServerManager()
    signal openSettings()
    signal openSearch()
    signal openHistory()

    // 媒体库过滤(「媒体库」标题右侧输入框):模糊子序列 + 拼音(全拼/简拼
    // 连续子串,见 FuzzyMatch),本地即时过滤不防抖;未命中的库卡折叠为 0 宽
    // (不重建委托、不重载图片)。匹配对象 = 库名 + 服务器名。
    // 注意:库行不做折叠 —— 条件行高叠加 reuseItems 与模型增量更新会让
    // ListView 重建离屏高度缓存(全量孵化行委托,阻塞 GUI ~600ms)。
    property string libFilter: ""
    function libMatch(row) {
        const q = root.libFilter.trim()
        if (q === "")
            return true
        return FuzzyMatch.hit(q, row.viewName || "") || FuzzyMatch.hit(q, row.serverName || "")
    }
    // 聚合 hero 轮播数据:优先服务器建议(/Suggestions),按建议顺序展示;
    // 建议未到/为空时回退本地聚合(继续观看优先,不足补最新添加)。
    // ---- hero 同步:缓存先展示,后台数据到达后原位替换 ----
    // 前排除(正在看的三张)不改内容:改动先挂起,轮播走开后再落;挂起超过
    // homeHeroPendingMaxMs 兜底强落(列表 ≤ 3 时轮播不会把任何一张移出前排)。
    function heroKey(it) {
        return (it.serverUrl || "") + "|" + (it.id || "")
    }
    function heroRowSame(i, it) {
        return i >= 0 && i < heroModel.count && heroKey(heroModel.get(i)) === heroKey(it)
    }
    function heroVisible(i) {
        const n = heroModel.count
        if (n <= 0)
            return false
        const d = Math.abs(i - root.heroCenter)
        return Math.min(d, n - d) <= root.heroKeepRadius   // 轮播是环形推进,按环距算
    }
    // force=false:只落非前排;true:连前排一起落(轮播走开或超时兜底)。
    function flushHero(force) {
        const want = root.heroWant
        let blocked = false
        for (let i = 0; i < want.length; ++i) {
            if (root.heroRowSame(i, want[i]))
                continue
            if (!force && root.heroVisible(i)) {
                blocked = true
                continue
            }
            if (i < heroModel.count)
                heroModel.set(i, want[i])
            else
                heroModel.append(want[i])
        }
        while (heroModel.count > want.length) {
            const last = heroModel.count - 1
            if (!force && root.heroVisible(last)) {
                blocked = true
                break
            }
            heroModel.remove(last)
        }
        if (!blocked) {
            root.heroPendingSince = 0
            return
        }
        if (root.heroPendingSince === 0)
            root.heroPendingSince = Date.now()
        else if (Date.now() - root.heroPendingSince > Constants.homeHeroPendingMaxMs
                 && !root.heroHovered
                 && heroModel.count <= root.heroKeepRadius * 2 + 1)
            root.flushHero(true)
    }
    // 角色归一化:ListModel 的角色集由首次 append 定型,而 set() 只覆盖传入的键 ——
    // 缺字段的条目会让该槽位残留上一条的旧值(旧背景图/旧进度不换)。按"键并集 +
    // 默认值"补齐(兜底聚合条目与服务器建议条目的字段集本来就不一样)。
    readonly property var heroRoleDefaults: ({
        "id": "", "name": "", "backdropId": "", "parentBackdropId": "", "posterId": "",
        "year": 0, "serverUrl": "", "accountId": ""
    })
    function heroRows(items) {
        const keys = {}
        for (const k in root.heroRoleDefaults)
            keys[k] = true
        for (let i = 0; i < items.length; ++i)
            for (const k in items[i])
                keys[k] = true
        const out = []
        for (let i = 0; i < items.length; ++i) {
            const row = {}
            for (const k in keys) {
                const v = items[i][k]
                row[k] = (v === undefined || v === null)
                         ? (root.heroRoleDefaults[k] !== undefined ? root.heroRoleDefaults[k] : "")
                         : v
            }
            out.push(row)
        }
        return out
    }

    // 挂起期间每秒自查一次:强落的时限判定只在 flushHero 被调用时生效,而轮播
    // 停摆(列表 ≤ 中心 ±1 全覆盖,如只有 1 条)时没人再调用它 ⇒ 内容永远不更新。
    Timer {
        interval: 1000
        running: root.heroPendingSince > 0
        repeat: true
        onTriggered: root.flushHero(false)
    }

    function syncHero(items) {
        root.heroWant = root.heroRows(items)
        if (heroModel.count === 0) {
            for (let i = 0; i < root.heroWant.length; ++i)
                heroModel.append(root.heroWant[i])
            return
        }
        root.flushHero(false)
    }


    // ---- 过滤(顶栏过滤框:服务器/媒体库一体) ----
    // 服务器管理页点卡片注入:Main.homeFilterText 写入(账号显示名)后
    // 此处消费进过滤框,消费即清(同名再点能再触发)。
    property string filterInject: ApplicationWindow.window ? ApplicationWindow.window.homeFilterText : ""
    // 非激活态(上方压着其他页)收到注入先挂起,待页面重新激活(转场结束)
    // 再写入过滤框:写入会连动整页 refilter/rebuildTop,不落在被压住的页面上。
    property string _pendingInject: ""
    onFilterInjectChanged: {
        if (root.filterInject === "")
            return
        root._pendingInject = root.filterInject
        // 清空挪出本 notify 级联:filterInject 绑定读 window.homeFilterText,
        // 同步清空 = 在自身 notify 里重赋值源,Binding loop 告警。
        Qt.callLater(function () { ApplicationWindow.window.homeFilterText = "" })
        if (root.StackView.status === StackView.Active)
            root._applyInject()
    }
    // 注入结算定时器:转场时长(230ms)之上取整。
    Timer {
        id: injectTimer
        interval: 400
        repeat: false
        onTriggered: root._applyInject()
    }
    function _applyInject() {
        if (root._pendingInject === "")
            return
        filterField.text = root._pendingInject
        root._pendingInject = ""
    }

    // pageList 恒定绑定代理模型(永不切换对象):过滤谓词 = libMatch(JS 回调,
    // FuzzyMatch 单一真相源);空查询 = 谓词恒真透传。历史:旧实现按查询空否
    // 切换 model(C++↔JS 快照),切换瞬间 DelegateModel 读已释放对象概率性
    // 崩溃(多轮复现矩阵实证,两步清池/关 reuseItems 均不能根除)。
    HomeRowsFilterModel {
        id: homeRowsFilter
        plainSource: AccountManager.homeRows
        customSource: AccountManager.customHomeRows
        customActive: ConfigManager.customLibrariesMode !== "off" && root.libFilter.trim() === ""
        filterPredicate: root.libMatch
        maxRows: ConfigManager.homeLibraryRows
        filtering: root.libFilter.trim() !== ""
    }
    onLibFilterChanged: {
        homeRowsFilter.refilter()
        root.rebuildTop()
    }

    // hero 跟随过滤的条件:查询命中某服名(媒体库名的查询不动推荐)。
    function heroFilterActive() {
        const q = root.libFilter.trim()
        if (q === "")
            return false
        const list = AccountManager.accounts
        for (let i = 0; i < list.length; ++i)
            if (FuzzyMatch.hit(q, list[i].name !== "" ? list[i].name : list[i].userName))
                return true
        return false
    }
    function heroServerHit(serverUrl, accountId) {
        const list = AccountManager.accounts
        for (let i = 0; i < list.length; ++i) {
            const a = list[i]
            if (a.serverUrl === serverUrl && a.id === accountId)
                return FuzzyMatch.hit(root.libFilter.trim(), a.name !== "" ? a.name : a.userName)
        }
        return false
    }
    // 服务器快选下拉选项:可见账号显示名,按当前过滤词模糊收窄。
    function serverPickOptions() {
        const q = root.libFilter.trim()
        const out = []
        const list = AccountManager.accounts
        for (let i = 0; i < list.length; ++i) {
            const a = list[i]
            if (!AccountManager.accountVisible(a.id))
                continue
            const nm = a.name !== "" ? a.name : a.userName
            if (q === "" || FuzzyMatch.hit(q, nm) || FuzzyMatch.hit(q, a.serverUrl))
                out.push(nm)
        }
        return out
    }
    // 多服(可见账号跨服务器)时媒体库卡片标注服名,单服无歧义不加。
    readonly property bool multiServer: {
        const list = AccountManager.accounts
        const seen = {}
        let n = 0
        for (let i = 0; i < list.length; ++i) {
            if (!AccountManager.accountVisible(list[i].id))
                continue
            const u = list[i].serverUrl
            if (!seen[u]) {
                seen[u] = true
                ++n
            }
        }
        return n > 1
    }

    // 页面被压栈(进详情/库/管理页)时收下拉里——Popup 挂在 Overlay 层,
    // 不收会悬在新页面上方。
    StackView.onStatusChanged: {
        if (StackView.status !== StackView.Active)
            serverPickPopup.close()
        else {
            // 延到转场结束后:pop 过渡期内旧页仍存活,过滤写入连动的
            // refilter/重建与旧页委托回收交错,等页面稳定后再落。
            injectTimer.start()
        }
    }

    function rebuildTop() {
        // 服务端已按 IncludeItemTypes=Movie,Series & ImageTypes=Backdrop 过滤
        // (4.9+ 版本门控,旧版跳过),此处只管截断显示条数。
        // 过滤框命中服名时,建议与兜底候选都只取该服;媒体库名查询不动 hero。
        const suggAll = AccountManager.suggestions
        const sugOk = root.heroFilterActive()
                      ? suggAll.filter(function (it) { return root.heroServerHit(it.serverUrl, it.accountId) })
                      : suggAll
        if (sugOk.length > 0) {
            root.syncHero(sugOk.slice(0, 10))
            return
        }
        const all = []
        const hm = AccountManager.homeRows
        for (let i = 0; i < hm.count; ++i) {
            const row = hm.rowAt(i)
            if (!root.libMatch(row))
                continue
            const sv = row.serverUrl || ""
            const aid = row.accountId || ""
            for (const it of (row.items || [])) {
                const m = Object.assign({}, it)
                m.serverUrl = sv
                m.accountId = aid
                all.push(m)
            }
        }
        const cw = all.filter(function (i) {
            return i.positionTicks > 0 && !i.played && i.runtimeTicks > 0
        })
        // 候选按行顺序取前 10:行内条目由服务器按 DateLastContentAdded 倒序返回。
        const cwTop = cw.slice(0, 10)
        root.syncHero(cwTop.length > 0 ? cwTop : all.slice(0, 10))
    }

    Component.onCompleted: {
        homeRowsFilter.refilter()
        if (AccountManager.hasAccounts) {
            AccountManager.validateTokens()
            AccountManager.fetchHomeRows(ConfigManager.homeLibraryLimit)
            AccountManager.fetchPlaybackHistory()
        }
    }

    // 行模型按行增量更新;此处仅重算 hero(从行模型读取)。
    Connections {
        target: AccountManager
        function onHomeRowsReady() {
            root.rebuildTop()
        }
        function onSuggestionsUpdated() {
            root.rebuildTop()
        }
    }

    // 顶部导航(固定)。
    Item {
        id: nav
        z: 10
        height: root.navH
        width: parent.width
        AppText {
            id: navTitle
            anchors.left: parent.left
            anchors.leftMargin: Constants.homeNavMarginL
            anchors.verticalCenter: parent.verticalCenter
            text: "MoePlayer"
            color: Theme.textPrimary
            font.pixelSize: Constants.homeNavTitlePx
            font.bold: true
        }
        // 过滤框(标题右):模糊过滤媒体库/服务器(拼音可),聚焦出服务器
        // 快选下拉(点服名填入框中,过滤即按服名命中);✕/Esc 清除;
        // 回车 = 进入首个命中库。
        TextField {
            id: filterField
            anchors.left: navTitle.right
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            width: 220
            height: 30
            leftPadding: 12
            rightPadding: 26
            placeholderText: "过滤服务器 / 媒体库…"
            placeholderTextColor: Theme.textMuted
            color: Theme.textPrimary
            font.pixelSize: 13
            selectByMouse: true
            background: Rectangle {
                radius: height / 2
                color: Qt.rgba(Theme.scrimSoft.r, Theme.scrimSoft.g, Theme.scrimSoft.b, 0.45)
                border.width: 1
                border.color: filterField.activeFocus
                              ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55)
                              : Theme.borderSoft
            }
            AppText {
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: "✕"
                visible: filterField.text !== ""
                color: filterClearHover.hovered ? Theme.textPrimary : Theme.textMuted
                font.pixelSize: 12
                HoverHandler { id: filterClearHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: filterField.text = "" }
            }
            onTextChanged: {
                root.libFilter = text
                if (serverPickPopup.visible)
                    serverPickList.model = root.serverPickOptions()
                // 编辑中保持下拉展开(点选关闭后再改词要能看到新匹配)。
                else if (activeFocus) {
                    serverPickList.model = root.serverPickOptions()
                    serverPickPopup.open()
                }
            }
            Keys.onEscapePressed: filterField.text = ""
            // 回车 = 进入首个命中库(与历史页"回车 = 激活首个匹配项"同约定)。
            onAccepted: {
                const n = AccountManager.homeRows.count
                for (let i = 0; i < n; ++i) {
                    const row = AccountManager.homeRows.rowAt(i)
                    if (root.libMatch(row)) {
                        root.openLibrary(row.viewId, row.serverUrl,
                                         row.viewName, row.accountId)
                        break
                    }
                }
            }
            // 失焦即收下拉(点框外任意处 → 全局失焦层清焦点 → 这里收口;
            // 点下拉项不收焦点——Popup 在 Overlay 层,选中走自身 onClicked)。
            onActiveFocusChanged: {
                if (activeFocus) {
                    serverPickList.model = root.serverPickOptions()
                    serverPickPopup.open()
                } else {
                    serverPickPopup.close()
                }
            }
            // 服务器快选下拉:列出可见账号(显示名),输入即过滤;点选 =
            // 服名填入框中(过滤按服名命中,行/卡条同步收窄)。
            Popup {
                id: serverPickPopup
                parent: filterField
                y: filterField.height + 6
                width: 240
                padding: 6
                closePolicy: Popup.CloseOnEscape
                background: Rectangle {
                    color: Qt.rgba(Theme.scrim.r, Theme.scrim.g, Theme.scrim.b, 0.92)
                    radius: 8
                    border.width: 1
                    border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
                }
                contentItem: ListView {
                    id: serverPickList
                    implicitHeight: Math.min(contentHeight, 300)
                    clip: true
                    // 命令式赋值(非活绑定):注入/聚合通知与页面切换交错时,
                    // 活绑定重算 setModel 会撞 DelegateModel 崩溃窗。
                    model: []
                    delegate: ItemDelegate {
                        id: pickItem
                        required property string modelData
                        width: ListView.view.width
                        height: 32
                        padding: 0
                        onClicked: {
                            filterField.text = pickItem.modelData
                            serverPickPopup.close()
                            filterField.forceActiveFocus()
                        }
                        contentItem: AppText {
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 20
                            text: pickItem.modelData
                            font.pixelSize: 13
                            color: Theme.textPrimary
                            elide: Text.ElideRight
                        }
                        background: Rectangle {
                            radius: 5
                            color: pickItem.hovered
                                   ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                                   : "transparent"
                        }
                    }
                }
            }
        }
        // 四个按钮共用一份模糊抓取(见 GlassBlurSource):整片列表只抓一次。
        // 刷新策略 = 滚动驱动 + 定时兜底:滚轮直接写 contentY(不产生 moving/flick),
        // 挂 contentYChanged 滚动时逐帧刷新;33ms(30fps)定时器兜住非滚动的内容变化
        // (图片异步装载等)。
        GlassBlurSource { id: navGlassBlur; sourceItem: pageList }
        Connections {
            target: pageList
            function onContentYChanged() { navGlassBlur.refresh() }
        }

        // iOS 毛玻璃导航:三个圆形通透毛玻璃按钮(背景模糊 + 半透明 + 微光)。
        // 模糊源用滚动内容 pageList,内容滚过按钮时实时通透模糊。
        Row {
            anchors.right: parent.right
            anchors.rightMargin: Constants.homeNavMarginR
            anchors.verticalCenter: parent.verticalCenter
            spacing: Constants.homeNavSpacing
            FrostedGlass {
                width: Constants.homeNavBtnSize
                height: Constants.homeNavBtnSize
                radius: Constants.homeNavBtnSize / 2
                blurSource: pageList
                blurGroup: navGlassBlur
                thickness: 22
                bend: 1.8
                frostAmount: 0.35
                edgeLight: 0.55
                saturation: 0.4
                blurRadius: 5
                sampleMargin: 48
                elevation: 4
                glassColor: Qt.rgba(Theme.scrimSoft.r, Theme.scrimSoft.g, Theme.scrimSoft.b, 0.25)
                borderColor: Theme.glassRim
                GlassCircleButton {
                    anchors.centerIn: parent
                    iconName: "search"
                    onClicked: root.openSearch()
                }
            }
            FrostedGlass {
                width: Constants.homeNavBtnSize
                height: Constants.homeNavBtnSize
                radius: Constants.homeNavBtnSize / 2
                blurSource: pageList
                blurGroup: navGlassBlur
                thickness: 22
                bend: 1.8
                frostAmount: 0.35
                edgeLight: 0.55
                saturation: 0.4
                blurRadius: 5
                sampleMargin: 48
                elevation: 4
                glassColor: Qt.rgba(Theme.scrimSoft.r, Theme.scrimSoft.g, Theme.scrimSoft.b, 0.25)
                borderColor: Theme.glassRim
                GlassCircleButton {
                    anchors.centerIn: parent
                    iconName: "history"
                    onClicked: root.openHistory()
                }
            }
            FrostedGlass {
                width: Constants.homeNavBtnSize
                height: Constants.homeNavBtnSize
                radius: Constants.homeNavBtnSize / 2
                blurSource: pageList
                blurGroup: navGlassBlur
                thickness: 22
                bend: 1.8
                frostAmount: 0.35
                edgeLight: 0.55
                saturation: 0.4
                blurRadius: 5
                sampleMargin: 48
                elevation: 4
                glassColor: Qt.rgba(Theme.scrimSoft.r, Theme.scrimSoft.g, Theme.scrimSoft.b, 0.25)
                borderColor: Theme.glassRim
                GlassCircleButton {
                    anchors.centerIn: parent
                    iconName: "server"
                    onClicked: root.openServerManager()
                }
            }
            FrostedGlass {
                width: Constants.homeNavBtnSize
                height: Constants.homeNavBtnSize
                radius: Constants.homeNavBtnSize / 2
                blurSource: pageList
                blurGroup: navGlassBlur
                thickness: 22
                bend: 1.8
                frostAmount: 0.35
                edgeLight: 0.55
                saturation: 0.4
                blurRadius: 5
                sampleMargin: 48
                elevation: 4
                glassColor: Qt.rgba(Theme.scrimSoft.r, Theme.scrimSoft.g, Theme.scrimSoft.b, 0.25)
                borderColor: Theme.glassRim
                GlassCircleButton {
                    anchors.centerIn: parent
                    iconName: "settings"
                    onClicked: root.openSettings()
                }
            }
        }
    }

    // 整页可滚动(主流:hero + 所有库行随页面上下滚动)。
    Flickable {
        id: pageList
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        // CPU-bound 滚动场景关闭像素平滑,降低 QSGRenderThread 滚动负载。
        smooth: false
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // Column 布局 ⇒ contentHeight 恒为精确值,滚动条无估计可跳
        // (ListView 按「可见委托平均高」外推 contentHeight,变高行必跳)。
        contentWidth: width
        contentHeight: pageCol.height
        ScrollBar.vertical: MoeScrollBar {}

        Column {
            id: pageCol
            width: pageList.width
            // 行间间距:标题与上一行海报间距(6)>= 标题与自身海报间距(4)。
            spacing: Constants.homeRowGap

            // hero 轮播 + 媒体库节(顶部一屏,随内容滚动,常驻加载 3 张图)。
            // 高度只依赖窗口宽度与常量:首次布局即最终尺寸,后续不翻转。
            Item {
            id: heroCar
            property bool _hoverMoved: false
            height: Constants.homeHeroTopPad + root.heroH + heroCar.mediaSecH
            width: pageList.width
            clip: false
            readonly property real cardH: root.heroH * Constants.homeHeroCardH
            readonly property real cardW: Math.min(cardH * Constants.homeHeroCardAspect,
                                                   width * Constants.homeHeroCardWCap)
            // 媒体库节高 = 标题行高 + 间距 + 库卡高 + 底部留白(常量构成,稳定)。
            readonly property real mediaSecH: mediaTitleRow.height + mediaLib.spacing
                                              + Constants.homeMediaCardH + Constants.homeMediaBottomPad

            PathView {
                id: heroPv
                // 仅占 hero 区(上方);媒体库节在下方。
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: Constants.homeHeroTopPad
                height: root.heroH
                model: heroModel
                        onCurrentIndexChanged: {
                    root.heroCenter = currentIndex   // 根级函数读不到本 id,用镜像
                    root.flushHero(false)            // 轮播走开即结算挂起的替换
                }
                pathItemCount: 3
                preferredHighlightBegin: 0.5
                preferredHighlightEnd: 0.5
                highlightRangeMode: PathView.StrictlyEnforceRange
                snapMode: PathView.SnapOneItem
                interactive: false

                path: Path {
                    startX: heroCar.width * Constants.homeHeroPathStartX
                    startY: root.heroH * 0.5
                    PathAttribute { name: "itemScale"; value: Constants.homeHeroSideScale }
                    PathAttribute { name: "tilt"; value: 1 }
                    PathAttribute { name: "itemZ"; value: 0 }
                    PathLine { x: heroCar.width * Constants.homeHeroPathCenterX; y: root.heroH * 0.5 }
                    PathAttribute { name: "itemScale"; value: 1.0 }
                    PathAttribute { name: "tilt"; value: 0 }
                    PathAttribute { name: "itemZ"; value: 2 }
                    PathLine { x: heroCar.width * Constants.homeHeroPathEndX; y: root.heroH * 0.5 }
                    PathAttribute { name: "itemScale"; value: Constants.homeHeroSideScale }
                    PathAttribute { name: "tilt"; value: -1 }
                    PathAttribute { name: "itemZ"; value: 0 }
                }
                delegate: HeroCard {}
            }

            // 圆点指示+hover/点击切换。
            Row {
                z: 7
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: Constants.homeHeroTopPad + root.heroH * 0.5 + heroCar.cardH / 2 + Constants.homeHeroDotsGap
                spacing: Constants.homeHeroDotSpacing
                Repeater {
                    model: heroModel.count
                    delegate: Rectangle {
                        required property int index
                        id: dot
                        width: heroPv.currentIndex === index
                               ? Constants.homeHeroDotSizeSel : Constants.homeHeroDotSize
                        height: Constants.homeHeroDotSize
                        radius: height / 2
                        color: heroPv.currentIndex === index
                               ? Theme.accent
                               : Qt.rgba(Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 0.55)
                        Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: dot.scale = 1.45
                            onExited: dot.scale = 1.0
                            onClicked: {
                                heroPv.currentIndex = index
                                if (!root.heroHovered)
                                    heroTimer.restart()
                            }
                        }
                    }
                }
            }

            // hover 悬停暂停自动轮播(看卡时不被切走)。
            HoverHandler {
                id: heroHover
                // 幻影 hover 闩锁:窗口若恰好开在光标下,enter 无移动即触发,
                // 悬停暂停会把轮换卡到"移出为止"(启动后轮转迟迟不开)。
                // 只在移入后真发生过位移才算悬停;移出即复位。
                onPointChanged: heroCar._hoverMoved = true
                onHoveredChanged: {
                    if (!hovered)
                        heroCar._hoverMoved = false
                    root.heroHovered = hovered && heroCar._hoverMoved
                }
            }
            // 全图慢速灌缓存:启动 10s 后每 1.5s 一张灌进磁盘缓存(会话中期
            // 空闲时,不挤启动)。随机建议的新条目图从未显示=从未入缓存,
            // 下次启动轮到只能现场拉(会白卡);灌过则下次全命中。
            property int _heroWarmIdx: 0
            Timer {
                id: heroWarmStarter
                interval: 10000
                running: true
                repeat: false
                onTriggered: {
                    heroCar._heroWarmIdx = 0
                    heroWarmTimer.start()
                }
            }
            Timer {
                id: heroWarmTimer
                interval: 1500
                repeat: true
                running: false
                onTriggered: {
                    if (heroCar._heroWarmIdx >= heroModel.count) {
                        stop()
                        return
                    }
                    const m = heroModel.get(heroCar._heroWarmIdx)
                    const id = m ? (m.backdropId || m.parentBackdropId || m.posterId || "") : ""
                    heroWarmImg.source = id ? "image://emby/" + id : ""
                    heroCar._heroWarmIdx++
                }
            }
            Image {
                id: heroWarmImg
                visible: false
                width: 0
                height: 0
                asynchronous: true
                cache: true
                // 缓存键 = 海报 id(与尺寸无关),无需对齐卡面尺寸。
            }
            // 只预载"下一张"卡图
            Image {
                visible: false
                width: 0
                height: 0
                asynchronous: true
                cache: true
                source: {
                    if (heroModel.count < 2)
                        return ""
                    const m = heroModel.get((heroPv.currentIndex + 2) % heroModel.count)
                    const id = m.backdropId || m.parentBackdropId || m.posterId || ""
                    return id ? "image://emby/" + id : ""
                }
                // 缓存键含解码尺寸:与卡面 Image 的 sourceSize 逐位一致。
                sourceSize.width: Math.max(1, Math.round((heroCar.cardW + 16) * Screen.devicePixelRatio))
                sourceSize.height: Math.max(1, Math.round((heroCar.cardH + 16) * Screen.devicePixelRatio))
            }
            Timer {
                id: heroTimer
                interval: Constants.homeHeroTimerMs
                repeat: true
                running: heroModel.count > 1 && !root.heroHovered
                onTriggered: heroPv.currentIndex = (heroPv.currentIndex + 1) % heroModel.count
            }
            // ===== 媒体库列举(hero 下方):标题 + 库图片横排(库名常显,不随 hover) =====
            Column {
                id: mediaLib
                anchors.top: parent.top
                anchors.topMargin: Constants.homeHeroTopPad + root.heroH
                width: parent.width
                spacing: 10
                visible: AccountManager.homeRows.count > 0
                // 底部留白:首行标题离媒体库卡片的间距与行内 12px 规则一致。
                bottomPadding: Constants.homeMediaBottomPad
                Item {
                    id: mediaTitleRow
                    width: parent.width
                    height: Math.max(mediaTitle.implicitHeight, 28)
                    AppText {
                        id: mediaTitle
                        anchors.left: parent.left
                        anchors.leftMargin: Constants.rowLeftMargin
                        anchors.verticalCenter: parent.verticalCenter
                        text: "媒体库"
                        color: Theme.textPrimary
                        font.pixelSize: Constants.homeMediaTitlePx
                        font.bold: true
                    }
                }
                Item {
                    width: parent.width
                    height: Constants.homeMediaCardH
                    clip: true
                    ListView {
                        id: mediaLibs
                        anchors.fill: parent
                        orientation: ListView.Horizontal
                        spacing: 0
                        header: Item { width: Constants.rowLeftMargin; height: 1 }
                        // 右缘与左缘同留白(滚到尽头时末卡不贴窗缘)。
                        footer: Item { width: Constants.rowLeftMargin; height: 1 }
                        // 卡条保持原始模型:过滤走每卡折叠(不打字期重建),
                        // 自定义桶卡无目标库页(虚拟库页后续阶段),不进卡条。
                        model: AccountManager.homeRows
                            // 过滤变化时回左端:原 contentX 会指向已折叠的中段(首卡被截断)。
                        property string filterEcho: root.libFilter
                        onFilterEchoChanged: positionViewAtBeginning()
                        // delegate 外包一层格子:卡间距折进格子右侧,过滤折叠(宽 0)
                        // 后不留缝隙;折叠只改尺寸,委托与图片不重建。
                        delegate: Item {
                            id: libCell
                            required property var modelData
                            visible: root.libMatch(libCell.modelData)
                            width: visible ? Constants.homeMediaCardW + Constants.rowSpacing : 0
                            height: Constants.homeMediaCardH
                            Rectangle {
                                id: libCard
                                property bool hovered: false
                                width: Constants.homeMediaCardW
                                height: Constants.homeMediaCardH
                                radius: Constants.homeMediaCardRadius
                                color: Theme.surface
                                Image {
                                    anchors.fill: parent
                                    source: libCell.modelData.posterId
                                           ? "image://emby/" + libCell.modelData.posterId : ""
                                    // 就绪淡入
                                    opacity: status === Image.Ready ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 260 } }
                                    fillMode: Image.PreserveAspectCrop
                                    cache: true
                                    asynchronous: true
                                    // 与 PosterCard 同源修复:原图全尺寸解码缩到卡面
                                    // 会毛边,解码尺寸对齐显示 + mipmap 降采样。
                                    smooth: true
                                    mipmap: true
                                    sourceSize.width: Math.max(1, Math.round(parent.width * Screen.devicePixelRatio))
                                    sourceSize.height: Math.max(1, Math.round(parent.height * Screen.devicePixelRatio))
                                    layer.enabled: true
                                    layer.smooth: true
                                    layer.effect: ShaderEffect {
                                        property real u_radius: Constants.homeMediaCardRadius
                                        property size u_size: Qt.size(libCell.width, Constants.homeMediaCardH)
                                        fragmentShader: "qrc:/qt/qml/MoePlayer/Core/shaders/round-rect.frag.qsb"
                                    }
                                }
                                // 底部渐变压暗 + 库名常显(与库海报 hover 显字的机制不同)。
                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    height: Constants.homeMediaGradH
                                    radius: Constants.homeMediaCardRadius
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: "transparent" }
                                        GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.65) }
                                    }
                                }
                                AppText {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    anchors.leftMargin: Constants.homeMediaTextMargin
                                    anchors.rightMargin: Constants.homeMediaTextMargin
                                    anchors.bottomMargin: Constants.homeMediaTextBottom
                                    text: (root.multiServer && libCell.modelData.serverName
                                           ? libCell.modelData.serverName + " · " : "")
                                          + libCell.modelData.viewName
                                    color: Theme.textOnBadge
                                    font.pixelSize: Constants.homeMediaTextPx
                                    elide: Text.ElideRight
                                }
                                Rectangle {
                                    anchors.fill: parent
                                    color: "transparent"
                                    radius: Constants.homeMediaCardRadius
                                    border.width: 1
                                    border.color: libCard.hovered ? Theme.accent : Theme.borderSoft
                                }
                                HoverHandler {
                                    onHoveredChanged: libCard.hovered = hovered
                                }
                                TapHandler {
                                    onTapped: root.openLibrary(libCell.modelData.viewId,
                                                               libCell.modelData.serverUrl,
                                                               libCell.modelData.viewName,
                                                               libCell.modelData.accountId)
                                }
                            }
                        }
                    }
                }
            }
        }

            Repeater {
                model: homeRowsFilter // 恒定对象,过滤走谓词(见 homeRowsFilter 注释)
                delegate: LibraryRow {}
            }
        }
    }


    // ---- 全页空态(无可见账号时替代浏览内容)----
    // 居中:应用图标 + 标题 + 一句说明 + 单一主 CTA(添加服务器)。
    Item {
        id: welcome
        // 无可见账号 = 无账号,或全部隐藏(隐藏即视作不存在)且未露出。
        visible: root.visibleAccountCount === 0
        anchors.fill: parent

        Column {
            anchors.centerIn: parent
            // 视觉中心略上抬(扣除顶栏高度)。
            anchors.verticalCenterOffset: -root.navH / 2
            spacing: 0

            // 应用图标作徽记(专属徽标后续再设计)。
            Image {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 96
                height: 96
                source: "qrc:/app/app-icon.svg"
                sourceSize: Qt.size(192, 192)
                fillMode: Image.PreserveAspectFit
                mipmap: true
            }

            Item { width: 1; height: 28 }

            AppText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "MoePlayer"
                color: Theme.textPrimary
                font.pixelSize: 32
                font.bold: true
            }

            Item { width: 1; height: 12 }

            AppText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "连接你的 Emby 服务器，开始观影"
                color: Theme.textPrimary
                font.pixelSize: 15
            }

            Item { width: 1; height: 8 }

            AppText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "登录后，媒体库、继续观看与播放历史都会在首页聚合"
                color: Theme.textMuted
                font.pixelSize: 13
            }

            Item { width: 1; height: 36 }

            // 主 CTA(与服务器管理页「添加」同款 pill 样式,放大一号)。
            Button {
                id: welcomeAddBtn
                anchors.horizontalCenter: parent.horizontalCenter
                width: 180
                height: 44
                text: "添加服务器"
                onClicked: root.openServerManager()
                background: Rectangle {
                    radius: 22
                    color: welcomeAddBtn.pressed || welcomeAddBtn.hovered
                           ? Theme.accentDeep : Theme.accent
                }
                contentItem: AppText {
                    text: welcomeAddBtn.text
                    color: Theme.accentInk
                    font.pixelSize: 15
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

        }
    }

    // 可见账号数(隐藏功能):0 = 无账号或全部隐藏且未露出 → 首页按
    // "无账号"处理(显示欢迎页)。Alt+S 露出(showHidden)时全部计入。
    // 依赖:accounts(accountsChanged)与 showHidden(hiddenChanged)。
    property int visibleAccountCount: {
        const list = AccountManager.accounts
        if (AccountManager.showHidden)
            return list.length
        let n = 0
        for (let i = 0; i < list.length; ++i) {
            if (!list[i].hidden && !list[i].hiddenByFolder)
                ++n
        }
        return n
    }

    // 库行(一个媒体库):行头文字(库名)+ 该库条目横向卡片行。
    component LibraryRow: Column {
        id: libRow
        required property var modelData
        width: parent ? parent.width : 0
        // 视口门控:壳高由几何公式定死(与卡是否实例化无关),离屏行的
        // 卡片/海报不创建,内存与 ListView 按需持平;回滚经磁盘缓存快速重现。
        readonly property bool rowActive: libRow.y + libRow.height > pageList.contentY - pageList.height
                                          && libRow.y < pageList.contentY + pageList.height * 2
        // 标题贴近自身海报(下间距 < 与上一节的上间距)。
        spacing: Constants.homeRowTitleGap

        // 行头(Column 子项不可上下锚定,故包一层 Item 做水平布局):
        // 左库名 + 右「查看全部 ›」链接(进入对应媒体库)。
        Item {
            height: Constants.rowTitleH
            width: parent.width
            AppText {
                id: rowTitle
                anchors.left: parent.left
                // 与「媒体库」节标题同左缘(标题文字对齐;卡片图像区各自内偏)。
                anchors.leftMargin: Constants.rowLeftMargin
                anchors.right: seeAllLink.left
                anchors.rightMargin: Constants.homeRowTitlePad
                anchors.verticalCenter: parent.verticalCenter
                text: (libRow.modelData.custom === true
                       ? ""
                       : (libRow.modelData.serverName !== ""
                          ? libRow.modelData.serverName + " · " : "")) + libRow.modelData.viewName
                color: Theme.textPrimary
                font.pixelSize: Constants.homeRowTitlePx
                font.bold: true
                elide: Text.ElideRight
            }
            AppText {
                id: seeAllLink
                visible: libRow.modelData.custom !== true
                anchors.right: parent.right
                anchors.rightMargin: Constants.rowLeftMargin + Constants.homeRowHoverPad / 2 + Constants.cellGap / 2
                anchors.verticalCenter: parent.verticalCenter
                text: "查看全部 ›"
                color: seeAllMouse.hovered ? Theme.accent : Theme.textMuted
                font.pixelSize: Constants.homeSeeAllPx
                MouseArea {
                    id: seeAllMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openLibrary(libRow.modelData.viewId,
                                                libRow.modelData.serverUrl,
                                                libRow.modelData.viewName,
                                                libRow.modelData.accountId)
                }
            }
        }
        // 条目卡片区:网格自动铺满宽度,不横向滚动(横滚与页面纵向滚动手感
        // 互搏,且离屏卡纯耗内存);行数 = 配置「每库行数」,条数 = min(请求
        // 上限, 行数×列数)。首末卡 hover 放大溢出经水平内缩垫吸收。
        Item {
            id: rowGridWrap
            anchors.left: parent.left
            anchors.leftMargin: Constants.rowLeftMargin
            width: libRow.width - Constants.rowLeftMargin * 2
            // 几何公式全部来自根级单一来源(不各自推导,防漂移)。
            readonly property int lines: root.homeLines
            readonly property int gap: Constants.cellGap
            readonly property int cols: root.gridCols(width)
            // GridView 按 floor(width/cellWidth) 布列(每格都含 gap)——
            // cellWidth 必须精确等分(width/cols),gap 折进格内,否则公式列数
            // 与 GridView 实际列数错位,末列空位成右缝。
            readonly property real cardW: root.gridCardW(width)
            readonly property real cardH: Constants.gridCardH(cardW)
            readonly property int vPad: root.gridVPad(cardH)
            // 实际显示行数:条目填不满设定行数时按实际行数收,不留空行
            readonly property int shownLines: root.gridShownLines(libRow.modelData.items.length, width)
            height: shownLines * cardH + (shownLines - 1) * gap + vPad * 2
            clip: true
            GridView {
                id: rowItems
                anchors.fill: parent
                anchors.leftMargin: Constants.homeRowHoverPad / 2
                anchors.rightMargin: Constants.homeRowHoverPad / 2
                anchors.topMargin: rowGridWrap.vPad
                interactive: false
                // -0.5:width/cols 的双精度积可微超 width(1201/7×7=1201.0000000000002)
                // ⇒ GridView 判定末格放不下而换行,末列失踪成右缝。
                cellWidth: width / parent.cols - 0.5
                cellHeight: parent.cardH + parent.gap
                reuseItems: true
                model: libRow.rowActive ? libRow.modelData.items.slice(0, parent.lines * parent.cols) : []
                delegate: Item {
                    required property var modelData
                    required property int index
                    width: rowItems.cellWidth
                    height: rowItems.cellHeight
                    z: pc.hovered ? 2 : 0
                    PosterCard {
                        id: pc
                        // 格内居中:卡间距拆半到卡两侧,首/末卡距缘各 gap/2,左右对称。
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: rowItems.cellWidth - Constants.cellGap
                        height: rowItems.cellHeight - Constants.cellGap
                        model: parent.modelData
                        index: parent.index
                        showActions: false
                        itemId: parent.modelData.id || ""
                        posterId: parent.modelData.posterId || ""
                        title: parent.modelData.name || ""
                        year: parent.modelData.year || 0
                        rating: parent.modelData.rating || 0
                        played: !!parent.modelData.played
                        favorite: !!parent.modelData.favorite
                        positionTicks: parent.modelData.positionTicks || 0
                        runtimeTicks: parent.modelData.runtimeTicks || 0
                        unplayedCount: parent.modelData.unplayedCount || 0
                        itemType: parent.modelData.type || ""
                        onClicked: root.showDetail(parent.modelData.id, parent.modelData.posterId || "",
                                                   parent.modelData.name,
                                                   parent.modelData.serverUrl || libRow.modelData.serverUrl,
                                                   parent.modelData.accountId || libRow.modelData.accountId)
                    }
                }
            }
            // 库壳已到、条目未到时显示加载占位(items 空且 loading)。
            Text {
                anchors.centerIn: parent
                visible: rowItems.count === 0 && libRow.modelData.loading
                color: Theme.textMuted
                font.pixelSize: 13
                text: "加载中…"
            }
        }
    }

    // 圆形毛玻璃按钮(放大镜等):圆形玻璃底 + 居中图标。
    component GlassCircleButton: Button {
        id: gcb
        property string iconName: ""
        width: Constants.homeNavBtnSize
        height: Constants.homeNavBtnSize
        padding: 0
        hoverEnabled: true
        background: Item {
            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: gcb.hovered
                       ? (ThemeStore.isLight ? Qt.rgba(0, 0, 0, 0.10)
                                             : Qt.rgba(1, 1, 1, 0.14))
                       : "transparent"
                Behavior on color { ColorAnimation { duration: 150 } }
            }
        }
        // contentItem 会被 Button 拉伸至全尺寸,图标须放进容器内居中才能保持小尺寸。
        // SVG 按显示尺寸×DPR 栅格化:避免大图降采样把细描边摊灰。
        // 图标是白色描边 SVG:亮色系配色换 dark/ 下的暗色变体(蒙版着色有锯齿,弃用)。
        contentItem: Item {
            Image {
                width: 14
                height: 14
                anchors.centerIn: parent
                source: gcb.iconName ? ("qrc:/icons/" + (ThemeStore.isLight ? "dark/" : "")
                                        + gcb.iconName + ".svg") : ""
                fillMode: Image.PreserveAspectFit
                smooth: true
                sourceSize.width: Math.max(1, Math.round(14 * Screen.devicePixelRatio))
                sourceSize.height: Math.max(1, Math.round(14 * Screen.devicePixelRatio))
            }
        }
    }

    component HeroCard: Item {
        id: hcard
        required property var modelData
        required property int index
        width: heroCar.cardW
        height: heroCar.cardH
        scale: PathView.onPath ? PathView.itemScale : Constants.homeHeroOffPathScale
        z: PathView.onPath ? PathView.itemZ : 0
        property real tilt: PathView.onPath ? PathView.tilt : 0
        // 中心卡判定(容差):root 级绑定,供文字显隐。
        readonly property bool isCenter: Math.abs(PathView.tilt) < 0.01
        // 卡片整体(图片 + 底部渐变 + 文字)被 ShaderEffectSource 抓取成纹理,
        // 再由 ShaderEffect 做透视映射——文字随卡片一起倾斜。
        // 过扫描:宿主比卡面大 pad(8px)/边,内容溢出进 pad——SDF 卡界线
        // 落在 mesh 三角形内部,圆角 ramp 两侧都有像素。
        Item {
            id: fxHost
            readonly property int pad: 8
            x: -pad
            y: -pad
            width: parent.width + pad * 2
            height: parent.height + pad * 2
            // layer 效果:内容一次进 layer 纹理,effect 采样透视(无双卡)。
            // 尺寸含 pad(过扫描,见上注);pad 传给 SDF 定位卡界。
            layer.enabled: true
            layer.samplerName: "src"
            layer.smooth: true
            layer.mipmap: true
            // 2 倍超采样,量化 128px 步进:缩放时纹理尺寸不逐帧重建(重建闪烁)。
            layer.textureSize: Qt.size(Math.max(1, Math.round(width * Screen.devicePixelRatio * 2 / 128) * 128),
                                       Math.max(1, Math.round(height * Screen.devicePixelRatio * 2 / 128) * 128))
            layer.effect: ShaderEffect {
                id: cardFx
                property real sideTilt: hcard.tilt
                property real radiusPx: Constants.homeHeroRadius
                property real padPx: fxHost.pad
                property real w: fxHost.width
                property real h: fxHost.height
                property real maxAngle: 38
                property real focal: w * Constants.homeHeroFocalRatio
                property real sideInset: 0
                mesh: Qt.size(16, 16)
                vertexShader: "qrc:/qt/qml/MoePlayer/Core/shaders/hero.vert.qsb"
                fragmentShader: "qrc:/qt/qml/MoePlayer/Core/shaders/hero.frag.qsb"
            }
        Item {
            id: cardContent
            x: fxHost.pad
            y: fxHost.pad
            width: hcard.width
            height: hcard.height
            // 圆角/裁剪全由 hero.frag 的 SDF 做;不做矩形 clip(内容要溢出
            // 进 pad 供 ramp 外半使用)。
            // 用 layer.effect 做透视(Qt 官方图片效果方式):本卡内容一次渲染进
            // layer 纹理,effect(ShaderEffect)采样透视——无独立 ShaderEffectSource,
            // Qt 保证不重复渲染(无双卡)。

            Image {
                id: cardImg
                // 就绪淡入带闩锁:首载淡入一次;之后 opacity 常 1,同实例换
                // source 由 retainWhileLoading 平滑(纯 status 门控会把 retain
                // 保留的旧帧一起淡出 = 无感刷新回退)。
                property bool _everReady: false
                onStatusChanged: if (status === Image.Ready) _everReady = true
                opacity: _everReady ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 260 } }
                // 溢出到 pad(ramp 外半需要真实内容,不只是透明)
                x: -fxHost.pad
                y: -fxHost.pad
                width: fxHost.width
                height: fxHost.height
                source: {
                    const m = hcard.modelData
                    const id = m.backdropId || m.parentBackdropId || m.posterId || ""
                    return id ? "image://emby/" + id : ""
                }
                fillMode: Image.PreserveAspectCrop
                // 平滑缩放:mipmap 预滤波层级,降采样(窗口缩小/解码尺寸大于
                // 显示)比 smooth 双线性明显更少锯齿(官方:降缩放下 mipmap
                // quality 优于 smooth,代价是初始化与渲染开销)。
                smooth: true
                mipmap: true
                // 解码尺寸与显示尺寸精确一致(×DPR):量化(256px 步进)会让
                // 解码尺寸偏离显示,窗口缩放中出现 1.0~1.5× 升采样/拉伸,
                // 双线性放大无 mipmap 兜底 → 边缘锯齿/模糊。缩放中重解码由
                // retainWhileLoading 保留旧纹理,避免闪烁(不再需要量化防抖)。
                sourceSize.width: Math.max(1, Math.round(fxHost.width * Screen.devicePixelRatio))
                sourceSize.height: Math.max(1, Math.round(fxHost.height * Screen.devicePixelRatio))
                asynchronous: true
                retainWhileLoading: true
            }
            // 玻璃信息条(仅中心卡):半透明 scrim + 顶部 1px 均匀细 rim
            Rectangle {
                opacity: hcard.isCenter ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 400 } }
                x: -fxHost.pad
                y: cardContent.height * 0.58
                width: fxHost.width
                height: cardContent.height * 0.42 + fxHost.pad
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.28) }
                }
            }
            Rectangle {
                id: glassBar
                opacity: hcard.isCenter ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 400 } }
                x: -fxHost.pad
                y: cardContent.height - Math.round(cardContent.height * 0.16)
                width: fxHost.width
                height: Math.round(cardContent.height * 0.16) + fxHost.pad
                color: Qt.rgba(0, 0, 0, 0.32)
                // 顶部细 rim(均匀,非定向——定向高光被否过)。
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: 1
                    color: Qt.rgba(1, 1, 1, 0.22)
                }
            }
            // 文字区(仅中心卡显示;侧卡纯图):年份靠左、标题靠右、底部平齐。
            // 锚定只连兄弟/直接父(官方限制),故年份与标题共用一个容器 Item,
            // 各自 anchors.left/right 到容器两侧;容器单边锚+显式 height 合法,
            // 标题单边右锚+width 合法(elide 需要确定宽)。
            // 判中心卡不用 isCurrentItem(本 PathView 恒 false),
            // 用路径 tilt=0 + 浮点容差(吸附毫厘差不瞬间失显)。
            Item {
                id: titleArea
                // 换卡文字动线:失焦 = 下移+淡出;到位 = 自下方上移+淡入。
                // visible 恒定,由 opacity 承担显隐(绑定 Behavior 才双向生效)。
                property real ty: hcard.isCenter ? 0 : 14
                opacity: hcard.isCenter ? 1 : 0
                Behavior on ty { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                anchors.bottomMargin: 12 - titleArea.ty
                height: titleText.height
                AppText {
                    id: yearText
                    visible: (hcard.modelData.year || 0) > 0
                    text: hcard.modelData.year || ""
                    color: Theme.textOnBadge
                    font.pixelSize: Math.max(12, Math.round(heroCar.cardW * Constants.homeHeroYearRatio))
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                }
                AppText {
                    id: titleText
                    text: hcard.modelData.name || ""
                    color: Theme.textOnBadge
                    font.pixelSize: Math.max(16, Math.round(heroCar.cardW * Constants.homeHeroTitleRatio))
                    font.bold: true
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, heroCar.cardW * 0.55)
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                }
            }
        }
        MouseArea {
            anchors.fill: parent
            onClicked: {
                if (heroPv.currentIndex === hcard.index) {
                    root.showDetail(hcard.modelData.id, hcard.modelData.posterId || "",
                                    hcard.modelData.name, hcard.modelData.serverUrl,
                                    hcard.modelData.accountId)
                } else {
                    heroPv.currentIndex = hcard.index
                    // 悬停中不 restart:restart 会强制 running=true 顶掉
                    // hover 暂停的绑定(直到下次依赖变化)。
                    if (!root.heroHovered)
                        heroTimer.restart()
                }
            }
        }
    }
}
}  // fxHost(过扫描宿主)

