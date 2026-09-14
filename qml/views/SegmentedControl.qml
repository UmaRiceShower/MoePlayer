pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import MoePlayer.Core

//! 分段切换:一个设置在其互斥取值之间切换(区别于 FilterChip 的"开关/筛选"语义)。
//! 选项文字恒为取值名(不随当前状态改写),当前取值由滑块标出 —— 点击是"换位",
//! 不是"点亮",因此不做透明→实心色的开合变化。
//! 分段等宽(按最宽标签定宽),滑块位移才是纯平移。
Item {
    id: root

    // ============================= 属性 =============================

    // 选项:[{ value, label }, ...]
    property var options: []
    // 当前取值:与某个选项的 value 相等时该项为选中态(比较用 ===)。
    property var currentValue
    readonly property int padding: 3
    readonly property int gap: 2
    readonly property int segmentH: 28

    readonly property int selectedIndex: {
        for (let i = 0; i < root.options.length; ++i) {
            if (root.options[i].value === root.currentValue)
                return i
        }
        return -1
    }
    // 等宽分段:按最宽的标签定宽(读标签自身的 implicitWidth,不在绑定内改写度量对象)。
    readonly property real segmentW: {
        let w = 0
        for (let i = 0; i < segments.count; ++i) {
            const seg = segments.itemAt(i)
            if (seg && seg.labelWidth > 0)
                w = Math.max(w, seg.labelWidth)
        }
        return Math.ceil(w) + 24
    }

    implicitWidth: root.options.length * root.segmentW
                   + Math.max(0, root.options.length - 1) * root.gap + root.padding * 2
    implicitHeight: root.segmentH
    // 定宽组件:滑块位移按 segmentW 计算,拉伸会与分段错位,故尺寸只由内容决定。
    width: implicitWidth
    height: implicitHeight

    // ============================= 信号 =============================

    signal activated(var value)

    // ============================= 子对象 =============================

    // 槽:低对比底 + 中性细边(不着强调色,避免与"已选中"混为一谈)。
    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Qt.rgba(Theme.scrimSoft.r, Theme.scrimSoft.g, Theme.scrimSoft.b, 0.45)
        border.width: 1
        border.color: Theme.borderSoft
    }

    // 滑块:当前取值(浅玻璃 + 细粉边;选中靠位置表达,不靠填充色)。
    Rectangle {
        id: indicator
        visible: root.selectedIndex >= 0
        x: root.padding + Math.max(0, root.selectedIndex) * (root.segmentW + root.gap)
        y: root.padding
        width: root.segmentW
        height: root.segmentH - root.padding * 2
        radius: height / 2
        color: Theme.tint
        border.width: 1
        border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55)
        Behavior on x {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
        Behavior on width {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
    }

    Row {
        anchors.fill: parent
        anchors.margins: root.padding
        spacing: root.gap
        Repeater {
            id: segments
            model: root.options
            delegate: Item {
                id: segment
                required property var modelData
                required property int index
                readonly property real labelWidth: labelText.implicitWidth
                width: root.segmentW
                height: parent.height

                AppText {
                    id: labelText
                    anchors.centerIn: parent
                    text: segment.modelData.label
                    color: segment.index === root.selectedIndex
                           ? Theme.accentText
                           : (segHover.hovered ? Theme.textPrimary : Theme.textMuted)
                    font.pixelSize: 13
                }
                HoverHandler {
                    id: segHover
                    cursorShape: Qt.PointingHandCursor
                }
                TapHandler {
                    onTapped: root.activated(segment.modelData.value)
                }
            }
        }
    }
}
