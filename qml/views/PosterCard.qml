import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import QtQuick.Effects
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
    // 数据经显式绑定(itemId/posterId/…)输入;model/index 是 Grid/List
    // delegate 标识(Library/Search 作网格 delegate 用),非必需——Home
    // 行卡可直接绑属性而不传 model/index。
    property var model: undefined
    property int index: -1
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
    // 键盘当前项(由 GridView 注入,delegate 当前项时为 true)。
    property bool current: false

    // 海报莫奈取色:底部渐变氛围尾色与进度条强调色跟随海报。
    // 命令式更新 + colorReady(posterId) 信号:QML 绑定 colors 属性会在
    // 任意海报取色完成时全量重算所有卡(colorsChanged 无参数);按 id
    // 过滤信号只更新本卡。取色未完成/失败保持回退色。
    property color heroFrom: Theme.surface
    property color accentColor: Theme.accent
    // 卡片底色藏色:带海报色相倾向,取代中性灰。
    property color surfaceTint: Theme.surface
    // 底部渐变尾色:暗色系用莫奈深色(承白字),亮色系用浅色卡底(承深字)
    property color _bottomFade: ThemeStore.isLight ? root.surfaceTint : root.heroFrom

    function applyMonet() {
        // 无条件赋值:取色未完成/失败或配置关闭时显示回退色,Grid 回收
        // 复用时不会残留上一张海报的颜色(早退会导致新卡沿用旧卡取色)。
        let c = null
        if (ConfigManager.monetEnabled)
            c = ColorProvider.colors[root.posterId]
        if (c) {
            root.heroFrom = c.heroFrom
            root.accentColor = c.accent
            // 亮色系下卡面取莫奈亮色镜像(否则深卡压深字)
            root.surfaceTint = ThemeStore.isLight && c.surfaceTintL ? c.surfaceTintL : c.surfaceTint
        } else {
            root.heroFrom = Theme.surface
            // 进度条/强调色用预设强调色(默认萌系粉白)。
            root.accentColor = Theme.accent
            root.surfaceTint = Theme.surface
        }
    }

    // 点击卡片(进详情)。
    signal clicked()
    // 悬停操作:收藏/已看切换请求(useById 翻转)。
    signal favoriteRequested(string itemId, bool fav)
    signal watchedRequested(string itemId, bool played)

    // hover 放大(hoverScale 手感同 ServerManager):等比例 scale(宽高
    // 同倍),220ms OutCubic 无回弹,中心缩放(默认 transformOrigin)。
    // 数值 1.06:卡两侧各留 gap/2=8,176 宽时水平溢出 5.3、垂直溢出
    // 7.9(gap 16 内),几乎不碰邻居;z 提升由使用方 delegate 根负责
    // (PosterCard 是 cell 子项,自身 z 盖不过兄弟 cell)。
    // hovered 暴露给使用方 delegate 根做 z 提升。
    property bool hovered: cardHover.hovered
    scale: cardHover.hovered ? 1.06 : 1.0
    Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
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
    Connections {
        // 配色切换:莫奈取色是命令式赋值(无绑定),需重跑取亮色镜像。
        // 挂 paletteChanged(不止明暗:同明暗换配色也要换 surface 回退值)。
        // 必须 Qt.callLater:回调触发时 Theme.* 依赖链尚未重算完,
        // 立即读 Theme.surface 会拿到旧值并被固化(实踩:切回暗色后卡面仍白)。
        target: ThemeStore
        function onPaletteChanged() {
            Qt.callLater(root.applyMonet)
        }
    }
    Connections {
        // 中途打开莫奈取色:补请求本卡取色,否则已有卡永远停在回退色
        target: ConfigManager
        function onMonetEnabledChanged() {
            if (ConfigManager.monetEnabled)
                ColorProvider.requestColor(root.posterId)
            Qt.callLater(root.applyMonet)
        }
    }

    Rectangle {
        x: 0
        y: 0
        width: parent.width
        height: parent.height
        color: root.surfaceTint
        radius: 14
        clip: true

        // 海报图:Image 自身 layer + layer.effect(MultiEffect)圆角。相比
        // CrossfadeImage,列表/网格卡片静止时无需溶解动画,省去「双图 + 溶解」
        // 的每帧片元与两个离屏 FBO;圆角由 Image 的 layer.effect 单 pass 裁切。
        Image {
            id: posterImg
            x: 0
            y: 0
            width: parent.width
            height: parent.height
            source: root.posterId ? "image://emby/" + root.posterId : ""
            fillMode: Image.PreserveAspectCrop
            cache: true
            asynchronous: true
            // 降采样锯齿主解:mipmap 预滤波层级(原图上千像素缩到卡面
            // 230×323,纯双线性无 mipmap 会毛边);smooth 双线性保留。
            smooth: true
            mipmap: true
            // 解码尺寸与显示一致(×DPR):卡尺寸固定,不再有 1.0~1.5× 的
            // 升/降采样错配(此前按原图全尺寸解码,缩放全由渲染器做)。
            sourceSize.width: Math.max(1, Math.round(root.width * Screen.devicePixelRatio))
            sourceSize.height: Math.max(1, Math.round(root.height * Screen.devicePixelRatio))
            layer.enabled: true
            layer.smooth: true
            // 圆角蒙版(Image 子项,经自身 layer 供 layer.effect 采样 alpha 裁切)。
            Rectangle {
                id: roundMask
                visible: false
                anchors.fill: parent
                radius: 14
                layer.enabled: true
            }
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: roundMask
                maskThresholdMin: 0.5
                maskSpreadAtMin: 1.0
            }
        }

        // 无主图或加载失败:萌系占位,不显示空卡(对照上游 404 契约)。
        Column {
            visible: root.posterId === "" || posterImg.status === Image.Error
            anchors.centerIn: parent
            spacing: 4
            opacity: 0.6

            AppText {
                text: root.itemType === "Series" ? "❀" : "🎞"
                color: Theme.accent
                font.pixelSize: 44
                horizontalAlignment: Text.AlignHCenter
                anchors.horizontalCenter: parent.horizontalCenter
            }
            AppText {
                text: root.itemType === "Series" ? "剧集" : "影像"
                color: Theme.textMuted
                font.pixelSize: 12
                horizontalAlignment: Text.AlignHCenter
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }

        // 底部渐变遮罩,提升标题可读性;尾色跟随海报莫奈色(氛围统一)。
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 46
            gradient: Gradient {
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 1.0; color: Qt.rgba(root._bottomFade.r, root._bottomFade.g, root._bottomFade.b, 0.72) }
            }
            radius: 14
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

        // 左上:评分角标(Emby 评分 0-10)。萌系:缩小、金粉描边、半透明。
        Rectangle {
            visible: root.rating >= 0.5
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: 6
            height: 18
            width: ratingRow.implicitWidth + 10
            radius: height / 2
            // 0.48 在浅海报上会让内部 ★(accentWarm)读不出,压到 0.60
            color: Qt.rgba(Theme.badgeScrim.r, Theme.badgeScrim.g, Theme.badgeScrim.b, 0.60)
            border.width: 1
            border.color: Theme.accentWarm
            Row {
                id: ratingRow
                anchors.centerIn: parent
                spacing: 2
                AppText {
                    text: "★"
                    color: Theme.accentWarm
                    font.pixelSize: 10
                }
                AppText {
                    text: root.rating.toFixed(1)
                    color: Theme.textOnBadge
                    font.pixelSize: 10
                }
            }
        }

        // 右上:状态角标(所有卡片常显,提供标记已看入口)。
        // 已看 → 绿勾;剧集有未看集数 → 粉色萌标;其余未看 → 中性"未看"。
        // showActions 时 hover 显示操作文案("标记未看/已看"),点击切换已看;
        // 轻量场景(搜索)保持纯状态展示。
        Rectangle {
            id: stateBadge
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 6
            height: 18
            width: stateRow.implicitWidth + 10
            radius: height / 2
            color: root.played
                     ? Qt.rgba(Theme.success.r, Theme.success.g, Theme.success.b, 0.75)
                     : (root.itemType === "Series" && root.unplayedCount > 0
                        ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.75)
                        // 中性"未看":角标永远压在海报图上,用深罩承白字(与主题无关)
                        : Qt.rgba(0, 0, 0, 0.45))
            border.width: root.played ? 0 : 1
            border.color: root.played ? "transparent" : Theme.accent
            Row {
                id: stateRow
                anchors.centerIn: parent
                spacing: 2
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
                    color: root.played ? Theme.textOnBadge : Theme.accentInk
                    font.pixelSize: 10
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

    // 萌系光晕边框:hover / 键盘焦点时泛出粉色轮廓。
    Rectangle {
        x: 0
        y: 0
        width: parent.width
        height: parent.height
        color: "transparent"
        radius: 14
        border.width: (cardHover.hovered || root.current) ? 2.5 : 0
        border.color: Theme.accent
        opacity: (cardHover.hovered || root.current) ? 0.95 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }
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
