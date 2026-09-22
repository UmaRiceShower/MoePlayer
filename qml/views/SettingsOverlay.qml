pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import MoePlayer.Core

//! 设置浮层(Ctrl+, / 首页设置按钮开关):两级布局,左侧设置分类,
//! 右侧对应该分类的具体设置项;Esc / 点击背景关闭。
//! 值全部直读写 ConfigManager(config.toml,外部修改热重载):控件初始
//! 绑定会被用户交互打断,故每个可同步控件注册进 syncables,open() 与
//! 任意配置变化信号(热重载/恢复默认)时统一 resync 回填实际生效值。
Item {
    id: root

    // 需要模糊的背景内容(主窗口传入 StackView,避免把浮层自身也模糊)。
    property Item backgroundSource: null

    // 可回填控件注册表:Switch/ComboBox/TextField 的用户写入会打断
    // 初始绑定,统一经各自的 resync() 从 ConfigManager 回填。
    property var syncables: []
    function registerSyncable(c) {
        root.syncables.push(c)
        // 动态页(设置项搜索结果)的委托销毁时自动注销:死对象留在表里,
        // 下次 open() → syncAll() 对其调 resync() 抛 TypeError,浮窗打不开。
        c.Component.onDestruction.connect(function () {
            const i = root.syncables.indexOf(c)
            if (i >= 0)
                root.syncables.splice(i, 1)
        })
    }
    function syncAll() {
        for (let i = 0; i < root.syncables.length; ++i)
            root.syncables[i].resync()
    }

    // 按 UI 分类过滤可见配置项(表驱动枚举;新增配置项无需手写行)。
    function itemsFor(section) {
        const all = ConfigManager.items
        const out = []
        for (let i = 0; i < all.length; ++i)
            if (all[i].uiSection === section)
                out.push(all[i])
        return out
    }

    // 设置项搜索:非空时保持两级布局,左侧只列有匹配项的分类(带匹配数),
    // 右侧为左选分类的匹配项。
    property string filterText: ""
    // 匹配(模糊/拼音,与库过滤同规则):对象 = 标签+描述+分类名;
    // section 限分类;无分类项(uiSection 空,不进界面的隐藏键)跳过。
    function itemsMatching(query, section) {
        const all = ConfigManager.items
        const out = []
        for (let i = 0; i < all.length; ++i) {
            const it = all[i]
            if (!it.uiSection)
                continue
            if (section !== undefined && it.uiSection !== section)
                continue
            if (FuzzyMatch.hit(query, it.label + " " + it.description + " " + it.uiSection))
                out.push(it)
        }
        return out
    }

    // 过滤模式下重建分类列表:只列有匹配项的分类,标签带匹配数;
    // 尽量保留原选中分类。「关于」无配置项,过滤时自然消失。
    function rebuildCats() {
        const prev = catList.currentIndex >= 0 && catModel.count > 0
                     ? catModel.get(catList.currentIndex).section : ""
        const q = root.filterText
        const cats = q === ""
            ? ["界面", "首页", "播放", "媒体库", "详情页", "快捷键", "代理", "关于"]
            : []
        catModel.clear()
        if (q === "") {
            for (let i = 0; i < cats.length; ++i)
                catModel.append({ label: cats[i], section: cats[i] })
        } else {
            const named = ["界面", "首页", "播放", "媒体库", "详情页", "快捷键", "代理"]
            for (let i = 0; i < named.length; ++i) {
                const n = itemsMatching(q, named[i]).length
                if (n > 0)
                    catModel.append({ label: named[i] + " (" + n + ")", section: named[i] })
            }
        }
        let idx = 0
        if (prev !== "")
            for (let i = 0; i < catModel.count; ++i)
                if (catModel.get(i).section === prev) { idx = i; break }
        catList.currentIndex = idx
    }
    onFilterTextChanged: rebuildCats()
    // 过滤模式右页的当前分类(随左选联动)。
    function currentFilterSection() {
        return catList.currentIndex >= 0 && catModel.count > 0
               ? catModel.get(catList.currentIndex).section : ""
    }

    function open() {
        root.syncAll()
        // 打开时清空设置项搜索:每次进入都是分类视图,状态可预期。
        filterField.text = ""
        root.visible = true
    }
    function close() {
        root.visible = false
    }

    // 热重载/恢复默认:任一配置变化统一回填(幂等,值相同无视觉变化)。
    Connections {
        target: ConfigManager
        // 任一配置变化(热重载/恢复默认/设置写入)统一回填——新增配置项
        // 无需在本文件加连接(属性级信号仅服务 QML 绑定粒度)。
        function onConfigChanged(key) { root.syncAll() }
    }

    // ===================== 内部组件 =====================

    // 设置行:左标签(+ 可选描述),右侧控件(default 属性注入)。
    component SettingRow: Item {
        id: srow
        required property string label
        property string description: ""
        default property alias control: srowLayout.data
        width: parent.width
        height: srowCol.implicitHeight
        Column {
            id: srowCol
            width: parent.width
            spacing: 6
            RowLayout {
                id: srowLayout
                width: parent.width
                spacing: 12
                AppText {
                    text: srow.label
                    font.pixelSize: 14
                    Layout.fillWidth: true
                }
            }
            AppText {
                visible: srow.description !== ""
                text: srow.description
                color: Theme.textMuted
                font.pixelSize: 12
                wrapMode: Text.WordWrap
                width: parent.width
            }
        }
    }

    // 开关:绑 ConfigManager 布尔键;胶囊指示器,选中粉色。
    component SettingSwitch: Switch {
        id: ssw
        required property string configKey
        padding: 0
        spacing: 0
        // 按下夺取焦点:输入框随之失焦(editingFinished 完成提交)。
        onDownChanged: if (down) root.forceActiveFocus()
        // contentItem 为 0 尺寸占位时 Qt 不回退到 indicator 尺寸,
        // 控件 implicitWidth 变 0(布局里不可见),须显式声明。
        implicitWidth: 42
        implicitHeight: 24
        checked: ConfigManager[ssw.configKey]
        onToggled: ConfigManager[ssw.configKey] = checked
        function resync() { checked = ConfigManager[ssw.configKey] }
        Component.onCompleted: root.registerSyncable(ssw)
        indicator: Rectangle {
            implicitWidth: 42
            implicitHeight: 24
            radius: 12
            color: ssw.checked ? Theme.accent : Theme.borderSoft
            border.width: 1
            border.color: ssw.checked ? Theme.accent : Theme.borderSoft
            Rectangle {
                width: 18
                height: 18
                radius: 9
                y: 3
                x: ssw.checked ? parent.width - width - 3 : 3
                color: Theme.accentInk
                Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            }
        }
        contentItem: Item { implicitWidth: 0; implicitHeight: 0 }
    }

    // 下拉:绑 ConfigManager 字符串键;model 统一 ListModel(label/key),
    // 视觉与 Library 的 FilterCombo 同款(暗底圆角/hover 粉描边/选中圆点)。
    component SettingCombo: ComboBox {
        id: scombo
        required property string configKey
        Layout.preferredWidth: 220
        Layout.preferredHeight: 34
        padding: 0
        textRole: "label"

        function resync() {
            const v = ConfigManager[scombo.configKey]
            const md = scombo.model
            for (let i = 0; i < scombo.count; ++i) {
                const it = md.get ? md.get(i) : md[i] // ListModel 或 JS 数组
                if (it.key === v) {
                    scombo.currentIndex = i
                    return
                }
            }
        }
        Component.onCompleted: {
            scombo.resync()
            root.registerSyncable(scombo)
        }
        onActivated: function (index) {
            const md = scombo.model
            const it = md.get ? md.get(index) : md[index]
            ConfigManager[scombo.configKey] = it.key
        }

        background: Rectangle {
            radius: 17
            color: Theme.bg
            border.width: 1
            border.color: scombo.hovered || scombo.popup.opened ? Theme.accent : Theme.textMuted
        }
        contentItem: Item {
            AppText {
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.right: scomboArrow.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                text: scombo.displayText
                font.pixelSize: 13
                elide: Text.ElideRight
            }
            AppText {
                id: scomboArrow
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: scombo.popup.opened ? "▴" : "▾"
                font.pixelSize: 10
            }
        }
        indicator: null
        popup: Popup {
            id: scomboPopup
            y: scombo.height + 4
            width: scombo.width
            implicitHeight: Math.min(contentItem.implicitHeight, 360) + topPadding + bottomPadding
            padding: 6
            enter: Transition {
                NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 120 }
            }
            exit: Transition {
                NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 120 }
            }
            background: Rectangle {
                color: Qt.rgba(Theme.scrim.r, Theme.scrim.g, Theme.scrim.b, 0.92)
                radius: 8
                border.width: 1
                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
            }
            contentItem: ListView {
                clip: true
                implicitHeight: contentHeight
                model: scombo.delegateModel
                currentIndex: scombo.highlightedIndex
                highlightMoveDuration: 0
            }
        }
        delegate: ItemDelegate {
            // Qt6 delegate 上下文(Bound 模式):required 声明注入属性。
            required property int index
            required property var model
            property string itemText: model[scombo.textRole]
            width: ListView.view.width
            height: 30
            padding: 0
            contentItem: Item {
                AppText {
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: parent.parent.itemText
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
                    visible: scombo.currentIndex === parent.parent.index
                }
            }
            highlighted: scombo.highlightedIndex === index
            background: Rectangle {
                radius: 4
                color: parent.highlighted || parent.hovered
                    ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                    : "transparent"
            }
        }
    }

    // 百分比滑块:绑 ConfigManager 整数键(0-100),拖动即写;与其它控件一样
    // 经 resync() 回填(热重载/重置后同步),右侧显示当前百分比。
    component SettingSlider: Item {
        id: sslider
        required property string configKey
        implicitWidth: 220
        implicitHeight: 34
        function resync() { sslide.value = ConfigManager[sslider.configKey] }
        Component.onCompleted: root.registerSyncable(sslider)
        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10
            Slider {
                id: sslide
                width: 180
                from: 0
                to: 100
                stepSize: 5
                value: ConfigManager[sslider.configKey]
                onMoved: ConfigManager[sslider.configKey] = Math.round(value)
                background: Rectangle {
                    x: sslide.leftPadding
                    y: sslide.topPadding + sslide.availableHeight / 2 - height / 2
                    width: sslide.availableWidth
                    height: 4
                    radius: 2
                    color: Theme.borderSoft
                    Rectangle {
                        width: sslide.visualPosition * parent.width
                        height: parent.height
                        radius: 2
                        color: Theme.accent
                    }
                }
                handle: Rectangle {
                    x: sslide.leftPadding + sslide.visualPosition * (sslide.availableWidth - width)
                    y: sslide.topPadding + sslide.availableHeight / 2 - height / 2
                    implicitWidth: 16
                    implicitHeight: 16
                    radius: 8
                    color: sslide.pressed ? Theme.accentDeep : Theme.accent
                    border.width: 1
                    border.color: Theme.accent
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: 30
                text: Math.round(sslide.value) + "%"
                color: Theme.textMuted
                font.pixelSize: 12
            }
        }
    }

    // 文本/整数输入:绑 ConfigManager 键,intOnly 启用整数校验;
    // 非法值被后端拒绝(代理格式/非正整数)时编辑结束回填实际生效值。
    component SettingField: TextField {
        id: sfield
        required property string configKey
        property bool intOnly: false
        Layout.fillWidth: false
        Layout.preferredWidth: 220
        Layout.preferredHeight: 34
        color: Theme.textPrimary
        font.pixelSize: 13
        // 框贴行右缘,文字右对齐视觉整齐
        horizontalAlignment: TextInput.AlignRight
        leftPadding: 12
        rightPadding: 12
        placeholderTextColor: Theme.textMuted
        validator: sfield.intOnly ? sfieldIntValidator : null
        IntValidator { id: sfieldIntValidator; bottom: 0; top: 9999 }
        text: ConfigManager[sfield.configKey]
        function resync() { text = String(ConfigManager[sfield.configKey]) }
        Component.onCompleted: root.registerSyncable(sfield)
        onEditingFinished: {
            if (sfield.intOnly) {
                let v = parseInt(text)
                const range = root.fieldClamp[sfield.configKey]
                if (range !== undefined)
                    v = Math.max(range[0], Math.min(range[1], v))
                ConfigManager[sfield.configKey] = v
            }
            else
                ConfigManager[sfield.configKey] = text.trim()
            sfield.resync()
            // 回车提交后主动失焦(点按其他区域由下方各失焦层转移焦点,
            // 焦点丢失同样触发本函数完成提交)。
            sfield.focus = false
        }
        background: Rectangle {
            radius: 8
            color: Theme.bg
            border.width: 1
            border.color: sfield.activeFocus ? Theme.accent : Theme.textMuted
        }
    }

    // 数值输入框区间钳制表:键 → [下限, 上限](越界自动收为界值)。
    readonly property var fieldClamp: ({ "homeLibraryLimit": [1, 60], "homeRowLines": [1, 5] })

    // 表驱动设置行:label/description/控件按 items 元数据渲染;
    // 条件显示行:某些配置项只在相关功能启用时有意义(key → 条件函数,绑定内
    // 读取的 ConfigManager 属性会注册依赖,切换即时显隐)。
    readonly property var rowVisibleIf: ({
        "backgroundMeteorRate": function() { return ConfigManager.backgroundEffect === "starry" },
        "playerBackend": function() { return MpvClient.embeddedAvailable() }
    })

    // Repeater 注入 modelData(SettingItem 的 required 属性)。
    component SettingItem: SettingRow {
        required property var modelData
        visible: root.rowVisibleIf[modelData.key] === undefined
                 || root.rowVisibleIf[modelData.key]()
        label: modelData.label
        description: modelData.description
        SettingSwitch { visible: modelData.widget === "switch"; configKey: modelData.key }
        SettingCombo { visible: modelData.widget === "combo"; configKey: modelData.key; model: modelData.options }
        SettingField { visible: modelData.widget === "field"; configKey: modelData.key; intOnly: modelData.intOnly === true }
        SettingSlider { visible: modelData.widget === "slider"; configKey: modelData.key }
    }

    // 设置页:纵向滚动容器,default 属性直写 Column。
    component SettingsPage: ScrollView {
        id: spage
        // 悬浮细条:不占布局,滚动/hover 显现。
        ScrollBar.vertical: MoeScrollBar {}
        default property alias content: spageCol.data
        clip: true
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        // 内容容器:至少撑满视口高,让失焦层覆盖行间隙与下方空白区;
        // 点击夺走输入框焦点(editingFinished 完成提交)。
        // (Column 是定位器,子项不能用 anchors,故失焦层放外层 Item。)
        Item {
            width: spage.availableWidth
            height: Math.max(spageCol.implicitHeight, spage.availableHeight)
            implicitHeight: spageCol.implicitHeight
            MouseArea {
                anchors.fill: parent
                onPressed: root.forceActiveFocus()
            }
            Column {
                id: spageCol
                width: parent.width
                spacing: 18
                topPadding: 2
                bottomPadding: 8
            }
        }
    }

    // 页标题(分类名)。
    component PageHeader: AppText {
        font.pixelSize: 16
        font.bold: true
    }

    // ===================== 浮层外壳(同 SearchOverlay) =====================

    // 毛玻璃暗遮罩:模糊背景 + 半透明压暗,点击关闭。
    GlassPanel {
        anchors.fill: parent
        blurSource: root.backgroundSource
        blurRadius: 64
        glassColor: Qt.rgba(Theme.scrimDeep.r, Theme.scrimDeep.g, Theme.scrimDeep.b, 0.55)
        border.width: 0
        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }
    }

    Rectangle {
        anchors.top: parent.top
        anchors.topMargin: 48
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width*0.8
        height: parent.height - 96
        radius: 16
        color: "transparent"
        border.width: 0

        // 毛玻璃面板底色。
        GlassPanel {
            anchors.fill: parent
            blurSource: root.backgroundSource
            blurRadius: 48
            glassColor: Qt.rgba(Theme.scrim.r, Theme.scrim.g, Theme.scrim.b, 0.72)
            borderColor: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.35)
            radius: parent.radius
        }

        // 吞掉面板内空白处的点击,防止穿透到遮罩 MouseArea 误关闭。
        MouseArea {
            anchors.fill: parent
            z: -1
            onClicked: { }
            onPressed: root.forceActiveFocus()
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 12

            // 标题行。
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                AppText {
                    text: "设置"
                    font.pixelSize: 18
                    font.bold: true
                }
                Item { Layout.fillWidth: true }
                // 设置项搜索:跨分类即时过滤(不防抖);Esc 清空,空时再按
                // Esc 放行给全局关浮层。
                TextField {
                    id: filterField
                    Layout.preferredWidth: 200
                    Layout.preferredHeight: 30
                    placeholderText: "搜索设置项…"
                    placeholderTextColor: Theme.textMuted
                    color: Theme.textPrimary
                    font.pixelSize: 13
                    selectByMouse: true
                    leftPadding: 12
                    rightPadding: 12
                    background: Rectangle {
                        radius: 15
                        color: Qt.rgba(Theme.scrimSoft.r, Theme.scrimSoft.g, Theme.scrimSoft.b, 0.45)
                        border.width: 1
                        border.color: filterField.activeFocus
                                      ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55)
                                      : Theme.borderSoft
                    }
                    onTextChanged: root.filterText = text.trim()
                    Keys.onEscapePressed: (event) => {
                        if (text !== "")
                            text = ""
                        else
                            event.accepted = false
                    }
                }
                AppText {
                    text: "Esc 关闭"
                    color: Theme.textMuted
                    font.pixelSize: 12
                }
            }

            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Theme.borderSoft
            }

            // 两级主体:左分类列表,右设置项页。
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 14

                ListView {
                    id: catList
                    Layout.preferredWidth: 160
                    Layout.fillHeight: true
                    // 过滤时保持可见:两级布局的左级(只列有匹配项的分类)。
                    clip: true
                    currentIndex: 0
                    model: ListModel { id: catModel }
                    // 初填与过滤重建都走 rebuildCats()(过滤=只列有匹配项的分类)。
                    Component.onCompleted: root.rebuildCats()
                    // 分类不满一列时下方空白区:点击夺走输入框焦点。
                    MouseArea {
                        z: -1
                        width: catList.width
                        height: Math.max(catList.contentHeight, catList.height)
                        onPressed: root.forceActiveFocus()
                    }
                    delegate: ItemDelegate {
                        id: catItem
                        required property string label
                        required property int index
                        width: catList.width
                        height: 40
                        padding: 0
                        onDownChanged: if (down) root.forceActiveFocus()
                        onClicked: catList.currentIndex = catItem.index
                        contentItem: Item {
                            AppText {
                                anchors.left: parent.left
                                anchors.leftMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                text: catItem.label
                                font.pixelSize: 14
                                color: catList.currentIndex === catItem.index ? Theme.textPrimary : Theme.textMuted
                            }
                            Rectangle {
                                anchors.right: parent.right
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                width: 6
                                height: 6
                                radius: 3
                                color: Theme.accent
                                visible: catList.currentIndex === catItem.index
                            }
                        }
                        background: Rectangle {
                            radius: 8
                            color: catList.currentIndex === catItem.index
                                   ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.25)
                                   : catItem.hovered
                                     ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.12)
                                     : "transparent"
                        }
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.fillHeight: true
                    color: Theme.borderSoft
                }

                StackLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: root.filterText === ""
                    currentIndex: catList.currentIndex

                    // ---- 界面(配置项经 items 表枚举) ----
                    SettingsPage {
                        PageHeader { text: "界面" }
                        Repeater {
                            model: root.itemsFor("界面")
                            delegate: SettingItem {}
                        }
                    }

                    // ---- 首页(聚合模式 + 自定义库编辑器) ----
                    SettingsPage {
                        PageHeader { text: "首页" }
                        Repeater {
                            model: root.itemsFor("首页")
                            delegate: SettingItem {}
                        }
                        // ---- 自定义库(内联编辑器,非表驱动项;过滤态隐藏)----
                        // 预置即默认值,直接可编辑/删除;编辑只动工作副本,保存才落盘。
                        Column {
                            id: customLibsEditor
                            width: parent.width
                            spacing: 10
                            visible: root.filterText === ""
                            // [{name, rules:[{field,pattern}]}];文本静默回写,结构变更重排
                            property var libs: []
                            property string errorText: ""
                            // 各桶当前命中统计(与配置同序;保存后刷新):[{name,libraries,itemCount}]
                            property var stats: []
                            // 显式保存语义(参考 antd/GitHub dirty-save 条):编辑只动工作副本,
                            // dirty 时底部浮现 取消/保存;不实时落盘。
                            property bool dirty: false

                            function load() {
                                try {
                                    const v = JSON.parse(ConfigManager.customLibraries)
                                    libs = Array.isArray(v) ? v : []
                                } catch (e) { libs = [] }
                                errorText = ""
                                dirty = false
                                refreshStats()
                            }
                            function refreshStats() {
                                stats = AccountManager.customBucketStats()
                            }
                            function markDirty() { dirty = true }
                            function mut() { libs = libs.slice(); dirty = true }
                            function save() {
                                const out = []
                                for (const lib of libs) {
                                    const name = (lib.name || "").trim()
                                    if (name === "") { errorText = "存在未命名的自定义库,未保存"; return }
                                    const rules = []
                                    for (const r of lib.rules) {
                                        const pat = (r.pattern || "").trim()
                                        if (pat === "") continue
                                        try { new RegExp(pat, "i") } catch (e) {
                                            errorText = "「" + name + "」含无效正则,未保存:" + pat
                                            return
                                        }
                                        rules.push({ field: r.field, pattern: pat })
                                    }
                                    if (rules.length === 0) { errorText = "「" + name + "」至少需要一条规则,未保存"; return }
                                    out.push({ name: name, rules: rules })
                                }
                                ConfigManager.customLibraries = JSON.stringify(out)
                                errorText = ""
                                dirty = false
                                refreshStats()
                            }
                            Component.onCompleted: load()
                            // 每次打开设置浮层重载(外部 config.toml 热改也收敛)
                            Connections {
                                target: root
                                function onVisibleChanged() {
                                    if (root.visible && !customLibsEditor.dirty)
                                        customLibsEditor.load()
                                }
                            }

                            RowLayout {
                                width: parent.width
                                AppText {
                                    text: "自定义库"
                                    font.pixelSize: 14
                                    Layout.fillWidth: true
                                }
                                AppText {
                                    text: "恢复预置"
                                    color: resetLibsHover.hovered ? Theme.accent : Theme.textMuted
                                    font.pixelSize: 12
                                    HoverHandler { id: resetLibsHover; cursorShape: Qt.PointingHandCursor }
                                    TapHandler {
                                        onTapped: {
                                            try {
                                                customLibsEditor.libs = JSON.parse(ConfigManager.defaultValue("customLibraries"))
                                            } catch (e) { customLibsEditor.libs = [] }
                                            customLibsEditor.markDirty()
                                        }
                                    }
                                }
                            }
                            AppText {
                                width: parent.width
                                wrapMode: Text.WordWrap
                                text: "把多台服务器的媒体库按规则合并成统一行。按顺序归桶,第一个命中的桶赢;同一库的多条规则为「或」。"
                                color: Theme.textMuted
                                font.pixelSize: 12
                            }
                            AppText {
                                visible: customLibsEditor.errorText !== ""
                                text: customLibsEditor.errorText
                                color: Theme.danger
                                font.pixelSize: 12
                            }
                            Column {
                                width: parent.width
                                spacing: 8
                                Repeater {
                                    model: customLibsEditor.libs
                                    delegate: Rectangle {
                                        id: libCard
                                        required property var modelData
                                        required property int index
                                        property var lib: modelData
                                        property bool hovered: cardHover.hovered
                                        HoverHandler { id: cardHover }
                                        width: parent.width
                                        height: libCol.implicitHeight + 20
                                        radius: 10
                                        color: Theme.bg
                                        border.width: 1
                                        border.color: Theme.borderSoft
                                        Column {
                                            id: libCol
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.top: parent.top
                                            anchors.margins: 10
                                            spacing: 6
                                            // 库名行:无边框内联输入 + 悬停露删除
                                            RowLayout {
                                                width: parent.width
                                                TextField {
                                                    id: libNameField
                                                    Layout.fillWidth: true
                                                    text: libCard.lib.name
                                                    placeholderText: "库名(如:动画)"
                                                    placeholderTextColor: Theme.textMuted
                                                    color: Theme.textPrimary
                                                    font.pixelSize: 13
                                                    font.bold: true
                                                    onEditingFinished: {
                                                        customLibsEditor.libs[libCard.index].name = text.trim()
                                                        customLibsEditor.markDirty()
                                                    }
                                                    background: Rectangle {
                                                        radius: 6
                                                        color: libNameField.activeFocus ? Theme.surface : "transparent"
                                                        border.width: 1
                                                        border.color: libNameField.activeFocus ? Theme.accent : "transparent"
                                                    }
                                                }
                                                Rectangle {
                                                    width: 26
                                                    height: 26
                                                    radius: 6
                                                    color: delLibHover.hovered ? Theme.dangerTint : "transparent"
                                                    opacity: libCard.hovered ? 1 : 0
                                                    Behavior on opacity { NumberAnimation { duration: 120 } }
                                                    HoverHandler { id: delLibHover; cursorShape: Qt.PointingHandCursor }
                                                    TapHandler {
                                                        onTapped: {
                                                            customLibsEditor.libs.splice(libCard.index, 1)
                                                            customLibsEditor.mut()
                                                        }
                                                    }
                                                    Image {
                                                        anchors.centerIn: parent
                                                        width: 13
                                                        height: 13
                                                        source: "qrc:/icons/" + (ThemeStore.isLight ? "dark/" : "") + "trash.svg"
                                                        sourceSize.width: 26
                                                        sourceSize.height: 26
                                                    }
                                                }
                                            }
                                            // 规则行:字段切换(库名/类型)+ 正则 + 悬停删除
                                            Repeater {
                                                model: libCard.lib.rules
                                                delegate: RowLayout {
                                                    id: ruleRow
                                                    required property var modelData
                                                    required property int index
                                                    width: libCol.width
                                                    spacing: 8
                                                    Rectangle {
                                                        width: 52
                                                        height: 24
                                                        radius: 12
                                                        color: Theme.tint
                                                        AppText {
                                                            anchors.centerIn: parent
                                                            text: ruleRow.modelData.field === "collectionType" ? "类型" : "库名"
                                                            color: Theme.accent
                                                            font.pixelSize: 11
                                                        }
                                                        TapHandler {
                                                            cursorShape: Qt.PointingHandCursor
                                                            onTapped: {
                                                                const cur = customLibsEditor.libs[libCard.index].rules[ruleRow.index]
                                                                cur.field = cur.field === "collectionType" ? "name" : "collectionType"
                                                                customLibsEditor.mut()
                                                            }
                                                        }
                                                    }
                                                    TextField {
                                                        id: patternField
                                                        Layout.fillWidth: true
                                                        text: ruleRow.modelData.pattern
                                                        placeholderText: "正则(如:动漫|番剧)"
                                                        placeholderTextColor: Theme.textMuted
                                                        color: Theme.textPrimary
                                                        font.pixelSize: 12
                                                        onEditingFinished: {
                                                            customLibsEditor.libs[libCard.index].rules[ruleRow.index].pattern = text.trim()
                                                            customLibsEditor.markDirty()
                                                        }
                                                        background: Rectangle {
                                                            radius: 6
                                                            color: patternField.activeFocus ? Theme.surface : "transparent"
                                                            border.width: 1
                                                            border.color: patternField.activeFocus ? Theme.accent : "transparent"
                                                        }
                                                    }
                                                    Rectangle {
                                                        width: 22
                                                        height: 22
                                                        radius: 5
                                                        color: delRuleHover.hovered ? Theme.dangerTint : "transparent"
                                                        opacity: libCard.hovered ? 1 : 0
                                                        Behavior on opacity { NumberAnimation { duration: 120 } }
                                                        HoverHandler { id: delRuleHover; cursorShape: Qt.PointingHandCursor }
                                                        TapHandler {
                                                            onTapped: {
                                                                customLibsEditor.libs[libCard.index].rules.splice(ruleRow.index, 1)
                                                                customLibsEditor.mut()
                                                            }
                                                        }
                                                        Image {
                                                            anchors.centerIn: parent
                                                            width: 11
                                                            height: 11
                                                            source: "qrc:/icons/" + (ThemeStore.isLight ? "dark/" : "") + "trash.svg"
                                                            sourceSize.width: 22
                                                            sourceSize.height: 22
                                                        }
                                                    }
                                                }
                                            }
                                            AppText {
                                                // 按名匹配(dirty 态增删卡后下标会错位);重名退下标
                                                property var st: {
                                                    const nm = (libCard.lib.name || "").trim()
                                                    const arr = customLibsEditor.stats
                                                    for (const x of arr)
                                                        if (x.name === nm)
                                                            return x
                                                    return arr.length > libCard.index ? arr[libCard.index] : null
                                                }
                                                visible: st !== null
                                                width: libCol.width
                                                wrapMode: Text.WordWrap
                                                font.pixelSize: 11
                                                color: Theme.textMuted
                                                text: st === null ? ""
                                                      : ((st.libraries.length === 0
                                                          ? "当前未命中任何库(空桶不占首页行)"
                                                          : "命中 " + st.libraries.length + " 库 "
                                                            + st.itemCount + " 条 ⓘ")
                                                         + (customLibsEditor.dirty ? "(保存后刷新)" : ""))
                                                // 名单明细收悬停提示:行内只留紧凑计数
                                                HoverHandler { id: statHover; enabled: parent.st !== null && parent.st.libraries.length > 0; cursorShape: Qt.PointingHandCursor }
                                                ToolTip {
                                                    id: statTip
                                                    visible: statHover.hovered
                                                    delay: 200
                                                    x: 0
                                                    y: parent.height + 6
                                                    padding: 10
                                                    contentItem: AppText {
                                                        text: statTip.parent.st ? statTip.parent.st.libraries.join("\n") : ""
                                                        font.pixelSize: 12
                                                        color: Theme.textPrimary
                                                        lineHeight: 1.4
                                                    }
                                                    background: Rectangle {
                                                        radius: 8
                                                        color: Theme.surface
                                                        border.width: 1
                                                        border.color: Theme.glassRim
                                                    }
                                                }
                                            }
                                            AppText {
                                                text: "+ 规则(或)"
                                                color: addRuleHover.hovered ? Theme.accent : Theme.textMuted
                                                font.pixelSize: 12
                                                HoverHandler { id: addRuleHover; cursorShape: Qt.PointingHandCursor }
                                                TapHandler {
                                                    onTapped: {
                                                        // 深拷贝陷阱:委托 modelData 是数组元素的
                                                        // 副本,改副本无效;一切写操作按下标直改真身。
                                                        customLibsEditor.libs[libCard.index].rules.push({ field: "name", pattern: "" })
                                                        customLibsEditor.mut()
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                // 幽灵「添加库」卡
                                Rectangle {
                                    width: parent.width
                                    height: 36
                                    radius: 10
                                    color: addLibHover.hovered ? Theme.tint : "transparent"
                                    border.width: 1
                                    border.color: Theme.borderSoft
                                    HoverHandler { id: addLibHover; cursorShape: Qt.PointingHandCursor }
                                    TapHandler {
                                        onTapped: {
                                            customLibsEditor.libs.push({ name: "", rules: [{ field: "name", pattern: "" }] })
                                            customLibsEditor.mut()
                                        }
                                    }
                                    AppText {
                                        anchors.centerIn: parent
                                        text: "+ 添加自定义库"
                                        color: Theme.textMuted
                                        font.pixelSize: 12
                                    }
                                }
                            }
                            RowLayout {
                                width: parent.width
                                height: customLibsEditor.dirty ? 36 : 0
                                visible: customLibsEditor.dirty
                                AppText {
                                    text: "有未保存的更改"
                                    color: Theme.textMuted
                                    font.pixelSize: 12
                                }
                                Item { Layout.fillWidth: true }
                                AppText {
                                    text: "取消"
                                    color: cancelLibsHover.hovered ? Theme.textPrimary : Theme.textMuted
                                    font.pixelSize: 13
                                    HoverHandler { id: cancelLibsHover; cursorShape: Qt.PointingHandCursor }
                                    TapHandler { onTapped: customLibsEditor.load() }
                                }
                                Rectangle {
                                    width: saveLibsTxt.implicitWidth + 26
                                    height: 30
                                    radius: 15
                                    color: saveLibsHover.hovered ? Theme.accentHover : Theme.accent
                                    HoverHandler { id: saveLibsHover; cursorShape: Qt.PointingHandCursor }
                                    TapHandler { onTapped: customLibsEditor.save() }
                                    AppText {
                                        id: saveLibsTxt
                                        anchors.centerIn: parent
                                        text: "保存"
                                        color: Theme.accentInk
                                        font.pixelSize: 13
                                    }
                                }
                            }
                        }
                    }

                    // ---- 播放(配置项经 items 表枚举) ----
                    SettingsPage {
                        PageHeader { text: "播放" }
                        Repeater {
                            model: root.itemsFor("播放")
                            delegate: SettingItem {}
                        }
                    }

                    // ---- 媒体库(配置项经 items 表枚举) ----
                    SettingsPage {
                        PageHeader { text: "媒体库" }
                        Repeater {
                            model: root.itemsFor("媒体库")
                            delegate: SettingItem {}
                        }
                    }

                    // ---- 详情页(配置项经 items 表枚举) ----
                    SettingsPage {
                        PageHeader { text: "详情页" }
                        Repeater {
                            model: root.itemsFor("详情页")
                            delegate: SettingItem {}
                        }
                    }

                    // ---- 快捷键(配置项经 items 表枚举) ----
                    SettingsPage {
                        PageHeader { text: "快捷键" }
                        Repeater {
                            model: root.itemsFor("快捷键")
                            delegate: SettingItem {}
                        }
                        AppText {
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: "键位语法:QKeySequence 文本(如 Ctrl+K、Alt+Left、/);同一功能多个键位用 | 分隔。修改即时生效,无需重启。"
                            color: Theme.textMuted
                            font.pixelSize: 12
                        }
                    }

                    // ---- 代理(配置项经 items 表枚举) ----
                    SettingsPage {
                        PageHeader { text: "代理" }
                        Repeater {
                            model: root.itemsFor("代理")
                            delegate: SettingItem {}
                        }
                        Column {
                            width: parent.width
                            spacing: 6
                            AppText {
                                text: "配置文件"
                                color: Theme.textMuted
                                font.pixelSize: 12
                            }
                            AppText {
                                text: ConfigManager.configPath
                                font.pixelSize: 12
                                wrapMode: Text.WrapAnywhere
                                width: parent.width
                            }
                            AppText {
                                text: "可直接编辑,保存后自动热重载。"
                                color: Theme.textMuted
                                font.pixelSize: 12
                            }
                        }
                    }

                    // ---- 关于 ----
                    SettingsPage {
                        PageHeader { text: "关于" }
                        AppText {
                            text: Qt.application.name + " " + Qt.application.version
                            font.pixelSize: 14
                        }
                        AppText {
                            text: "第三方 Emby 桌面客户端。"
                            color: Theme.textMuted
                            font.pixelSize: 12
                        }
                        SettingRow {
                            label: "恢复默认设置"
                            description: "全部设置恢复默认值并立即写入配置文件。"
                            ItemDelegate {
                                id: resetBtn
                                // 尺寸自适应:去掉硬编码 width,宽度由文字+左右内边距决定(Control implicitWidth),
                                // 高度固定胶囊高;background 半径跟随高度。改文字/字体不再溢出。
                                // 二次确认防误点:首击进入"确认恢复"红色待定态,再击才真正恢复默认;
                                // 待定态 4 秒未确认自动撤销,避免留下危险的红色按钮。
                                property bool confirmArmed: false
                                padding: 0
                                implicitHeight: 34
                                leftPadding: 14
                                rightPadding: 14
                                onDownChanged: if (down) root.forceActiveFocus()
                                onClicked: {
                                    if (resetBtn.confirmArmed) {
                                        ConfigManager.resetToDefaults()
                                        resetBtn.confirmArmed = false
                                    } else {
                                        resetBtn.confirmArmed = true
                                        resetTimer.restart()
                                    }
                                }
                                Timer {
                                    id: resetTimer
                                    interval: 4000
                                    onTriggered: resetBtn.confirmArmed = false
                                }
                                contentItem: AppText {
                                    text: resetBtn.confirmArmed ? "确认恢复" : "恢复默认"
                                    color: resetBtn.confirmArmed ? Theme.textOnBadge : Theme.accentText
                                    font.pixelSize: 13
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                background: Rectangle {
                                    radius: parent.height / 2
                                    color: resetBtn.confirmArmed
                                        ? (parent.hovered
                                           ? Theme.dangerPressed
                                           : Theme.danger)
                                        : (parent.hovered
                                           ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                                           : "transparent")
                                    border.width: 1
                                    border.color: resetBtn.confirmArmed
                                        ? Theme.danger
                                        : Theme.accent
                                }
                            }
                        }
                    }
                }

                // ---- 过滤结果页:跟随左选分类,只列该分类的匹配项 ----
                SettingsPage {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: root.filterText !== ""
                    Repeater {
                        model: root.filterText === "" ? []
                                : root.itemsMatching(root.filterText, root.currentFilterSection())
                        delegate: SettingItem {}
                    }
                    AppText {
                        visible: root.filterText !== "" && catModel.count === 0
                        text: "无匹配设置项"
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                }
            }
        }
    }


}

