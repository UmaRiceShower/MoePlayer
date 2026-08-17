import QtQuick
import QtQuick.Controls
import MoePlayer.Core

//! 通用海报卡片(媒体库网格/搜索浮层共用):海报 + 评分/已看/未看集数角标
//! + 观看进度条。右上角标 hover 显示"标记未看/已看"、点击切换已看;
//! 右下收藏按钮(已收藏常显,未收藏悬停浮现)。点击进详情;操作经信号上抛,
//! 由使用方调模型翻转(不依赖行号)。
Item {
    id: root

    // delegate 用法下由 GridView/ListView 注入,使用方在实例上经
    // model.<角色> 读取条目;required 声明让 qmllint 静态识别
    // (C++ 模型角色无法从类型推导,未声明则报 unqualified)。
    required property var model
    required property int index
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

    // 海报莫奈取色:底部渐变氛围尾色与进度条强调色跟随海报。
    // 命令式更新 + colorReady(posterId) 信号:QML 绑定 colors 属性会在
    // 任意海报取色完成时全量重算所有卡(colorsChanged 无参数);按 id
    // 过滤信号只更新本卡。取色未完成/失败保持回退色。
    property color heroFrom: Theme.surface
    property color accentColor: Theme.accent
    // 卡片底色藏色:带海报色相倾向,取代中性灰。
    property color surfaceTint: Theme.surface

    function applyMonet() {
        // 无条件赋值:取色未完成/失败或配置关闭时显示回退色,Grid 回收
        // 复用时不会残留上一张海报的颜色(早退会导致新卡沿用旧卡取色)。
        let c = null
        if (ConfigManager.monetEnabled)
            c = ColorProvider.colors[root.posterId]
        if (c) {
            root.heroFrom = c.heroFrom
            root.accentColor = c.accent
            root.surfaceTint = c.surfaceTint
        } else {
            root.heroFrom = Theme.surface
            root.accentColor = Theme.accent
            root.surfaceTint = Theme.surface
        }
    }

    // 点击卡片(进详情)。
    signal clicked()
    // 悬停操作:收藏/已看切换请求(useById 翻转)。
    signal favoriteRequested(string itemId, bool fav)
    signal watchedRequested(string itemId, bool played)
    onPosterIdChanged: {
        root.applyMonet()
        if (ConfigManager.monetEnabled)
            ColorProvider.requestColor(root.posterId)
    }
    Component.onCompleted: {
        root.applyMonet()
        if (ConfigManager.monetEnabled)
            ColorProvider.requestColor(root.posterId)
    }
    Connections {
        target: ColorProvider
        function onColorReady(posterId) {
            if (posterId === root.posterId)
                root.applyMonet()
        }
    }

    Rectangle {
        anchors.fill: parent
        color: root.surfaceTint
        radius: 14
        clip: true

        // CrossfadeImage:圆角在绘制层裁切(Item::clip 只裁矩形;Rectangle
        // radius 不影响子项)。duration 0 = delegate 复用瞬时切换,无动画开销。
        CrossfadeImage {
            id: posterImg
            anchors.fill: parent
            cornerRadius: 14
            source: root.posterId ? "image://emby/" + root.posterId : ""
            fillMode: Image.PreserveAspectCrop
            cache: true
            asynchronous: true
            // 网格滚动 delegate 复用:禁用替换动画(duration 0 = 瞬时切换)。
            duration: 0
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
        AppText {
            visible: root.posterId === "" || posterImg.status === Image.Error
            anchors.centerIn: parent
            text: root.itemType === "Series" ? "▦" : "▶"
            color: Theme.textMuted
            font.pixelSize: 40
            opacity: 0.5
        }

        // 底部渐变遮罩,提升标题可读性;尾色跟随海报莫奈色(氛围统一)。
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 46
            gradient: Gradient {
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 1.0; color: Qt.rgba(root.heroFrom.r, root.heroFrom.g, root.heroFrom.b, 0.72) }
            }
        }

        // 标题 + 年份(第二行小字,避免长标题截断年份)。
        // 右侧锚到收藏按钮左侧,右下角按钮(常显/悬停浮现)不遮标题。
        Column {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: favBtn.left
            anchors.bottomMargin: 6
            anchors.leftMargin: 8
            anchors.rightMargin: 4
            spacing: 1
            AppText {
                width: parent.width
                text: root.title
                color: Theme.textPrimary
                font.pixelSize: 13
                elide: Text.ElideRight
            }
            AppText {
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
                color: root.accentColor
                Behavior on color { ColorAnimation { duration: Constants.animMaxMs } }
            }
        }

        // 收藏:右下角圆形按钮,浮于标题/进度条之上(同父内最后声明,顶层)。
        // 已收藏常显;未收藏悬停卡片时浮现。点击翻转收藏(useById)。
        // 必须与标题 Column 同父(anchors 只允许父/兄弟目标)。
        Button {
            id: favBtn
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: 8
            anchors.bottomMargin: 8
            width: 30
            height: 30
            padding: 0
            visible: root.showActions && (root.favorite || cardHover.hovered)
            onClicked: root.favoriteRequested(root.itemId, !root.favorite)
            background: Rectangle { radius: 15; color: Theme.overlayBg }
            contentItem: AppText {
                text: root.favorite ? "♥" : "♡"
                color: root.favorite ? Theme.favorite : Theme.textOnBadge
                font.pixelSize: 16
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
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
            color: Theme.badgeBg
            Row {
                id: ratingRow
                anchors.centerIn: parent
                spacing: 3
                AppText {
                    text: "★"
                    color: Theme.rating
                    font.pixelSize: 12
                }
                AppText {
                    text: root.rating.toFixed(1)
                    color: Theme.textPrimary
                    font.pixelSize: 12
                }
            }
        }

        // 右上:状态角标(所有卡片常显,提供标记已看入口)。
        // 已看 → 绿勾;剧集有未看集数 → 蓝标;其余未看 → 中性"未看"。
        // showActions 时 hover 显示操作文案("标记未看/已看"),点击切换已看;
        // 轻量场景(搜索)保持纯状态展示。
        Rectangle {
            id: stateBadge
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 8
            height: 22
            width: stateRow.implicitWidth + 12
            radius: 4
            color: root.played ? Theme.success
                 : (root.itemType === "Series" && root.unplayedCount > 0 ? Theme.info : Theme.info)
            Row {
                id: stateRow
                anchors.centerIn: parent
                spacing: 3
                AppText {
                    // hover 文案由本角标内的 HoverHandler 驱动:
                    // hovered 只在鼠标位于 parent(角标)边界内时为 true,
                    // 精确命中角标区域(cardHover 是整卡范围,已弃用)。
                    text: stateBadgeHover.hovered && root.showActions
                          ? (root.played ? "标记未看" : "标记已看")
                          : (root.played ? "✓ 已看"
                             : (root.itemType === "Series" && root.unplayedCount > 0
                                ? (root.unplayedCount >= 100 ? "99+ 未看"
                                   : root.unplayedCount + " 未看")
                                : "未看"))
                    color: root.played ? Theme.textOnBadge
                         : (root.itemType === "Series" && root.unplayedCount > 0
                            ? Theme.textOnBadge : Theme.textPrimary)
                    font.pixelSize: 12
                }
            }
            // Pointer Handler 体系(与卡片 root 同机制,不依赖 MouseArea
            // hover 事件):HoverHandler 精确命中角标区域(边界内)驱动文案
            // 与手型;TapHandler 用 ReleaseWithinBounds(按下即 exclusive
            // grab),阻止卡片 root 的 TapHandler(进详情)同时触发。
            // enabled 门控 showActions:轻量场景(搜索)禁用后不参与命中,
            // 点击正常落到卡片进详情,角标保持纯展示。
            HoverHandler {
                id: stateBadgeHover
                enabled: root.showActions
                cursorShape: root.showActions ? Qt.PointingHandCursor : Qt.ArrowCursor
            }
            TapHandler {
                enabled: root.showActions
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: root.watchedRequested(root.itemId, !root.played)
            }
        }
    }

    HoverHandler {
        id: cardHover
    }

    // 点击进详情:TapHandler(Pointer Handler 体系,与 HoverHandler 一致;
    // 官方推荐替代 MouseArea 做点击检测)。
    TapHandler {
        onTapped: root.clicked()
    }
}
