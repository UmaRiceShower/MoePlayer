pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import MoePlayer.Core

// 可见返回钮(玻璃圆 ‹):点击 = Main 窗口 goBack() 统一分发
// (浮层优先 → 页内后退 → 退栈)。置于各页左上(顶栏行首或 hero 角),
// 供无侧键鼠标与不熟手势的用户走纯鼠标路径。
// blurSource 默认取窗口主题背景(顶栏下方即它);压在内容上的场景
// (hero/网格)由调用方传入内容 item(约束同 FrostedGlass)。
FrostedGlass {
    width: 32
    height: 32
    radius: 16
    blurSource: ApplicationWindow.window ? ApplicationWindow.window.background : null
    blurRadius: 4
    thickness: 12
    hoverGlow: backArea.hovered ? 0.35 : 0.0
    Behavior on hoverGlow { NumberAnimation { duration: 150 } }

    NavGlyph {
        anchors.centerIn: parent
        dir: 0
    }
    MouseArea {
        id: backArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: ApplicationWindow.window.goBack()
    }
}
