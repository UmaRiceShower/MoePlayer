import QtQuick
import QtQuick.Controls
import MoePlayer.Playback
import "qrc:/qml/theme"

//! 播放窗口:MpvItem 播放视频,官方 OSC(进度条/按钮/时间)由 mpv 直接绘制。
//! 无自绘控件,鼠标/键盘事件转发给 mpv 以驱动 OSC 交互。
Window {
    id: root
    width: 960
    height: 540
    visible: true
    title: source.length ? "MoePlayer · " + source.split("/").pop() : "MoePlayer"
    color: "black"

    property string source: ""
    property var headers: []

    MpvItem {
        id: mpv
        anchors.fill: parent
        Component.onCompleted: load(root.source, root.headers)
    }

    // 鼠标转发:mpv `mouse <x> <y> <button> [mode]`(button -1=移动,0/1/2=左/中/右键);
    // 滚轮经 `keypress WHEEL_UP|WHEEL_DOWN` 转发。
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onPositionChanged: mpv.command(["mouse", x, y, -1])
        onPressed: function (mouse) {
            const btn = mouse.button === Qt.LeftButton ? 0
                      : mouse.button === Qt.MiddleButton ? 1 : 2
            mpv.command(["mouse", mouse.x, mouse.y, btn, "single"])
        }
        onWheel: function (wheel) {
            if (wheel.angleDelta.y > 0)
                mpv.command(["keypress", "WHEEL_UP"])
            else if (wheel.angleDelta.y < 0)
                mpv.command(["keypress", "WHEEL_DOWN"])
        }
    }

    // 键盘转发:Qt 键码映射到 mpv 键名,经 keypress 下发(MpvItem 已开启默认绑定)。
    Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.onPressed: function (event) {
            const map = {
                [Qt.Key_Space]: "SPACE",
                [Qt.Key_Left]: "LEFT",
                [Qt.Key_Right]: "RIGHT",
                [Qt.Key_Up]: "UP",
                [Qt.Key_Down]: "DOWN",
                [Qt.Key_Escape]: "ESC",
                [Qt.Key_P]: "p",
                [Qt.Key_M]: "m",
                [Qt.Key_F]: "f",
                [Qt.Key_Return]: "ENTER",
                [Qt.Key_Enter]: "ENTER",
                [Qt.Key_Slash]: "/",
                [Qt.Key_Asterisk]: "*",
                [Qt.Key_9]: "9",
                [Qt.Key_0]: "0"
            }
            const name = map[event.key]
            if (name) {
                mpv.command(["keypress", name])
                event.accepted = true
            }
        }
    }

    Component.onCompleted: keyCatcher.forceActiveFocus()
    onActiveChanged: if (active) keyCatcher.forceActiveFocus()
}
