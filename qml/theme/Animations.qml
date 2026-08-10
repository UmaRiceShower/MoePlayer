pragma Singleton
import QtQuick

QtObject {
    readonly property int durationShort: 150
    readonly property int durationMedium: 280
    readonly property int durationLong: 450
    readonly property real springStiffness: 2.0 // 弹簧刚度
    readonly property real springDamping: 0.2   // 弹簧阻尼
}
