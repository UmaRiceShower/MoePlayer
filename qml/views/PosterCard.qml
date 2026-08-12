import QtQuick
import QtQuick.Controls
import "qrc:/qml/theme"

//! 通用海报卡片(媒体库网格/搜索浮层共用):海报 + 评分/已看/未看集数角标
//! + 观看进度条 + 悬停收藏/已看快捷操作。点击进详情;操作经信号上抛,
//! 由使用方调模型翻转(不依赖行号)。
Item {
    id: root

    // 条目数据(由使用方从模型角色绑定)。
    property string itemId: ""
    property string posterId: ""
    property string title: ""
    property int year: 0
    property real rating: 0
    property bool played: false
    property bool favorite: false
    property real positionTicks: 0
    property real runtimeTicks: 0
    property int unplayedCount: 0
    property string itemType: ""
    // 悬停快捷操作开关(搜索结果等轻量场景可关)。
    property bool showActions: true

    // 点击卡片(进详情)。
    signal clicked()
    // 悬停操作:收藏/已看切换请求(useById 翻转)。
    signal favoriteRequested(string itemId, bool fav)
    signal watchedRequested(string itemId, bool played)

    Rectangle {
        anchors.fill: parent
        color: Theme.surface
        radius: 8
        clip: true

        Image {
            id: posterImg
            anchors.fill: parent
            anchors.margins: 4
            source: root.posterId ? "image://emby/" + root.posterId : ""
            fillMode: Image.PreserveAspectCrop
            cache: true
            asynchronous: true
            // 仅 Ready 可见:加载中露卡片底色,失败隐藏(配合 fallback 图标)。
            visible: status === Image.Ready
            opacity: 0
            // 成功淡入;失败走 fallback。
            onStatusChanged: {
                if (status === Image.Ready)
                    fadeIn.restart()
            }
        }
        // 加载成功淡入,避免图片突然出现。
        NumberAnimation {
            id: fadeIn
            target: posterImg
            property: "opacity"
            to: 1
            duration: 200
        }

        // 无主图或加载失败:类型占位图标,不显示空卡(对照上游 404 契约)。
        Text {
            visible: root.posterId === "" || posterImg.status === Image.Error
            anchors.centerIn: parent
            text: root.itemType === "Series" ? "▦" : "▶"
            color: Theme.textMuted
            font.pixelSize: 40
            opacity: 0.5
        }

        // 底部渐变遮罩,提升标题可读性。
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 46
            gradient: Gradient {
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.72) }
            }
        }

        // 标题 + 年份(第二行小字,避免长标题截断年份)。
        Column {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottomMargin: 6
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 1
            Text {
                width: parent.width
                text: root.title
                color: Theme.textPrimary
                font.pixelSize: 13
                elide: Text.ElideRight
            }
            Text {
                visible: root.year > 0
                width: parent.width
                text: root.year
                color: Theme.textMuted
                font.pixelSize: 11
            }
        }

        // 观看进度条(位置/时长随列表 UserData 返回,零额外请求)。
        Rectangle {
            visible: root.positionTicks > 0 && root.runtimeTicks > 0
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 3
            color: Qt.rgba(1, 1, 1, 0.25)
            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: parent.width * Math.min(1, root.positionTicks / root.runtimeTicks)
                color: Theme.accent
            }
        }

        // 左上:评分角标(Emby 评分 0-10)。
        Rectangle {
            visible: root.rating >= 0.5
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: 8
            height: 22
            width: ratingRow.implicitWidth + 12
            radius: 4
            color: Qt.rgba(0, 0, 0, 0.6)
            Row {
                id: ratingRow
                anchors.centerIn: parent
                spacing: 3
                Text {
                    text: "★"
                    color: "#ffd33d"
                    font.pixelSize: 12
                }
                Text {
                    text: root.rating.toFixed(1)
                    color: Theme.textPrimary
                    font.pixelSize: 12
                }
            }
        }

        // 右上:已看绿勾 / 剧集未看集数蓝标。
        Rectangle {
            visible: root.played || (root.itemType === "Series" && root.unplayedCount > 0)
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 8
            height: 22
            width: stateRow.implicitWidth + 12
            radius: 4
            color: root.played ? "#2ea043" : "#1f6feb"
            Row {
                id: stateRow
                anchors.centerIn: parent
                spacing: 3
                Text {
                    text: root.played ? "✓ 已看"
                         : (root.unplayedCount >= 100 ? "99+ 未看"
                            : root.unplayedCount + " 未看")
                    color: "#ffffff"
                    font.pixelSize: 12
                }
            }
        }
    }

    HoverHandler {
        id: cardHover
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.clicked()
    }

    // 悬停快捷操作:♥ 收藏 / ✓ 已看切换,置于最上层(MouseArea 之后声明)。
    Row {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: 36
        anchors.rightMargin: 8
        visible: root.showActions && cardHover.hovered
        spacing: 6
        Button {
            width: 30
            height: 30
            padding: 0
            background: Rectangle { radius: 15; color: "#000000aa" }
            contentItem: Text {
                text: root.favorite ? "♥" : "♡"
                color: root.favorite ? "#f778ba" : "#ffffff"
                font.pixelSize: 16
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
            onClicked: root.favoriteRequested(root.itemId, !root.favorite)
        }
        Button {
            width: 30
            height: 30
            padding: 0
            background: Rectangle { radius: 15; color: root.played ? "#2ea043" : "#000000aa" }
            contentItem: Text {
                text: "✓"
                color: "#ffffff"
                font.pixelSize: 15
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
            onClicked: root.watchedRequested(root.itemId, !root.played)
        }
    }
}
