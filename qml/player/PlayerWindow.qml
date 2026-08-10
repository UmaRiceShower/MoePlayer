import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import MoePlayer.Playback
import "qrc:/qml/theme"

//! 播放窗口:MpvItem 播放视频,官方 OSC(进度条/按钮/时间)由 mpv 直接绘制。
//! 无自绘控件,鼠标/键盘事件转发给 mpv 以驱动 OSC 交互。
//! 携带播放元数据(meta)时执行 Emby 播放状态回传:
//! 起播 reportStart,播放中每 10s reportProgress,结束/关窗 reportStopped,每 10 分钟 Ping。
Window {
    id: root
    width: 960
    height: 540
    visible: true
    title: source.length ? "MoePlayer · " + source.split("/").pop() : "MoePlayer"
    color: "black"

    property string source: ""
    property var headers: []
    // 播放元数据:{itemId, mediaSourceId, playSessionId, playMethod};演示流为空对象。
    property var meta: ({})

    readonly property bool reporting: meta && meta.playSessionId !== undefined && meta.playSessionId !== ""
    property double lastProgressReport: 0

    MpvItem {
        id: mpv
        anchors.fill: parent
        Component.onCompleted: load(root.source, root.headers)

        // 开始解码(时长首次有效) → 上报播放开始。
        onPlaybackStarted: {
            if (root.reporting)
                EmbyClient.reportPlaybackStart(root.meta.itemId, root.meta.mediaSourceId,
                                               root.meta.playSessionId, root.meta.playMethod, 0)
        }
        // 播放中每 10 秒上报一次进度。
        onPositionChanged: {
            if (!root.reporting || mpv.state !== "playing")
                return
            const now = Date.now()
            if (now - root.lastProgressReport >= 10000) {
                root.lastProgressReport = now
                EmbyClient.reportPlaybackProgress(root.meta.itemId, root.meta.mediaSourceId,
                                                  root.meta.playSessionId, root.meta.playMethod,
                                                  mpv.position, false)
            }
        }
        // 暂停/恢复等状态变化立即上报一次(携带 IsPaused)。
        onStateChanged: {
            if (!root.reporting || mpv.state === "idle")
                return
            EmbyClient.reportPlaybackProgress(root.meta.itemId, root.meta.mediaSourceId,
                                              root.meta.playSessionId, root.meta.playMethod,
                                              mpv.position, mpv.state === "paused")
        }
        // 播放结束(正常播完或出错) → 上报停止。
        onPlaybackEnded: function (error) {
            if (root.reporting)
                EmbyClient.reportPlaybackStopped(root.meta.itemId, root.meta.mediaSourceId,
                                                 root.meta.playSessionId, mpv.position)
        }
    }

    // 播放中每 10 分钟 Ping 一次,维持服务器会话。
    Timer {
        interval: 600000
        running: root.reporting && mpv.state !== "idle"
        repeat: true
        onTriggered: EmbyClient.reportPlaybackPing(root.meta.playSessionId)
    }

    // 关窗时上报最终位置。
    onClosing: {
        if (root.reporting)
            EmbyClient.reportPlaybackStopped(root.meta.itemId, root.meta.mediaSourceId,
                                             root.meta.playSessionId, mpv.position)
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
