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
    readonly property int topBarH: 108

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

    // ============================= 信号 =============================

    signal showDetail(string itemId, string posterId, string title, string serverUrl, string accountId)
    signal backRequested()

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
    // 缩略图:行内是 16:9 框,优先取 16:9 图源 —— backdropId 对分集是父剧背景、
    // 对影片是自身背景;两者都没有时回退自身 posterId(2:3 海报会裁切)。
    function thumbSource(it) {
        const key = (it.backdropId || "") !== "" ? it.backdropId : (it.posterId || "")
        return key === "" ? "" : "image://emby/" + key
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
            if (!it || !it.modelData || it.modelData.kind !== "item")
                continue
            if (it.y + it.height > y)
                return { key: it.modelData.key, delta: y - it.y }
        }
        return null
    }
    function restoreAnchor(anchor) {
        if (!anchor)
            return
        for (let i = 0; i < root.rows.length; ++i) {
            if (root.rows[i].kind === "item" && root.rows[i].key === anchor.key) {
                list.positionViewAtIndex(i, ListView.Beginning)
                list.contentY = Math.max(0, list.contentY + anchor.delta)
                return
            }
        }
    }
    // 重建行模型:allItems() 已按(上次播放时间倒序, 服务器顺序)排好,
    // 故同桶条目连续,扫一遍即可分组;重建前记锚点、重建后恢复滚动位置。
    // keepPosition=false:条目集合整体变化(如切换账号过滤),不沿用锚点、由调用方回顶。
    function rebuildRows(keepPosition) {
        const anchor = keepPosition ? root.currentAnchor() : null
        const out = []
        let bucket = -1
        let header = null
        for (const it of PlaybackHistory.allItems()) {
            if (root.filterAccountId !== "" && (it.accountId || "") !== root.filterAccountId)
                continue
            const b = dayBucket(it.lastPlayedAt || 0)
            if (b !== bucket) {
                bucket = b
                header = { kind: "header", label: bucketLabel(b), count: 0, key: "h" + b }
                out.push(header)
            }
            ++header.count
            out.push({
                kind: "item",
                key: it.scope + "|" + it.id,
                itemId: it.id || "",
                posterId: it.posterId || "",
                serverUrl: it.serverUrl || "",
                accountId: it.accountId || "",
                title: itemTitle(it),
                sub: itemSub(it),
                account: accountName(it),
                time: timeText(it.lastPlayedAt || 0, b),
                status: statusText(it),
                progress: progressRatio(it),
                thumb: thumbSource(it)
            })
        }
        root.rows = out
        let headers = 0
        for (const r of out) {
            if (r.kind === "header")
                ++headers
        }
        root.itemCount = out.length - headers
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

    // 返回:Alt+←(与详情页同一约定;仅本页可见时生效)。
    Shortcut {
        sequences: ["Alt+Left"]
        enabled: root.visible
        onActivated: root.backRequested()
    }

    // ============================= 子对象 =============================

    // ---- 顶部条:标题 + 条数 ----
    Rectangle {
        id: topBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: root.pageMargin
        height: root.topBarH
        radius: 14
        color: Qt.rgba(0.07, 0.08, 0.11, 0.72)
        border.width: 1
        border.color: Qt.rgba(Constants.moePink.r, Constants.moePink.g, Constants.moePink.b, 0.22)

        Row {
            id: titleRow
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.top: parent.top
            anchors.topMargin: 12
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
                text: root.itemCount + " 条 · 最近播放在前"
                color: Theme.textMuted
                font.pixelSize: 12
            }
        }
        // 账号过滤:全部 / 单账号(与全局搜索的目标选择同一交互约定)
        Row {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.top: titleRow.bottom
            anchors.topMargin: 10
            spacing: 8
            clip: true
            FilterChip {
                label: "全部"
                active: root.filterAccountId === ""
                showHeart: false
                onClicked: root.filterAccountId = ""
            }
            Repeater {
                model: root.accountOptions
                delegate: FilterChip {
                    required property var modelData
                    label: modelData.name
                    active: root.filterAccountId === modelData.id
                    showHeart: false
                    onClicked: root.filterAccountId = (root.filterAccountId === modelData.id
                                                       ? "" : modelData.id)
                }
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
            height: modelData.kind === "header" ? root.headerH : root.rowH + root.rowGap

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

            // 条目行
            Rectangle {
                id: card
                width: parent.width
                height: root.rowH
                visible: rowItem.modelData.kind !== "header"
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
            text: root.filterAccountId !== ""
                  ? "该账号还没有播放记录"
                  : (AccountManager.accounts.length === 0
                     ? "先在「服务器管理」里添加 Emby 服务器"
                     : "播放过的条目会出现在这里")
            color: Theme.textMuted
            font.pixelSize: 12
        }
    }
}
