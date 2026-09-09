pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import MoePlayer.Core

//! 首页(主流平铺版):整页 Flickable 上下滚动;顶部导航固定。
//! 内容 = hero 轮播 + 每库一行(大库海报 + 条目卡片横向行)。
Item {
    id: root

    // hero 轮播(继续观看前 8,不足补最新添加前 8)。
    property var heroItems: []
    property int heroIndex: 0
    readonly property real navH: Constants.homeNavH
    // hero 高按应用宽度计算(横向海报比例):首页可滚动,视图高度不构成约束;
    // 窄窗随宽度收缩,卡片保持满带宽。
    // 用窗口宽度而非父宽:页面首帧布局时父宽度尚未赋值,会致 ListView 以 0
    // hero 高做首次布局(条目从不重排,hero 被留在内容上方不可见)。
    readonly property real heroH: (root.Window && root.Window.width > 0
                                   ? root.Window.width : 1280) * Constants.homeHeroWidthRatio

    signal showDetail(string itemId, string posterId, string title, string serverUrl, string accountId)
    signal openLibrary(string viewId, string serverUrl, string viewName, string accountId)
    signal openServerManager()
    signal openSettings()
    signal openSearch()

    // 聚合 hero 轮播数据:优先服务器建议(/Suggestions),按建议顺序展示;
    // 建议未到/为空时回退本地聚合(继续观看优先,不足补最新添加)。
    function rebuildTop() {
        // 服务端已按 IncludeItemTypes=Movie,Series & ImageTypes=Backdrop 过滤
        // (4.9+ 版本门控,旧版跳过),此处只管截断显示条数。
        const sugOk = AccountManager.suggestions
        if (sugOk.length > 0) {
            root.heroItems = sugOk.slice(0, 10)
            return
        }
        const all = []
        const hm = AccountManager.homeRows
        for (let i = 0; i < hm.count; ++i) {
            const row = hm.rowAt(i)
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
        cw.sort(function (a, b) {
            return (b.playbackDateTicks || 0) - (a.playbackDateTicks || 0)
        })
        const cwTop = cw.slice(0, 10)
        root.heroItems = cwTop.length > 0 ? cwTop : all.slice(0, 10)
    }

    Component.onCompleted: {
        if (AccountManager.hasAccounts) {
            AccountManager.validateTokens()
            AccountManager.fetchHomeRows(Constants.homePerLibraryLimit)
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
            anchors.left: parent.left
            anchors.leftMargin: Constants.homeNavMarginL
            anchors.verticalCenter: parent.verticalCenter
            text: "MoePlayer"
            color: Theme.textPrimary
            font.pixelSize: Constants.homeNavTitlePx
            font.bold: true
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
                thickness: 22
                bend: 1.8
                frostAmount: 0.35
                edgeLight: 0.55
                saturation: 0.4
                blurRadius: 5
                sampleMargin: 48
                elevation: 4
                glassColor: Qt.rgba(0.08, 0.09, 0.12, 0.25)
                borderColor: Qt.rgba(1, 1, 1, 0.32)
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
                thickness: 22
                bend: 1.8
                frostAmount: 0.35
                edgeLight: 0.55
                saturation: 0.4
                blurRadius: 5
                sampleMargin: 48
                elevation: 4
                glassColor: Qt.rgba(0.08, 0.09, 0.12, 0.25)
                borderColor: Qt.rgba(1, 1, 1, 0.32)
                GlassCircleButton {
                    anchors.centerIn: parent
                    iconName: "history"
                    // 播放历史页未做,点击暂不响应
                }
            }
            FrostedGlass {
                width: Constants.homeNavBtnSize
                height: Constants.homeNavBtnSize
                radius: Constants.homeNavBtnSize / 2
                blurSource: pageList
                thickness: 22
                bend: 1.8
                frostAmount: 0.35
                edgeLight: 0.55
                saturation: 0.4
                blurRadius: 5
                sampleMargin: 48
                elevation: 4
                glassColor: Qt.rgba(0.08, 0.09, 0.12, 0.25)
                borderColor: Qt.rgba(1, 1, 1, 0.32)
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
                thickness: 22
                bend: 1.8
                frostAmount: 0.35
                edgeLight: 0.55
                saturation: 0.4
                blurRadius: 5
                sampleMargin: 48
                elevation: 4
                glassColor: Qt.rgba(0.08, 0.09, 0.12, 0.25)
                borderColor: Qt.rgba(1, 1, 1, 0.32)
                GlassCircleButton {
                    anchors.centerIn: parent
                    iconName: "settings"
                    onClicked: root.openSettings()
                }
            }
        }
    }

    // 整页可滚动(主流:hero + 所有库行随页面上下滚动)。
    ListView {
        id: pageList
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        // CPU-bound 滚动场景关闭像素平滑,降低 QSGRenderThread 滚动负载。
        smooth: false
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: AccountManager.homeRows
        reuseItems: true
        cacheBuffer: 400
        // 滚轮步进走配置:页级 homeWheelStep(0=全局 ConfigManager.wheelStep,
        // 默认 150;设置浮窗只调全局,页面级手改 config.toml)。
        WheelStepHandler {
            targetItem: pageList
            pageStep: ConfigManager.homeWheelStep
        }

        // 行间间距:标题与上一行海报间距(14)>= 标题与自身海报间距(12)。
        spacing: Constants.homeRowGap

        // header = hero 轮播 + 媒体库节(顶部一屏,随内容滚动,常驻加载 3 张图)。
        // 高度只依赖窗口宽度与常量:首次布局即最终尺寸,后续不翻转——
        // header 高度异步变化时 ListView 不会重排条目,只把 header 顶出内容区。
        header: Item {
            id: heroCar
            height: root.heroH + heroCar.mediaSecH
            width: pageList.width
            clip: false
            readonly property real cardH: root.heroH * Constants.homeHeroCardH
            readonly property real cardW: Math.min(cardH * Constants.homeHeroCardAspect,
                                                   width * Constants.homeHeroCardWCap)
            // 媒体库节高 = 标题隐高 + 间距 + 库卡高 + 底部留白(常量构成,稳定)。
            readonly property real mediaSecH: mediaTitle.implicitHeight + mediaLib.spacing
                                              + Constants.homeMediaCardH + Constants.homeMediaBottomPad

            PathView {
                id: heroPv
                // 仅占 hero 区(上方);媒体库节在下方。
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: root.heroH
                model: root.heroItems
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
                anchors.topMargin: root.heroH * 0.5 + heroCar.cardH / 2 + Constants.homeHeroDotsGap
                spacing: Constants.homeHeroDotSpacing
                Repeater {
                    model: root.heroItems.length
                    delegate: Rectangle {
                        required property int index
                        id: dot
                        width: heroPv.currentIndex === index
                               ? Constants.homeHeroDotSizeSel : Constants.homeHeroDotSize
                        height: Constants.homeHeroDotSize
                        radius: height / 2
                        color: heroPv.currentIndex === index
                               ? Constants.moePink : Qt.rgba(1, 1, 1, 0.55)
                        Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: dot.scale = 1.45
                            onExited: dot.scale = 1.0
                            onClicked: {
                                heroPv.currentIndex = index
                                heroTimer.restart()
                            }
                        }
                    }
                }
            }

            Timer {
                id: heroTimer
                interval: Constants.homeHeroTimerMs
                repeat: true
                running: root.heroItems.length > 1
                onTriggered: heroPv.currentIndex = (heroPv.currentIndex + 1) % root.heroItems.length
            }
            // ===== 媒体库列举(hero 下方):标题 + 库图片横排(库名常显,不随 hover) =====
            Column {
                id: mediaLib
                anchors.top: parent.top
                anchors.topMargin: root.heroH
                width: parent.width
                spacing: 10
                visible: AccountManager.homeRows.count > 0
                // 底部留白:首行标题离媒体库卡片的间距与行内 12px 规则一致。
                bottomPadding: Constants.homeMediaBottomPad
                AppText {
                    id: mediaTitle
                    anchors.left: parent.left
                    anchors.leftMargin: Constants.rowLeftMargin
                    text: "媒体库"
                    color: Theme.textPrimary
                    font.pixelSize: Constants.homeMediaTitlePx
                    font.bold: true
                }
                Item {
                    width: parent.width
                    height: Constants.homeMediaCardH
                    clip: true
                    ListView {
                        anchors.fill: parent
                        orientation: ListView.Horizontal
                        spacing: Constants.rowSpacing
                        header: Item { width: Constants.rowLeftMargin; height: 1 }
                        model: AccountManager.homeRows
                        delegate: Rectangle {
                            id: libCard
                            required property var modelData
                            property bool hovered: false
                            width: Constants.homeMediaCardW
                            height: Constants.homeMediaCardH
                            radius: Constants.homeMediaCardRadius
                            color: Theme.surface
                            border.width: 1
                            border.color: libCard.hovered ? Constants.moePink : Qt.rgba(1, 1, 1, 0.10)
                            Image {
                                anchors.fill: parent
                                source: libCard.modelData.posterId
                                       ? "image://emby/" + libCard.modelData.posterId : ""
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
                                Rectangle {
                                    id: libMask
                                    visible: false
                                    anchors.fill: parent
                                    radius: Constants.homeMediaCardRadius
                                    layer.enabled: true
                                }
                                layer.effect: MultiEffect {
                                    maskEnabled: true
                                    maskSource: libMask
                                    maskThresholdMin: 0.5
                                    maskSpreadAtMin: 1.0
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
                                text: libCard.modelData.viewName
                                color: "white"
                                font.pixelSize: Constants.homeMediaTextPx
                                elide: Text.ElideRight
                            }
                            HoverHandler {
                                onHoveredChanged: libCard.hovered = hovered
                            }
                            TapHandler {
                                onTapped: root.openLibrary(libCard.modelData.viewId,
                                                           libCard.modelData.serverUrl,
                                                           libCard.modelData.viewName,
                                                           libCard.modelData.accountId)
                            }
                        }
                    }
                }
            }
        }

        delegate: LibraryRow {
            width: ListView.view.width
        }
    }


    // 未登录提示条:无账号时提供服务器管理入口。
    Rectangle {
        visible: !AccountManager.hasAccounts
        anchors.top: parent.top
        anchors.topMargin: 64
        anchors.horizontalCenter: parent.horizontalCenter
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
            Button { onClicked: root.openServerManager(); text: "服务器管理" }
        }
    }

    // 库行(一个媒体库):行头文字(库名)+ 该库条目横向卡片行。
    component LibraryRow: Column {
        id: libRow
        required property var modelData
        width: parent ? parent.width : 0
        // 行高 = 行头文字 + 标题行间距 + 条目卡行(hover 溢出缓冲)。
        height: Constants.rowTitleH + Constants.homeRowTitleGap
                + Constants.rowHeight + Constants.homeRowHoverPad
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
                anchors.leftMargin: Constants.rowLeftMargin
                anchors.right: seeAllLink.left
                anchors.rightMargin: Constants.homeRowTitlePad
                anchors.verticalCenter: parent.verticalCenter
                text: (libRow.modelData.serverName !== ""
                       ? libRow.modelData.serverName + " · " : "") + libRow.modelData.viewName
                color: Theme.textPrimary
                font.pixelSize: Constants.homeRowTitlePx
                font.bold: true
                elide: Text.ElideRight
            }
            AppText {
                id: seeAllLink
                anchors.right: parent.right
                anchors.rightMargin: Constants.rowLeftMargin
                anchors.verticalCenter: parent.verticalCenter
                text: "查看全部 ›"
                color: seeAllMouse.hovered ? Constants.moePink : Theme.textMuted
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
        // 条目卡片横向行(鼠标拖拽横向滚动)。
        // clip:true 的边界即裁切线:首卡左缘原贴 ListView 左缘,hover 放大
        // (1.06,横向溢出 4.6px)立即被裁;header 垫 8px 让首卡左缘内移,
        // 高度 +16 容纳垂直溢出(230×1.06=243.8)。
        Item {
            anchors.left: parent.left
            anchors.leftMargin: Constants.rowLeftMargin
            width: libRow.width - Constants.rowLeftMargin
            height: Constants.rowHeight + Constants.homeRowHoverPad
            clip: true
                ListView {
                    id: rowItems
                    anchors.fill: parent
                    orientation: ListView.Horizontal
                    spacing: Constants.rowSpacing
                    // 首卡左缘内移(hover 放大横向溢出的一半),避免被 clip 裁切。
                    header: Item { width: Constants.homeRowHoverPad / 2; height: 1 }
                    // 复用 delegate 避免滚动时销毁/重建;cacheBuffer 预备离屏项减少抖动。
                    reuseItems: true
                    cacheBuffer: 600
                    model: libRow.modelData.items
                    delegate: Item {
                        required property var modelData
                        required property int index
                        width: Constants.rowCardW
                        height: Constants.rowHeight + Constants.homeRowHoverPad
                        z: pc.hovered ? 2 : 0
                        PosterCard {
                            id: pc
                            anchors.centerIn: parent
                            width: Constants.rowCardW
                            height: Constants.rowHeight
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
                                                       parent.modelData.name, libRow.modelData.serverUrl,
                                                       libRow.modelData.accountId)
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

    // iOS 毛玻璃容器(胶囊/圆):背景内容高斯模糊 + 半透明暗底 + 微光描边。
    // 形状由 radius 决定(胶囊=height/2,圆=width/2);content 置于玻璃之上。
    component GlassBar: Rectangle {
        id: gbar
        property var blurSource: null
        property color glassColor: Qt.rgba(0.08, 0.09, 0.12, 0.5)
        property color borderColor: Qt.rgba(1, 1, 1, 0.22)
        color: "transparent"
        border.width: 0
        clip: true

        // 取背后区块,降采样后高斯模糊 → 毛玻璃通透。
        ShaderEffectSource {
            id: gbarBg
            sourceItem: gbar.blurSource
            sourceRect: {
                if (!gbarBg.sourceItem)
                    return Qt.rect(0, 0, 0, 0)
                const p = gbar.mapToItem(gbarBg.sourceItem, 0, 0)
                return Qt.rect(p.x, p.y, gbar.width, gbar.height)
            }
            textureSize: Qt.size(Math.max(1, Math.round(gbar.width / 2)),
                                  Math.max(1, Math.round(gbar.height / 2)))
            live: true
            hideSource: false
        }
        // 圆角遮罩:clip 是矩形裁剪,管不到圆角;模糊层四角须用 mask 裁掉。
        Rectangle {
            id: gbarMask
            width: gbar.width
            height: gbar.height
            radius: gbar.radius
            visible: false
            layer.enabled: true
            layer.smooth: true
        }
        MultiEffect {
            anchors.fill: parent
            source: gbarBg
            maskEnabled: true
            maskSource: gbarMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
            autoPaddingEnabled: false
            blurEnabled: true
            blur: 1.0
            blurMax: 22
        }

        // 玻璃底色 + 描边。
        Rectangle {
            anchors.fill: parent
            color: gbar.glassColor
            radius: gbar.radius
            border.width: 1
            border.color: gbar.borderColor
        }
        // 顶部微光:与底色同形整圆,填充随自身 radius 裁切;
        // 半高胶囊做法顶角会伸出圆外(clip 是矩形裁剪,管不到圆角)。
        Rectangle {
            anchors.fill: parent
            radius: gbar.radius
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.08) }
                GradientStop { position: 0.5; color: "transparent" }
            }
        }

        default property alias content: gbarContent.data
        Item { id: gbarContent; anchors.fill: parent }
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
                color: gcb.hovered ? Qt.rgba(1, 1, 1, 0.14) : "transparent"
                Behavior on color { ColorAnimation { duration: 150 } }
            }
        }
        // contentItem 会被 Button 拉伸至全尺寸,图标须放进容器内居中才能保持小尺寸。
        // SVG 按显示尺寸×DPR 栅格化:避免大图降采样把细描边摊灰。
        contentItem: Item {
            Image {
                width: 14
                height: 14
                anchors.centerIn: parent
                source: gcb.iconName ? "qrc:/icons/" + gcb.iconName + ".svg" : ""
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
        Rectangle {
            id: cardContent
            anchors.fill: parent
            radius: Constants.homeHeroRadius
            color: "transparent"
            border.width: 0
            clip: true
            // 用 layer.effect 做透视(Qt 官方图片效果方式):本卡内容一次渲染进
            // layer 纹理,effect(ShaderEffect)采样透视——无独立 ShaderEffectSource,
            // Qt 保证不重复渲染(无双卡)。

            Image {
                id: cardImg
                anchors.fill: parent
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
                sourceSize.width: Math.max(1, Math.round(cardContent.width * Screen.devicePixelRatio))
                sourceSize.height: Math.max(1, Math.round(cardContent.height * Screen.devicePixelRatio))
                asynchronous: true
                retainWhileLoading: true
            }
            // 底部渐变,保证右下角文字可读
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: parent.height * 0.42
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.62) }
                }
            }
            // 文字区(仅中心卡显示;侧卡纯图):年份靠左、标题靠右、底部平齐。
            // 锚定只连兄弟/直接父(官方限制),故年份与标题共用一个容器 Item,
            // 各自 anchors.left/right 到容器两侧;容器单边锚+显式 height 合法,
            // 标题单边右锚+width 合法(elide 需要确定宽)。
            // 判中心卡不用 isCurrentItem(实测本 PathView 恒 false),
            // 用路径 tilt=0 + 浮点容差(吸附毫厘差不瞬间失显)。
            Item {
                visible: hcard.isCenter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                anchors.bottomMargin: 12
                height: titleText.height
                AppText {
                    id: yearText
                    visible: (hcard.modelData.year || 0) > 0
                    text: hcard.modelData.year || ""
                    color: Qt.rgba(1, 1, 1, 0.9)
                    font.pixelSize: Constants.homeHeroYearPx
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                }
                AppText {
                    id: titleText
                    text: hcard.modelData.name || ""
                    color: "white"
                    font.pixelSize: Constants.homeHeroTitlePx
                    font.bold: true
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, heroCar.cardW * 0.55)
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                }
            }
            // layer 效果:内容一次进 layer 纹理,effect 采样透视(无双卡)。
            // layer.samplerName 与 shader 采样名(src)一致;w/h 用本卡尺寸。
            // 侧卡经 scale + 透视倾斜是缩采样,双线性无 mipmap 文字会糊;
            // 2 倍超采样渲染进纹理,缩小后仍保持 1:1 以上采样密度。
            layer.enabled: true
            layer.samplerName: "src"
            // 侧卡(item 级 scale 变换)的降采样发生在 layer 纹理上:双线性会
            // 锯齿,mipmap 预滤波消除;2 倍超采样纹理本身缓解,两者叠加更干净。
            layer.smooth: true
            layer.mipmap: true
            // 2 倍超采样,量化 128px 步进:缩放时纹理尺寸不逐帧重建(重建闪烁)。
            layer.textureSize: Qt.size(Math.max(1, Math.round(cardContent.width * Screen.devicePixelRatio * 2 / 128) * 128),
                                       Math.max(1, Math.round(cardContent.height * Screen.devicePixelRatio * 2 / 128) * 128))
            layer.effect: ShaderEffect {
                property real sideTilt: hcard.tilt
                property real w: cardContent.width
                property real h: cardContent.height
                property real maxAngle: 38
                property real focal: 1100
                property real sideInset: 0
                property real meshDensity: 16
                mesh: Qt.size(16, 16)
                vertexShader: "qrc:/qt/qml/MoePlayer/Core/shaders/hero.vert.qsb"
                fragmentShader: "qrc:/qt/qml/MoePlayer/Core/shaders/hero.frag.qsb"
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
                    heroTimer.restart()
                }
            }
        }
    }
}
