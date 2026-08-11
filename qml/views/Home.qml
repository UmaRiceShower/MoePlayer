import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import "qrc:/qml/theme"

//! 首页:每行一个媒体库,行首为库海报,后面是该库按加入时间倒序的最近条目。
//! 中间一行最大,上下行尺寸与透明度逐级递减(透视感)。
//! 点击条目进详情;库海报点击进媒体库页(暂推默认库,后续调整)。
Item {
    id: root

    signal showDetail(string itemId, string posterId, string title)
    signal openLibrary()
    // 打开服务器管理页(未登录提示条入口)。
    signal openServerManager()

    // 聚合行(所有账号的媒体库,顺序按服务器管理中的账号排序)。
    property var rows: AccountManager.homeRows
    // 循环模型:rows 复制 3 份,始终在中间副本内滚动,边界时跳回中间副本,
    // 实现无限循环(网上通用做法:首尾复制模型作缓冲)。
    property var loopRows: []
    // 跨服导航:等待账号切换成功后再执行的跳转(见 ensureAccount)。
    property var pendingNav: null

    function rebuildLoop() {
        root.loopRows = root.rows.concat(root.rows).concat(root.rows)
        // 中间副本第 1 行初始居中(第一个媒体库即可在中间)。
        if (root.rows.length > 0)
            list.positionViewAtIndex(root.rows.length, ListView.Center)
    }

    // 行点击目标账号与当前会话一致则立即执行,否则先切换账号再执行。
    // 行跨服时切换会话后详情/媒体库页按该服数据打开。
    function ensureAccount(accountId, action) {
        if (accountId === "" || accountId === AccountManager.activeAccountId) {
            action()
            return
        }
        root.pendingNav = action
        AccountManager.switchAccount(accountId)
    }

    // 聚合拉取不依赖当前会话(每服用各自缓存的 token),有账号即拉;
    // 账号增删/排序变化(accountsChanged)时按新顺序重拉。
    Component.onCompleted: {
        if (AccountManager.hasAccounts)
            AccountManager.fetchHomeRows(7)
    }

    // 未登录提示条:没有任何已保存账号时覆盖在首页上方,提供服务器管理入口。
    Rectangle {
        visible: !AccountManager.hasAccounts
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: 16
        width: Math.min(420, parent.width - 32)
        height: 44
        radius: 8
        color: Theme.surface
        border.width: 1
        border.color: Theme.accent

        Row {
            anchors.centerIn: parent
            spacing: 12
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "未添加服务器，添加后即可浏览媒体库"
                color: Theme.textPrimary
                font.pixelSize: 13
            }
            Button {
                text: "服务器管理"
                onClicked: root.openServerManager()
            }
        }
    }

    Connections {
        target: AccountManager
        function onHomeRowsReady() {
            root.rows = AccountManager.homeRows
            root.rebuildLoop()
        }
        function onAccountsChanged() {
            if (AccountManager.hasAccounts)
                AccountManager.fetchHomeRows(7)
        }
        function onAccountLoginFinished(ok) {
            if (ok && root.pendingNav) {
                const nav = root.pendingNav
                root.pendingNav = null
                nav()
            } else if (!ok) {
                root.pendingNav = null
            }
        }
    }
    onRowsChanged: if (root.rows.length > 0) root.rebuildLoop()

    // 每行条目卡片(库海报或媒体条目)。
    component RowCard: Rectangle {
        property string cardImage: ""
        property string cardText: ""
        property bool isLibrary: false
        property alias cardArea: cardArea
        width: isLibrary ? 92 : 88
        height: isLibrary ? 128 : 122
        color: Theme.surface
        radius: 8
        border.width: cardArea.hovered ? 2 : 0
        border.color: Theme.accent
        Image {
            anchors.fill: parent
            anchors.margins: 4
            source: cardImage !== "" ? "image://emby/" + cardImage : ""
            fillMode: Image.PreserveAspectCrop
            cache: true
        }
        Text {
            visible: cardImage === ""
            anchors.centerIn: parent
            text: cardText
            color: Theme.textPrimary
            font.pixelSize: isLibrary ? 15 : 11
            font.bold: isLibrary
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            width: parent.width - 8
            wrapMode: Text.Wrap
        }
        MouseArea {
            id: cardArea
            anchors.fill: parent
            hoverEnabled: true
        }
    }

    // 轮盘选择:ListView 垂直滚动,当前项(highlight)强制居中;
    // 每行缩放/透明度由"行中心到视口中心的距离"动态决定(中间最大,
    // 两端逐级缩小变暗),滚轮/拖拽滚动,任意行(含第一个媒体库)可滚到中间。
    ListView {
        id: list
        anchors.fill: parent
        clip: true
        model: root.loopRows
        spacing: 12
        // 不强制 highlight 居中:由滚轮手动控制 contentY 并做无缝循环,
        // StrictlyEnforceRange 会拉回手动跳转位置导致边界不可达。
        highlightRangeMode: ListView.NoHighlightRange
        snapMode: ListView.SnapToItem

        delegate: Column {
            id: rowDelegate
            width: list.width
            transformOrigin: Item.Top
            // 行数据快照:modelData 是委托上下文变量,不能作为对象属性
            // (rowDelegate.modelData)访问;存入显式属性供嵌套卡片取行级信息。
            property var rowData: modelData
            // 行中心到视口中心的距离(随滚动变化)驱动缩放与透明度。
            function centerDist() {
                const centerY = rowDelegate.y + rowDelegate.height / 2 - list.contentY
                return Math.abs(centerY - list.height / 2)
            }
            scale: {
                const maxDist = Math.max(1, list.height / 2 - 60)
                return Math.max(0.5, 1 - 0.16 * rowDelegate.centerDist() / maxDist)
            }
            opacity: {
                const maxDist = Math.max(1, list.height / 2 - 60)
                return Math.max(0.25, 1 - 0.75 * rowDelegate.centerDist() / maxDist)
            }

            // 行标题:服务器名 - 媒体库名(同一服务器多库时区分来源)。
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: modelData.serverName !== ""
                        ? modelData.serverName + " - " + modelData.viewName
                        : modelData.viewName
                color: Theme.textPrimary
                font.pixelSize: 14
                font.bold: true
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 10
                // 库海报(行首)
                RowCard {
                    cardImage: modelData.posterId || ""
                    cardText: modelData.viewName
                    isLibrary: true
                    cardArea.onClicked: root.ensureAccount(modelData.accountId,
                        function () { root.openLibrary() })
                }
                // 该库最近条目
                Repeater {
                    model: modelData.items
                    delegate: RowCard {
                        cardImage: modelData.posterId || ""
                        cardText: modelData.name
                        // 内层 modelData 是条目,行级 accountId 从 rowData 取。
                        cardArea.onClicked: root.ensureAccount(rowDelegate.rowData.accountId,
                            function () {
                                root.showDetail(modelData.id, modelData.posterId || "",
                                                modelData.name)
                            })
                    }
                }
            }
        }
    }

    // 滚轮无缝循环:contentY 越界时按模型长度取余回绕(同步生效,
    // 按住滚轮连续滚动时每格立即循环,不会等松手才跳转)。
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton // 不拦截点击,只接收滚轮
        onWheel: function (wheel) {
            if (root.rows.length === 0)
                return
            const maxY = list.contentHeight - list.height
            let newY = list.contentY - wheel.angleDelta.y * 0.6
            if (newY > maxY)
                newY = newY - maxY // 滚过末行 → 从首行继续
            else if (newY < 0)
                newY = maxY + newY // 滚过首行 → 从末行继续
            list.contentY = newY
            wheel.accepted = true
        }
    }
}
