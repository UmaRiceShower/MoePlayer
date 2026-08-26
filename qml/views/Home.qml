pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import MoePlayer.Core

//! 首页(主流平铺版):整页 Flickable 上下滚动;顶部导航固定。
//! 内容 = hero 轮播 + 每库一行(大库海报 + 条目卡片横向行)。
Item {
    id: root

    // 聚合行(所有账号的媒体库,顺序按账号排序)。
    property var rows: []
    property var pendingRows: []
    // hero 轮播(继续观看前 8,不足补最新添加前 8)。
    property var heroItems: []
    property int heroIndex: 0
    readonly property real navH: 48
    readonly property real heroH: Math.min(380, (parent ? parent.height : 720) * 0.42)

    signal showDetail(string itemId, string posterId, string title, string serverUrl)
    signal openLibrary(string viewId, string serverUrl, string viewName)
    signal openServerManager()
    signal openSettings()
    signal openSearch()

    // 聚合 hero 轮播数据(继续观看优先,不足补最新添加)。
    function rebuildTop() {
        const all = []
        for (const row of root.rows) {
            const sv = row.serverUrl || ""
            for (const it of (row.items || [])) {
                const m = Object.assign({}, it)
                m.serverUrl = sv
                all.push(m)
            }
        }
        const cw = all.filter(function (i) {
            return i.positionTicks > 0 && !i.played && i.runtimeTicks > 0
        })
        cw.sort(function (a, b) {
            return (b.playbackDateTicks || 0) - (a.playbackDateTicks || 0)
        })
        const cwTop = cw.slice(0, 8)
        root.heroItems = cwTop.length > 0 ? cwTop : all.slice(0, 8)
    }

    Component.onCompleted: {
        if (AccountManager.hasAccounts) {
            AccountManager.fetchHomeRows(Constants.homePerLibraryLimit)
            AccountManager.validateTokens()
        }
    }
    onRowsChanged: root.rebuildTop()

    // rows 更新门控(账号增删/重登时 pendingRows 可能连续刷新,合并后一次替换)。
    Timer {
        id: rowsTimer
        onTriggered: root.rows = root.pendingRows
        interval: 40
        repeat: false
    }
    Connections {
        target: AccountManager
        function onHomeRowsReady() {
            root.pendingRows = AccountManager.homeRows
            rowsTimer.restart()
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
            anchors.leftMargin: 20
            anchors.verticalCenter: parent.verticalCenter
            text: "MoePlayer"
            color: Theme.textPrimary
            font.pixelSize: 22
            font.bold: true
        }
        // 圆形图标按钮(透明背景,hover 淡底;去除文字/色块,仅图标)。
        Row {
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 12
            GlassIconButton { iconName: "search"; onClicked: root.openSearch() }
            GlassIconButton { iconName: "server"; onClicked: root.openServerManager() }
            GlassIconButton { iconName: "settings"; onClicked: root.openSettings() }
        }
    }

    // 整页可滚动(主流:hero + 所有库行随页面上下滚动)。
    Flickable {
        id: page
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        contentWidth: width
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        contentHeight: pageCol.childrenRect.height
        Column {
            id: pageCol
            width: page.width

            // ---- hero 卡片轮播:三卡可视,中间 16:9,两侧倾斜缩小 ----
            Item {
                id: heroCar
                height: root.heroH
                width: parent.width
                visible: root.heroItems.length > 0
                clip: false
                readonly property real cardH: height * 0.74
                readonly property real cardW: Math.min(cardH * 16 / 9, width * 0.56)

                PathView {
                    id: heroPv
                    anchors.fill: parent
                    model: root.heroItems
                    pathItemCount: 3
                    preferredHighlightBegin: 0.5
                    preferredHighlightEnd: 0.5
                    highlightRangeMode: PathView.StrictlyEnforceRange
                    snapMode: PathView.SnapOneItem
                    interactive: false

                    path: Path {
                        startX: heroCar.width * 0.12
                        startY: heroCar.height * 0.5
                        PathAttribute { name: "itemScale"; value: 0.72 }
                        PathAttribute { name: "tilt"; value: 1 }
                        PathAttribute { name: "itemZ"; value: 0 }
                        PathLine { x: heroCar.width * 0.5; y: heroCar.height * 0.5 }
                        PathAttribute { name: "itemScale"; value: 1.0 }
                        PathAttribute { name: "tilt"; value: 0 }
                        PathAttribute { name: "itemZ"; value: 2 }
                        PathLine { x: heroCar.width * 0.88; y: heroCar.height * 0.5 }
                        PathAttribute { name: "itemScale"; value: 0.72 }
                        PathAttribute { name: "tilt"; value: -1 }
                        PathAttribute { name: "itemZ"; value: 0 }
                    }
                    delegate: HeroCard {}
                }

                // 底部渐变已移除:文字用描边保证可读,卡片保持清晰亮度。

                // 圆点指示+hover/点击切换。
                Row {
                    z: 7
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 10
                    spacing: 8
                    Repeater {
                        model: root.heroItems.length
                        delegate: Rectangle {
                            required property int index
                            id: dot
                            width: heroPv.currentIndex === index ? 14 : 7
                            height: 7
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
                    interval: 5000
                    repeat: true
                    running: root.heroItems.length > 1
                    onTriggered: heroPv.currentIndex = (heroPv.currentIndex + 1) % root.heroItems.length
                }
            }

            // ---- 每库一行:大库海报 + 条目卡片横向行 ----
            Repeater {
                model: root.rows
                delegate: LibraryRow {
                    width: pageCol.width
                }
            }
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

    // 库行(一个媒体库):大库海报(行首)+ 该库条目横向卡片行。
    component LibraryRow: Column {
        id: libRow
        required property var modelData
        width: parent ? parent.width : 0
        height: Constants.rowHeight + 20
        spacing: 14
        Row {
            anchors.left: parent.left
            anchors.leftMargin: Constants.rowLeftMargin
            spacing: Constants.rowSpacing
            // 大库海报:图片 + 底部"服名 · 库名"文字。
            RowCard {
                modelData: libRow.modelData
                index: -1
                cardImage: libRow.modelData.posterId || ""
                cardText: (libRow.modelData.serverName !== ""
                           ? libRow.modelData.serverName + " · " : "") + libRow.modelData.viewName
                isLibrary: true
                cardW: Constants.rowLibraryW
                cardH: Constants.rowHeight
                cardArea.onClicked: root.openLibrary(libRow.modelData.viewId,
                                                      libRow.modelData.serverUrl,
                                                      libRow.modelData.viewName)
            }
            // 条目卡片横向行(鼠标拖拽横向滚动)。
            ListView {
                id: rowItems
                width: libRow.width - Constants.rowLeftMargin - Constants.rowLibraryW - Constants.rowSpacing
                height: Constants.rowHeight
                orientation: ListView.Horizontal
                spacing: Constants.rowSpacing
                clip: true
                model: libRow.modelData.items
                delegate: Item {
                    required property var modelData
                    required property int index
                    width: Constants.rowCardW
                    height: Constants.rowHeight
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
                                                   parent.modelData.name, libRow.modelData.serverUrl)
                    }
                }
            }
        }
    }

    // 玻璃态圆形图标按钮:半透明白 + 白边框 + 顶部高光(近似液态玻璃)。
    component GlassIconButton: Button {
        id: gbtn
        property string iconName: ""
        width: 36
        height: 36
        padding: 0
        background: Item {
            // 液态玻璃:极透底 + 细透边框 + 顶部椭圆高光 + 底部内暗影(立体感)。
            Rectangle {
                id: body
                anchors.fill: parent
                radius: height / 2
                color: gbtn.hovered ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(1, 1, 1, 0.07)
                border.width: 1
                border.color: gbtn.hovered ? Qt.rgba(1, 1, 1, 0.48) : Qt.rgba(1, 1, 1, 0.26)
                clip: true
                // 顶部椭圆高光:柔和、半透明,模拟玻璃顶缘反射。
                Rectangle {
                    anchors.top: parent.top
                    anchors.topMargin: 1
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width * 0.66
                    height: parent.height * 0.5
                    radius: width / 2
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, gbtn.hovered ? 0.34 : 0.18) }
                        GradientStop { position: 0.6; color: Qt.rgba(1, 1, 1, gbtn.hovered ? 0.10 : 0.05) }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                }
                // 底部内暗影:增强玻璃厚度感(底部略暗)。
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: parent.height * 0.4
                    radius: height / 2
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.18) }
                    }
                }
            }
        }
        contentItem: Image {
            width: 15
            height: 15
            anchors.centerIn: parent
            source: gbtn.iconName ? "qrc:/icons/" + gbtn.iconName + ".svg" : ""
            fillMode: Image.PreserveAspectFit
            // 通透感:图标纯白、柔和、略缩(36px 圆内 15px,留足边距)。
            smooth: true
            opacity: 0.96
        }
    }

    // 库海报卡(大):图片 + 底部文字,点击上抛由使用方路由。
    component RowCard: Rectangle {
        id: rowCard
        required property var modelData
        required property int index
        property string cardImage: ""
        property string cardText: ""
        property bool isLibrary: false
        property bool selected: false
        property int cardW: Constants.rowCardW
        property int cardH: Constants.rowHeight
        property alias cardArea: cardArea
        width: cardW
        height: cardH
        color: Theme.surface
        radius: 14
        CrossfadeImage {
            anchors.fill: parent
            anchors.leftMargin: 5
            anchors.rightMargin: 5
            anchors.topMargin: 5
            anchors.bottomMargin: 24
            cornerRadius: 14
            duration: 0
            source: rowCard.cardImage !== "" ? "image://emby/" + rowCard.cardImage : ""
            fillMode: Image.PreserveAspectCrop
            cache: true
            asynchronous: true
        }
        AppText {
            visible: rowCard.cardImage === ""
            anchors.centerIn: parent
            text: rowCard.cardText
            color: Theme.textPrimary
            font.pixelSize: 16
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
            anchors.bottomMargin: 4
            text: rowCard.cardText
            color: Theme.textPrimary
            font.pixelSize: 13
            font.bold: rowCard.isLibrary
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
        }
        MouseArea {
            id: cardArea
            anchors.fill: parent
            hoverEnabled: true
        }
    }

    component HeroCard: Item {
        id: hcard
        required property var modelData
        required property int index
        width: heroCar.cardW
        height: heroCar.cardH
        scale: PathView.onPath ? PathView.itemScale : 0.78
        z: PathView.onPath ? PathView.itemZ : 0
        property real tilt: PathView.onPath ? PathView.tilt : 0

        // 卡片整体(图片 + 底部渐变 + 文字)被 ShaderEffectSource 抓取成纹理,
        // 再由 ShaderEffect 做透视映射——文字随卡片一起倾斜。
        Rectangle {
            id: cardContent
            anchors.fill: parent
            radius: 16
            color: "transparent"
            border.width: 0
            clip: true
            opacity: 0

            Image {
                id: cardImg
                anchors.fill: parent
                source: {
                    const m = hcard.modelData
                    const id = m.backdropId || m.parentBackdropId || m.posterId || ""
                    return id ? "image://emby/" + id : ""
                }
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 1280
                sourceSize.height: 720
                asynchronous: true
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
            // 右下角标题/年份
            Column {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.rightMargin: 12
                anchors.bottomMargin: 12
                width: parent.width * 0.85
                spacing: 2
                AppText {
                    width: parent.width
                    text: hcard.modelData.name || ""
                    color: "white"
                    font.pixelSize: 13
                    font.bold: true
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignRight
                }
                AppText {
                    visible: (hcard.modelData.year || 0) > 0
                    text: hcard.modelData.year || ""
                    color: Qt.rgba(1, 1, 1, 0.9)
                    font.pixelSize: 11
                    horizontalAlignment: Text.AlignRight
                }
            }
        }
        ShaderEffectSource {
            id: effectSource
            width: cardContent.width
            height: cardContent.height
            sourceItem: cardContent
            live: true
            hideSource: false
            opacity: 0
            enabled: false
        }
        ShaderEffect {
            anchors.fill: parent
            property variant src: effectSource
            property real sideTilt: hcard.tilt
            property real w: parent.width
            property real h: parent.height
            property real maxAngle: 38
            property real focal: 1100
            property real sideInset: 0
            property real meshDensity: 32
            mesh: Qt.size(32, 32)
            vertexShader: "qrc:/qt/qml/MoePlayer/Core/shaders/hero.vert.qsb"
            fragmentShader: "qrc:/qt/qml/MoePlayer/Core/shaders/hero.frag.qsb"
        }
        MouseArea {
            anchors.fill: parent
            onClicked: {
                if (PathView.isCurrentItem) {
                    root.showDetail(hcard.modelData.id, hcard.modelData.posterId || "",
                                    hcard.modelData.name, hcard.modelData.serverUrl)
                } else {
                    heroPv.currentIndex = hcard.index
                    heroTimer.restart()
                }
            }
        }
    }
}
