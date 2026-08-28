import QtQuick

// 滚轮步进处理器:拦截滚轮,按 px/格 滚动 targetItem.contentY。
// Qt Quick 默认滚轮每格 = QStyleHints::wheelScrollLines()×24(Linux=72px、
// 且该值只读,平台主题提供),太短;本处理器改为配置值。
// 步进优先级:pageStep(页级 config 键)>0 用页级,否则 ConfigManager.wheelStep
// (全局,设置浮窗只暴露此项;页面级靠手改 config.toml 覆盖)。
WheelHandler {
    id: wheel
    // 要滚动的滚动体(Flickable/ListView/GridView;须有 contentY)。
    property Item targetItem: null
    // 页面级步进(px/格);0 = 跟随全局 ConfigManager.wheelStep。
    property int pageStep: 0
    // 笔记本触控板滚动同样视为 wheel 事件,一并接受
    // (Qt 文档:非鼠标硬件的 wheel 事件也可能被 Mouse 过滤)。
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

    onWheel: (event) => {
        if (event.angleDelta.y === 0 || !targetItem)
            return
        const step = wheel.pageStep > 0 ? wheel.pageStep : ConfigManager.wheelStep
        targetItem.contentY -= (event.angleDelta.y / 120) * step
        // 官方 API:手动写 contentY 不触发边界 fixup,写入后调用
        // Flickable::returnToBounds() 按视图自身边界(含 ListView/GridView
        // 的 originY 语义与 header)回弹,防止滚过 hero 上方/内容末尾。
        // 手算边界不可靠(maxYExtent/minYExtent 未暴露给 QML;contentY
        // 正/负域随 view 的 origin 而变),交给视图自己的 fixup。
        if (typeof targetItem.returnToBounds === "function")
            targetItem.returnToBounds()
        event.accepted = true
    }
}
