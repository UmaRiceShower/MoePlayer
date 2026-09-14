import QtQuick
import MoePlayer.Core

Item {
    id: root

    readonly property var bg: ThemeStore.background
    // 动效时间:仅"预设含动效且设置未关闭"时由 Timer 推进。
    property real u_time: 0.0


    Timer {
        interval: ThemeStore.frameIntervalMs
        repeat: true
        running: ThemeStore.animated
        onTriggered: root.u_time = (root.u_time + interval / 1000.0) % 100000.0
    }

    ShaderEffectSource {
        id: bgLayer
        anchors.fill: parent
        sourceItem: effect
        hideSource: true
        live: ThemeStore.animated
        textureSize: Qt.size(Math.max(1, Math.ceil(width)), Math.max(1, Math.ceil(height)))
        function refresh() { if (!live) scheduleUpdate() }
        onWidthChanged: refresh()
        onHeightChanged: refresh()
        Component.onCompleted: refresh()
    }
    Connections {
        target: ThemeStore
        function onBackgroundChanged() { bgLayer.refresh() }
        function onIntensityChanged() { bgLayer.refresh() }
    }

    Image {
        id: petalSource
        source: "qrc:/icons/petal.svg"
        sourceSize: Qt.size(96, 96)
        width: 96
        height: 96
    }
    ShaderEffectSource {
        id: petalTex
        sourceItem: petalSource
        hideSource: true
        live: false
        mipmap: true
        textureSize: Qt.size(96, 96)
    }

    ShaderEffect {
        id: effect
        width: root.width
        height: root.height
        property vector2d u_size: Qt.vector2d(width, height)
        property real u_time: root.u_time
        property real u_intensity: ThemeStore.intensity
        property real u_vignette: root.bg.vignette
        property real u_motion: ThemeStore.animated ? Number(root.bg.motion) : 0.0
        property real u_style: Number(root.bg.style)
        property real u_light: Number(root.bg.light)
        property real u_meteorT: ThemeStore.meteorPeriod
        property var u_sprite: petalTex

        property color u_baseTop: root.bg.baseTop
        property color u_baseBottom: root.bg.baseBottom
        property color u_g0Color: root.bg.glow0[0]
        property color u_g1Color: root.bg.glow1[0]
        property color u_g2Color: root.bg.glow2[0]
        property vector4d u_g0: Qt.vector4d(root.bg.glow0[1], root.bg.glow0[2],
                                            root.bg.glow0[3], root.bg.glow0[4])
        property vector4d u_g1: Qt.vector4d(root.bg.glow1[1], root.bg.glow1[2],
                                            root.bg.glow1[3], root.bg.glow1[4])
        property vector4d u_g2: Qt.vector4d(root.bg.glow2[1], root.bg.glow2[2],
                                            root.bg.glow2[3], root.bg.glow2[4])
        fragmentShader: "qrc:/qt/qml/MoePlayer/Core/shaders/background.frag.qsb"
    }
}
