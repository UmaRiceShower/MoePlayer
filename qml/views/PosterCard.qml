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
    // 创建时查询一次即可:门控销毁/重建的卡在重建时刻判定,期间缓存状态不变
    readonly property bool _posterCached: posterId !== "" && PosterProvider.isCached(posterId)
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
    // 键盘当前项(使用方 delegate 显式绑定,如 current: GridView.isCurrentItem)。
    property bool current: false

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
    // 取色搭显示管线便车:图就绪时必然已落缓存,loadImageSync 纯命中;
    // 创建即请求会与显示加载并发回源同一图(双倍请求/双倍服务器转码)。
    function requestMonet() {
        if (ConfigManager.monetEnabled && root.posterId !== "")
            ColorProvider.requestColor(root.posterId)
    }
    onPosterIdChanged: {
        posterImg._retry = 0
        root.applyMonet()
        if (posterImg.status === Image.Ready)
            root.requestMonet()
    }
    Component.onCompleted: {
        root.applyMonet()
        if (posterImg.status === Image.Ready)
            root.requestMonet()
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
        // 立即读 Theme.surface 会拿到旧值并被固化(切回暗色后卡面仍白)。
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

    // 海报区(上) + 文字块(下,图外)
    Rectangle {
        id: posterArea
        x: 0
        y: 0
        width: parent.width
        height: parent.height - Constants.posterCardTextH
        color: root.surfaceTint
        radius: 14
        clip: true

        // 海报图:Image 自身 layer + layer.effect(SDF 圆角)单 pass 裁切。
        // 相比 CrossfadeImage,列表/网格卡片静止时无需溶解动画,省去「双图 +
        // 溶解」的每帧片元与两个离屏 FBO。
        Image {
            id: posterImg
            x: 0
            y: 0
            width: parent.width
            height: parent.height

            // 就绪淡入;已缓存的图跳过
            opacity: status === Image.Ready || root._posterCached ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 260 } enabled: !root._posterCached }
            // 失败重试:QQuickPixmap 对失败 URL 在进程内缓存错误态,重设
            // 同源秒回错误不发新请求——换 ~r<N> 外衣重请求(provider 剥
            // 标记,缓存键不变),1.5s × 最多 5 次。委托复用时复位。
            property int _retry: 0
            source: root.posterId ? "image://emby/" + root.posterId
                        + (posterImg._retry > 0 ? "~r" + posterImg._retry : "") : ""
            onStatusChanged: {
                if (status === Image.Error && posterImg._retry < 5)
                    posterRetry.restart()
                if (status === Image.Ready)
                    root.requestMonet()
            }
            Timer {
                id: posterRetry
                interval: 1500
                onTriggered: posterImg._retry += 1
            }
            fillMode: Image.PreserveAspectCrop
            cache: true
            asynchronous: true
            // 降采样锯齿主解:mipmap 预滤波层级(原图上千像素缩到卡面
            // 230×323,纯双线性无 mipmap 会毛边);smooth 双线性保留。
            smooth: true
            mipmap: true
            // provider 恒回 512px 服务端缩放档(requestedSize 不参与),sourceSize
            // 不解码只污染缓存键(resize 每像素一轮重载 ⇒ 白卡闪)——不设。
            // retainWhileLoading(Qt 6.8):source 重绑时旧图保留到新图就绪。
            retainWhileLoading: true
            layer.enabled: true
            layer.smooth: true
            // 圆角 = 片元 SDF 解析抗锯齿(hero 同款);蒙版方案死路:蒙版纹理
            // 无 MSAA 硬二值,阈值重映射救不回。
            layer.effect: ShaderEffect {
                property real u_radius: 14
                property size u_size: Qt.size(posterImg.width, posterImg.height)
                fragmentShader: "qrc:/qt/qml/MoePlayer/Core/shaders/round-rect.frag.qsb"
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

        // 观看进度条(位置/时长随列表 UserData 返回,零额外请求)。
        Rectangle {
            visible: root.positionTicks > 0 && root.runtimeTicks > 0
            anchors.left: parent.left
            anchors.right: parent.right
            // 横向内缩:卡底 r14 圆角镂空最深 ~5.3px,条角不浮空。
            anchors.leftMargin: 6
            anchors.rightMargin: 6
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
            anchors.margins: 10
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
            anchors.margins: 10
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

    Rectangle {
        // 光晕外包裹:Qt 矩形描边画在界内(不骑跨),整带外探 = 矩形外移
        // 整个描边宽;带占 [-2.5,0] 全在图外,内弧 16.5-2.5=14 恰贴图角弧。
        x: -2.5
        y: -2.5
        width: parent.width + 5
        height: posterArea.height + 5
        color: "transparent"
        radius: 16.5
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

    // 文字块
    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: posterArea.bottom
        anchors.topMargin: 6
        height: Constants.posterCardTextH - 6
        spacing: 1
        AppText {
            width: parent.width
            text: root.title
            color: Theme.textPrimary
            font.pixelSize: 13
            elide: Text.ElideRight
        }
        AppText {
            width: parent.width
            text: root.year > 0 ? String(root.year) : ""
            color: Theme.textMuted
            font.pixelSize: 11
        }
    }
}
