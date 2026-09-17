import QtQuick
import QtQuick.Controls

ScrollBar {
    id: bar
    property Flickable view: null
    policy: ScrollBar.AsNeeded
    orientation: Qt.Vertical
    width: 10
    leftPadding: 3
    rightPadding: 3
    minimumSize: width / height
    hoverEnabled: true
    enabled: view ? size < 1.0 : true

    Binding on size {
        when: bar.view !== null
        value: bar.view ? bar.view.visibleArea.heightRatio : 1.0
        restoreMode: Binding.RestoreNone
    }
    // 拖动期间暂停位置回填,避免与拖拽争抢 position。
    Binding on position {
        when: bar.view !== null && !bar.pressed
        value: bar.view ? bar.view.visibleArea.yPosition : 0
        restoreMode: Binding.RestoreNone
    }
    Binding on active {
        when: bar.view !== null
        value: bar.view !== null && (bar.view.moving || bar.pressed)
        restoreMode: Binding.RestoreNone
    }

    // 拖动回写(贴边模式):visibleArea 公式逆运算。
    onPositionChanged: {
        const v = bar.view
        if (!v || !bar.pressed || bar.size <= 0 || bar.size >= 1.0)
            return
        const origin = (v.originY !== undefined) ? v.originY : 0
        const top = (v.topMargin !== undefined) ? v.topMargin : 0
        const bottom = (v.bottomMargin !== undefined) ? v.bottomMargin : 0
        const minY = origin - top
        const maxY = Math.max(minY, origin + v.contentHeight - v.height + bottom)
        v.contentY = minY + (bar.position / (1.0 - bar.size)) * (maxY - minY)
    }

    background: null
    contentItem: Rectangle {
        radius: 2
        color: (bar.pressed || bar.hovered) ? Theme.accent : Theme.accentMuted
        opacity: bar.size >= 1.0 ? 0
               : bar.pressed ? 0.75
               : (bar.hovered || bar.active) ? 0.55
               : 0.30
        Behavior on opacity { NumberAnimation { duration: 160 } }
        Behavior on color { ColorAnimation { duration: 160 } }
    }
}
