pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import MoePlayer.Core

//! 播放窗口:MpvItem 渲染视频,UI 控件由 QML 自绘(播放/暂停/进度/音量/全屏)。
//! 鼠标/键盘事件不再转发给 mpv,由 QML 层直接调用 MpvItem API。
//! 保留 Emby 播放状态回传:起播、10s 进度、暂停、停止、每 10 分钟 Ping。
Window {
    id: root
    width: 960
    height: 540
    visible: true
    title: root.loading ? Qt.application.name + " · 正在获取播放地址…" : Qt.application.name
    color: "black"

    function mediaDisplayName() {
        if (root.meta && root.meta.displayName && root.meta.displayName.length > 0)
            return root.meta.displayName
        return mpv.mediaTitle || (source.length ? source.split("/").pop() : "")
    }

    function syncTitle() {
        if (root.loading) {
            root.title = Qt.application.name + " · 正在获取播放地址…"
            return
        }
        const mt = root.mediaDisplayName()
        let t = mt
        if (mpv.playlistCount > 1)
            t = "[" + (mpv.playlistPos + 1) + "/" + mpv.playlistCount + "] " + mt
        root.title = t ? Qt.application.name + " · " + t : Qt.application.name
    }

    onLoadingChanged: root.syncTitle()

    property string source: ""
    property var headers: []
    // 播放元数据:{itemId, mediaSourceId, playSessionId, playMethod}。
    property var meta: ({})

    // 协商中(窗口已建、播放地址未到):显示加载态,startPlayback 后隐藏。
    property bool loading: false
    // 协商失败文案:非空显示失败态(错误信息 + 关闭按钮)。
    property string loadError: ""

    readonly property bool reporting: meta && meta.playSessionId !== undefined && meta.playSessionId !== ""
    property double lastProgressReport: 0
    // 最后已知播放位置:关窗时 mpv 已复位(time-pos 失效),回传须用缓存值。
    property double lastPosition: 0
    // 媒体总时长缓存(播完判定用)。
    property double lastDuration: 0
    // 续播位置(100ns ticks,来自详情页继续观看),起播后跳转。
    readonly property double resumeTicks: (meta && meta.resumePositionTicks) || 0

    readonly property bool isMaximized: root.visibility === Window.Maximized

    // 供 Connections 处理器引用:Qt 6.11 中信号处理器函数内的 id 解析
    // 在部分实例上会得到 null(运行时报 TypeError),绑定求值于创建时,
    // 持有的是实例引用,不经过运行时 id 查找。
    readonly property var owner: root

    // 停止回传已发出(stop 触发的 playbackEnded 不再重复上报)。
    property bool stoppedReported: false

    // 自定义 UI 显隐。
    property bool controlsVisible: true
    readonly property bool isFullScreen: root.visibility === Window.FullScreen

    // 官方 tc_left/tc_right 点击交互:毫秒显示 / 总时长-剩余切换。
    property bool tcMs: false
    property bool tcTotal: false
    // 控制栏标题文本(官方 title;seekbar 悬停章节时替换为 "Chapter: 名称")。
    property string oscTitleText: root.mediaDisplayName()

    // 版本/音轨/字幕信息(来自 EmbyClient.fetchPlaybackInfo 返回的 meta)。
    property var mediaSources: []
    property var audioStreams: []
    property var subtitleStreams: []
    property int currentAudioIndex: -1
    property int currentSubtitleIndex: -1
    property bool switchingVersion: false

    // 剧集分集列表(仅 Emby 剧集,按季/集排序),供上一集/下一集切换。
    property var episodePlaylist: []
    readonly property bool hasEpisodePlaylist: root.episodePlaylist.length > 0
    // 播放列表预载:分集协商完成后 append 进 mpv,对齐 mpv playlist 顺序。
    property bool playlistReady: false
    // mpv 播放列表索引 → episodePlaylist 索引(失败项跳过导致错位时映射)。
    property var mpvToEp: []
    // 预载协商结果缓存(itemId → {url, headers, meta}),mpv 切集时应用。
    property var pendingMeta: ({})
    property bool precacheActive: false
    property var precacheQueue: []
    property int precacheInFlight: 0
    property int precacheDone: 0
    property int precacheTotal: 0

    // 窗口关闭完成(Main 据此从播放窗口列表移除)。
    signal windowClosed()
    // 正常播完(错误退出不发):主窗口据此重拉当前页已看/进度。
    signal playbackFinished()

    // 播放地址协商完成:设置元数据并起播(先开窗后台协商模式下,
    // 窗口创建时无 source,起播统一经此入口)。
    function startPlayback(url, headers, meta) {
        root.source = url
        root.headers = headers || []
        root.meta = meta || {}
        root.loading = false
        root.loadError = ""

        // 保存版本/音轨/字幕信息。
        root.mediaSources = root.meta.mediaSources || []
        root.audioStreams = root.meta.audioStreams || []
        root.subtitleStreams = root.meta.subtitleStreams || []
        // 默认选中 Emby 返回的默认轨(通过 isDefault 标记)。
        root.currentAudioIndex = root.defaultStreamIndex(root.audioStreams)
        root.currentSubtitleIndex = root.defaultStreamIndex(root.subtitleStreams)

        // 属于某剧集时拉取全部分集,供上一集/下一集切换。
        root.episodePlaylist = []
        if (root.meta.seriesId) {
            EmbyClient.fetchAllEpisodes(root.meta.serverUrl, root.meta.token,
                                        root.meta.userId, root.meta.seriesId)
        }

        root.syncTitle()
        mpv.load(url, root.headers)
    }
    // 返回默认轨索引;无默认则取第一个。
    function defaultStreamIndex(streams) {
        for (let i = 0; i < streams.length; ++i) {
            if (streams[i].isDefault)
                return i
        }
        return streams.length > 0 ? 0 : -1
    }
    // 协商失败:显示错误态,由用户关闭(或直接点窗口 X)。
    function showLoadError(message) {
        root.loading = false
        root.loadError = message || ""
    }

    // 关窗时上报最终位置(用缓存值,mpv 已停止读取不到)并停止播放:
    // Window.close() 只隐藏窗口,对象与 mpv 继续存活、音频照播。
    onClosing: {
        if (root.reporting && !root.stoppedReported) {
            root.stoppedReported = true
            EmbyClient.reportPlaybackStopped(root.meta.serverUrl, root.meta.token,
                                             root.meta.userId, root.meta.itemId,
                                             root.meta.mediaSourceId, root.meta.playSessionId,
                                             root.lastPosition)
        }
        mpv.command(["stop"])
        root.windowClosed()
        // 隐藏窗口的 MpvItem/mpv 残留,显式销毁释放。
        root.destroy()
    }

    onActiveChanged: if (active) keyCatcher.forceActiveFocus()
    Component.onCompleted: keyCatcher.forceActiveFocus()

    MpvItem {
        id: mpv
        anchors.fill: parent
        Component.onCompleted: {
            // 播放流代理:配置层已限 HTTP(https 目标走 CONNECT 隧道)。
            mpv.httpProxy = ConfigManager.proxy
            // 先开窗后协商模式:创建时 source 为空,起播统一经
            // root.startPlayback;仅在调用方直接携带 url 创建时立即加载。
            if (root.source !== "")
                load(root.source, root.headers)
        }
    }

    // 标题随 mpv 媒体标题/播放列表变化同步;播放列表就绪后切集应用协商 meta。
    Connections {
        target: mpv
        function onMediaTitleChanged() { root.syncTitle() }
        function onPlaylistPosChanged() {
            root.syncTitle()
            root.applyPlaylistMeta()
        }
        function onPlaylistCountChanged() { root.syncTitle() }
    }

    // 代理热重载:新开的流用新代理(进行中的流不受影响)。
    Connections {
        target: ConfigManager
        function onProxyChanged() {
            mpv.httpProxy = ConfigManager.proxy
        }
    }

    // 播放状态回传驱动。用 Connections 而非 MpvItem 内联 handler:
    // Qt 6.11 中属性 change 信号的内联 handler 作用域异常,引用 root 会得到 null。
    Connections {
        target: mpv
        // 与文件级 owner 同机制:处理器函数内 id 解析不可靠,经绑定期
        // 捕获的实例引用访问 root;声明为本对象属性可让 qmllint 识别。
        property var owner: root.owner
        // 开始解码(时长首次有效) → 上报播放开始;续播则跳到上次位置。
        function onPlaybackStarted() {
            owner.lastDuration = mpv.duration
            if (owner.reporting)
                // 回传按源路由:凭据随 meta 携带(见 fetchPlaybackInfo)。
                EmbyClient.reportPlaybackStart(owner.meta.serverUrl, owner.meta.token,
                                               owner.meta.userId, owner.meta.itemId,
                                               owner.meta.mediaSourceId, owner.meta.playSessionId,
                                               owner.meta.playMethod, 0)
            if (owner.resumeTicks > 0)
                mpv.seek(owner.resumeTicks / Constants.ticksPerSecond)
        }
        // 播放中每 10 秒上报一次进度。
        function onPositionChanged() {
            owner.lastPosition = mpv.position
            if (!owner.reporting || mpv.state !== "playing")
                return
            const now = Date.now()
            if (now - owner.lastProgressReport >= Constants.progressReportMs) {
                owner.lastProgressReport = now
                EmbyClient.reportPlaybackProgress(owner.meta.serverUrl, owner.meta.token,
                                                  owner.meta.userId, owner.meta.itemId,
                                                  owner.meta.mediaSourceId, owner.meta.playSessionId,
                                                  owner.meta.playMethod, mpv.position, false)
            }
        }
        // 暂停/恢复等状态变化立即上报一次(携带 IsPaused)。
        function onStateChanged() {
            if (!owner.reporting || mpv.state === "idle")
                return
            EmbyClient.reportPlaybackProgress(owner.meta.serverUrl, owner.meta.token,
                                              owner.meta.userId, owner.meta.itemId,
                                              owner.meta.mediaSourceId, owner.meta.playSessionId,
                                              owner.meta.playMethod, mpv.position,
                                              mpv.state === "paused")
        }
        // 播放结束(正常播完或出错) → 上报停止。
        // resume 位置与已看由服务器维护(Progress 每 10s 写入位置,
        // 播完 ≥90% 时服务器自动标已看)。
        function onPlaybackEnded(error) {
            if (owner.reporting && !owner.stoppedReported) {
                owner.stoppedReported = true
                EmbyClient.reportPlaybackStopped(owner.meta.serverUrl, owner.meta.token,
                                                 owner.meta.userId, owner.meta.itemId,
                                                 owner.meta.mediaSourceId, owner.meta.playSessionId,
                                                 owner.lastPosition)
            }
            // 正常播完:通知主窗口重拉当前页(等效替代 WS 实时推送)。
            if (!error)
                owner.playbackFinished()
        }
    }

    // 播放中每 10 分钟 Ping 一次,维持服务器会话。
    Timer {
        interval: Constants.pingIntervalMs
        running: root.reporting && mpv.state !== "idle"
        repeat: true
        onTriggered: EmbyClient.reportPlaybackPing(root.meta.serverUrl, root.meta.token,
                                                   root.meta.userId, root.meta.playSessionId)
    }

    // 播放协商回调:预载 append / 版本切换两路。
    Connections {
        target: EmbyClient
        function onPlaybackReady(serverUrl, url, headers, meta) {
            // 预载:播放列表其余集协商完成 → 缓存 + 推进队列;全部完成 → 对齐 mpv 列表。
            // 多窗口并存时另一窗口的响应也会广播到此:按 serverUrl + 本剧集
            // itemId 归属过滤,防止串扰推进计数导致列表缺集。
            if (root.precacheActive
                    && serverUrl === root.meta.serverUrl
                    && root.episodePlaylist.some(function (e) { return e.id === meta.itemId })) {
                root.pendingMeta[meta.itemId] = { url: url, headers: headers || [], meta: meta }
                root.precacheInFlight = Math.max(0, root.precacheInFlight - 1)
                root.precacheDone++
                if (root.precacheDone >= root.precacheTotal) {
                    root.precacheActive = false
                    root.finalizePlaylist()
                } else {
                    root.pumpPrecache()
                }
                return
            }
            if (!root.switchingVersion)
                return
            root.switchingVersion = false
            if (serverUrl !== root.meta.serverUrl || meta.itemId !== root.meta.itemId)
                return
            const savedPos = root.lastPosition
            root.stoppedReported = false
            root.meta = Object.assign({}, meta)
            root.source = url
            root.headers = headers || []
            root.mediaSources = meta.mediaSources || []
            root.audioStreams = meta.audioStreams || []
            root.subtitleStreams = meta.subtitleStreams || []
            root.currentAudioIndex = root.defaultStreamIndex(root.audioStreams)
            root.currentSubtitleIndex = root.defaultStreamIndex(root.subtitleStreams)
            mpv.load(url, root.headers)
            if (savedPos > 0)
                mpv.seek(savedPos)
        }
    }

    // 剧集全部分集到达:构建分集播放列表(按季号/集号排序)。
    Connections {
        target: EmbyClient
        function onAllEpisodesReady(serverUrl) {
            if (!root.meta.seriesId || serverUrl !== root.meta.serverUrl)
                return
            const model = EmbyClient.allEpisodesModelFor(serverUrl)
            const list = []
            for (let i = 0; i < model.count; ++i) {
                const it = model.itemAt(i)
                if (!it || !it.id)
                    continue
                const no = (it.seasonNo > 0 && it.episodeNo > 0)
                           ? "S" + it.seasonNo + "E" + it.episodeNo + " "
                           : ""
                list.push({
                    id: it.id,
                    title: (no + (it.name || "未知")).trim(),
                    seasonNo: it.seasonNo || 0,
                    episodeNo: it.episodeNo || 0
                })
            }
            list.sort(function (a, b) {
                if (a.seasonNo !== b.seasonNo)
                    return a.seasonNo - b.seasonNo
                return a.episodeNo - b.episodeNo
            })
            root.episodePlaylist = list
            root.startPrecache()
        }
    }

    // 播放列表预载:起播后协商其余全部分集 URL(受限并发 4,按距当前集
    // 距离排序:先下一集/上一集,再逐步外扩),全部就绪后按集序 append
    // 进 mpv 并重排当前集位置,使 mpv 原生 playlist-prev/next、媒体键、
    // > / <、Shift+Home/End 全部生效,且顺序正确。
    function startPrecache() {
        if (root.precacheActive || root.playlistReady)
            return
        const cur = root.findEpisodeIndex()
        if (cur < 0 || root.episodePlaylist.length <= 1)
            return
        const q = []
        for (let d = 1; d < root.episodePlaylist.length; ++d) {
            if (cur + d < root.episodePlaylist.length)
                q.push(cur + d)
            if (cur - d >= 0)
                q.push(cur - d)
        }
        root.precacheQueue = q
        root.precacheTotal = q.length
        root.precacheDone = 0
        root.precacheInFlight = 0
        root.precacheActive = true
        root.pumpPrecache()
    }
    function pumpPrecache() {
        while (root.precacheInFlight < 4 && root.precacheQueue.length > 0) {
            const idx = root.precacheQueue.shift()
            const ep = root.episodePlaylist[idx]
            root.precacheInFlight++
            EmbyClient.fetchPlaybackInfo(root.meta.serverUrl, root.meta.token,
                                         root.meta.userId, ep.id, "",
                                         root.meta.seriesId)
        }
    }
    // 全部就绪:按集序 append(跳过协商失败项),move 当前集到正确位置,
    // 构建 mpv 索引 → 集索引映射。
    function finalizePlaylist() {
        const curIdx = root.findEpisodeIndex()
        if (curIdx < 0) {
            root.playlistReady = true
            return
        }
        const succeeded = []
        for (let i = 0; i < root.episodePlaylist.length; ++i) {
            if (i !== curIdx && root.pendingMeta[root.episodePlaylist[i].id])
                succeeded.push(i)
        }
        // mpv 命令按队列顺序执行,append 顺序即集序(当前集已在 index 0)。
        for (const i of succeeded)
            mpv.command(["loadfile", root.pendingMeta[root.episodePlaylist[i].id].url, "append"])
        // 当前集移到位置 t(它前面成功项的个数):playlist-move 0 → t+1。
        const t = succeeded.filter(function (i) { return i < curIdx }).length
        if (t > 0)
            mpv.command(["playlist-move", "0", String(t + 1)])
        // 索引映射:mpv pos → episodePlaylist index(有失败项时防止错位)。
        const mpvToEp = []
        for (const i of succeeded) if (i < curIdx) mpvToEp.push(i)
        mpvToEp.push(curIdx)
        for (const i of succeeded) if (i > curIdx) mpvToEp.push(i)
        root.mpvToEp = mpvToEp
        root.playlistReady = true
        root.oscTitleText = root.mediaDisplayName()
    }
    // mpv 原生切集(playlist-prev/next、媒体键、> / <、播完自动连播)后:
    // 应用该集的协商 meta(回传会话/轨道),外挂字幕自动加载。
    function applyPlaylistMeta() {
        if (!root.playlistReady)
            return
        const pos = mpv.playlistPos
        if (pos < 0 || pos >= root.mpvToEp.length)
            return
        const ep = root.episodePlaylist[root.mpvToEp[pos]]
        if (!ep || ep.id === root.meta.itemId)
            return
        const pm = root.pendingMeta[ep.id]
        if (!pm)
            return
        // 手动切集(playlist-prev/next/菜单)不经过 end-file:先上报旧会话停止,
        // 避免服务器会话残留与进度串集。
        if (root.reporting && !root.stoppedReported) {
            root.stoppedReported = true
            EmbyClient.reportPlaybackStopped(root.meta.serverUrl, root.meta.token,
                                             root.meta.userId, root.meta.itemId,
                                             root.meta.mediaSourceId, root.meta.playSessionId,
                                             root.lastPosition)
        }
        root.meta = Object.assign({}, pm.meta)
        root.mediaSources = pm.meta.mediaSources || []
        root.audioStreams = pm.meta.audioStreams || []
        root.subtitleStreams = pm.meta.subtitleStreams || []
        root.currentAudioIndex = root.defaultStreamIndex(root.audioStreams)
        root.currentSubtitleIndex = root.defaultStreamIndex(root.subtitleStreams)
        root.lastPosition = 0
        root.stoppedReported = false
        root.lastProgressReport = 0
        // 默认音轨交给 mpv(新文件自动选);外挂字幕 mpv 不会自动加载,需 sub-add。
        if (root.subtitleStreams.length > 0)
            root.setSubtitleStream(root.currentSubtitleIndex)
        else
            mpv.command(["set", "sid", "no"])
        root.syncTitle()
    }
    // 预载项协商失败:跳过该项(推进计数,不阻塞其余)。
    Connections {
        target: EmbyClient
        function onPlaybackFailed(serverUrl, itemId, message) {
            if (!root.precacheActive || serverUrl !== root.meta.serverUrl)
                return
            if (!root.episodePlaylist.some(function (e) { return e.id === itemId }))
                return
            root.precacheInFlight = Math.max(0, root.precacheInFlight - 1)
            root.precacheDone++
            if (root.precacheDone >= root.precacheTotal) {
                root.precacheActive = false
                root.finalizePlaylist()
            } else {
                root.pumpPrecache()
            }
        }
    }

    // ---------- 自绘播放 UI ----------
    function toggleFullscreen() {
        root.visibility = root.isFullScreen ? Window.Windowed : Window.FullScreen
    }
    function toggleMaximize() {
        if (root.isFullScreen)
            root.visibility = Window.Windowed
        else if (root.isMaximized)
            root.visibility = Window.Windowed
        else
            root.visibility = Window.Maximized
    }
    function playPause() {
        if (mpv.state === "playing")
            mpv.setPause(true)
        else if (mpv.state === "paused")
            mpv.setPause(false)
    }
    function seekRelative(seconds) {
        const pos = mpv.position + seconds
        mpv.seek(Math.max(0, Math.min(pos, mpv.duration || pos)))
    }
    function seekTo(ratio) {
        const pos = (mpv.duration || 0) * Math.max(0, Math.min(1, ratio))
        mpv.seek(pos)
    }
    // 精确 seek(非关键帧对齐,no-osd 不弹提示):官方 Shift+方向键。
    function seekRelativeExact(seconds) {
        mpv.command(["no-osd", "seek", String(seconds), "exact"])
    }
    // 官方 PgUp/PgDn:有章节切章节,无章节回退 ±10 分钟。
    function seekChapterOr(dir, fallbackSecs) {
        if (mpv.chapterList.length > 0)
            mpv.command(["add", "chapter", String(dir)])
        else
            mpv.seek(mpv.position + fallbackSecs)
    }
    // 倍速:absolute=true 直接 set,否则 multiply(官方 [ ] { } 语义)。
    // mpv.speed 属性异步推送,OSD 文案按期望值计算显示。
    function changeSpeed(factor, absolute) {
        if (absolute) {
            mpv.command(["set", "speed", String(factor)])
            root.osd("速度: " + root.formatSpeed(factor) + "×")
        } else {
            mpv.command(["multiply", "speed", String(factor)])
            root.osd("速度: " + root.formatSpeed(mpv.speed * factor) + "×")
        }
    }
    function formatSpeed(v) {
        const r = Math.round(v * 100) / 100
        return (Math.abs(r % 1) < 1e-9) ? String(r) : r.toFixed(2).replace(/0$/, "")
    }
    // 音量增减并 OSD 提示(官方 / * 与滚轮路径)。
    function adjustVolume(delta) {
        mpv.volume = Math.max(0, Math.min(100, mpv.volume + delta))
        root.osd("音量: " + mpv.volume + "%")
    }
    // mpv 内置 OSD 文本提示(渲染进视频帧,样式后续定制)。
    function osd(message) {
        mpv.command(["show-text", message, "1500"])
    }
    // 官方 T:窗口置顶切换(WindowStaysOnTopHint)。
    function toggleOnTop() {
        root.flags = root.flags & Qt.WindowStaysOnTopHint
                ? (root.flags & ~Qt.WindowStaysOnTopHint)
                : (root.flags | Qt.WindowStaysOnTopHint)
        root.osd(root.flags & Qt.WindowStaysOnTopHint ? "置顶: 开" : "置顶: 关")
    }
    // 官方 DEL(osc/visibility):控制栏显隐切换。
    function toggleControls() {
        root.controlsVisible = !root.controlsVisible
        if (root.controlsVisible)
            hideControlsTimer.restart()
    }
    // 官方 Alt+0/1/2:窗口缩放(基准 960×540)。
    function setWindowScale(scale) {
        root.width = Math.round(960 * scale)
        root.height = Math.round(540 * scale)
    }
    // 官方 F8:播放列表文本(剧集用分集列表,电影回退 mpv 播放列表)。
    function playlistSummary() {
        if (root.episodePlaylist.length > 0) {
            const cur = root.findEpisodeIndex()
            const lines = []
            for (let i = 0; i < root.episodePlaylist.length; ++i) {
                const mark = i === cur ? "▶ " : "  "
                lines.push(mark + (i + 1) + ". " + root.episodePlaylist[i].title)
            }
            return "播放列表:\n" + lines.join("\n")
        }
        if (mpv.playlistCount <= 0)
            return "播放列表: 空"
        const lines = []
        for (let i = 0; i < mpv.playlist.length; ++i) {
            const mark = i === mpv.playlistPos ? "▶ " : "  "
            lines.push(mark + (i + 1) + ". " + root.playlistLabel(mpv.playlist[i]))
        }
        return "播放列表:\n" + lines.join("\n")
    }
    // 官方 F9:轨道列表文本。
    function trackSummary() {
        const lines = []
        if (root.audioStreams.length > 0) {
            lines.push("音轨:")
            for (let i = 0; i < root.audioStreams.length; ++i) {
                const mark = i === root.currentAudioIndex ? "▶ " : "  "
                lines.push(mark + root.streamLabel(root.audioStreams[i]))
            }
        }
        if (root.subtitleStreams.length > 0) {
            lines.push("字幕:")
            lines.push((root.currentSubtitleIndex < 0 ? "▶ " : "  ") + "关闭")
            for (let i = 0; i < root.subtitleStreams.length; ++i) {
                const mark = i === root.currentSubtitleIndex ? "▶ " : "  "
                lines.push(mark + root.streamLabel(root.subtitleStreams[i]))
            }
        }
        return lines.length > 0 ? lines.join("\n") : "轨道: 无"
    }
    function formatTime(seconds, withMs) {
        const s = Math.max(0, seconds || 0)
        const h = Math.floor(s / 3600)
        const m = Math.floor((s % 3600) / 60)
        const sec = Math.floor(s % 60)
        const mm = m < 10 ? "0" + m : m
        const ss = sec < 10 ? "0" + sec : sec
        let t = h > 0 ? h + ":" + mm + ":" + ss : mm + ":" + ss
        if (withMs) {
            const ms = Math.floor((s - Math.floor(s)) * 1000)
            t += "." + (ms < 100 ? "0" : "") + (ms < 10 ? "0" : "") + ms
        }
        return t
    }
    // 官方 seekbar 拖动:absolute-percent(关键帧对齐,seekbarkeyframes 默认)。
    function seekToExact(ratio) {
        const pct = Math.max(0, Math.min(100, ratio * 100))
        mpv.command(["seek", String(pct), "absolute-percent"])
    }
    // 官方 seekbar 右键:跳到最近章节。
    function seekToNearestChapter(ratio) {
        if (mpv.chapterList.length === 0 || mpv.duration <= 0)
            return
        const targetSec = ratio * mpv.duration
        let nearest = null
        let minDist = Infinity
        for (const c of mpv.chapterList) {
            const d = Math.abs(c.time - targetSec)
            if (d < minDist) {
                minDist = d
                nearest = c
            }
        }
        if (nearest)
            mpv.seek(nearest.time)
    }
    // 官方 cache 元素文本:"Cache: 1m30s"(无缓存返回空,隐藏)。
    function cacheLabel() {
        const s = mpv.demuxerCacheDuration
        if (s <= 0)
            return ""
        const min = Math.floor(s / 60)
        const sec = Math.floor(s % 60)
        return min > 0
                ? "Cache: " + min + "m" + (sec < 10 ? "0" : "") + sec + "s"
                : "Cache: " + Math.round(s) + "s"
    }
    // 官方 volume 图标档位(1-3 档 + 静音)。
    function volIcon() {
        if (mpv.mute || mpv.volume <= 0)
            return "mute"
        return "volume" + Math.max(1, Math.min(3, Math.ceil(mpv.volume / 34)))
    }
    function streamLabel(stream) {
        if (!stream)
            return ""
        if (stream.displayTitle)
            return stream.displayTitle
        const parts = []
        if (stream.title)
            parts.push(stream.title)
        if (stream.displayLanguage)
            parts.push(stream.displayLanguage)
        else if (stream.language)
            parts.push(stream.language)
        if (stream.codec)
            parts.push(stream.codec.toUpperCase())
        return parts.length > 0 ? parts.join(" · ") : "未知"
    }
    // 播放列表项标签:title 优先,否则文件名尾段(mpv playlist NODE 字段)。
    function playlistLabel(item) {
        if (!item)
            return ""
        if (item.title)
            return item.title
        const f = item.filename || ""
        const i = f.lastIndexOf("/")
        return i >= 0 ? f.substring(i + 1) : f
    }
    // 生成指定类型的轨道菜单项(audio/sub)。
    function trackMenuItems(type) {
        return mpv.trackList.filter(t => t.type === type).map(t => {
            let label = t.title || t.lang || "未知"
            if (t.codec) label += " · " + t.codec.toUpperCase()
            if (t.lang) label += " · " + t.lang
            if (t.external) label += " · 外挂"
            if (t.default) label += " · 默认"
            if (t.forced) label += " · 强制"
            return { id: t.id, title: label }
        })
    }
    function currentTrackId(type) {
        for (const t of mpv.trackList) {
            if (t.type === type && t.selected)
                return t.id
        }
        return undefined
    }
    function openTrackMenu(type) {
        const items = root.trackMenuItems(type)
        selectMenu.title = type === "audio" ? "音轨" : "字幕"
        selectMenu.model = items
        selectMenu.currentId = root.currentTrackId(type)
        selectMenu.onSelect = function(id) {
            mpv.command(["set", type === "audio" ? "aid" : "sid", String(id)])
        }
        selectMenu.open()
    }
    function openAudioTrackMenu() {
        selectMenu.anchorItem = oscAudio
        root.openTrackMenu("audio")
    }
    function openSubtitleTrackMenu() {
        selectMenu.anchorItem = oscSub
        root.openTrackMenu("sub")
    }
    function openAudioDeviceMenu() {
        selectMenu.title = "音频设备"
        selectMenu.model = mpv.audioDeviceList.map(d => ({ id: d.name, title: d.description || d.name }))
        selectMenu.currentId = undefined
        selectMenu.anchorItem = oscVol
        selectMenu.onSelect = function(id) {
            mpv.command(["set", "audio-device", id])
        }
        selectMenu.open()
    }
    function openVersionMenu() {
        const items = root.mediaSources.map(s => ({ id: s.id, title: s.name || "默认版本" }))
        selectMenu.title = "版本"
        selectMenu.model = items
        selectMenu.currentId = root.meta.mediaSourceId
        selectMenu.anchorItem = oscVersion
        selectMenu.onSelect = function(id) {
            if (id && id !== root.meta.mediaSourceId)
                root.switchVersion(id)
        }
        selectMenu.open()
    }
    // 播放列表菜单(官方 menu ≡ / select/select-playlist):列出分集,点击跳转。
    function openPlaylistMenu() {
        if (root.episodePlaylist.length === 0) {
            root.osd("无播放列表")
            return
        }
        const items = []
        for (let i = 0; i < root.episodePlaylist.length; ++i)
            items.push({ id: root.episodePlaylist[i].id, title: (i + 1) + ". " + root.episodePlaylist[i].title })
        selectMenu.anchorItem = menuBtn
        selectMenu.title = "播放列表"
        selectMenu.model = items
        selectMenu.currentId = root.meta.itemId
        selectMenu.onSelect = function (id) {
            // mpv 列表对齐后经映射定位切换;预载未完成时忽略(稍后重试)。
            if (!root.playlistReady)
                return
            let epIdx = -1
            for (let i = 0; i < root.episodePlaylist.length; ++i) {
                if (root.episodePlaylist[i].id === id) { epIdx = i; break }
            }
            const mpvIdx = root.mpvToEp.indexOf(epIdx)
            if (mpvIdx >= 0)
                mpv.command(["set", "playlist-pos", String(mpvIdx)])
        }
        selectMenu.open()
    }
    function setAudioStream(index) {
        root.currentAudioIndex = index
        const s = root.audioStreams[index]
        if (s)
            mpv.command(["set", "aid", String(s.index)])
    }
    function setSubtitleStream(index) {
        root.currentSubtitleIndex = index
        if (index < 0 || !root.subtitleStreams[index]) {
            mpv.command(["set", "sid", "no"])
            return
        }
        const s = root.subtitleStreams[index]
        if (s.isExternal && s.deliveryUrl) {
            // 外挂字幕先加载再选择:补全前缀并附带 api_key(与主视频流
            // withApiKey 同法,字幕接口同样需要认证;mpv 命令无头可带)。
            let u = root.meta.serverUrl
                     + (s.deliveryUrl.startsWith("/") ? s.deliveryUrl : "/" + s.deliveryUrl)
            if (root.meta.token && u.indexOf("api_key=") < 0)
                u += (u.indexOf("?") >= 0 ? "&" : "?") + "api_key=" + root.meta.token
            mpv.command(["sub-add", u])
        }
        mpv.command(["set", "sid", String(s.index)])
    }
    function switchVersion(mediaSourceId) {
        if (!mediaSourceId || mediaSourceId === root.meta.mediaSourceId || root.switchingVersion)
            return
        root.switchingVersion = true
        const pos = mpv.position
        root.lastPosition = pos
        EmbyClient.fetchPlaybackInfo(root.meta.serverUrl, root.meta.token,
                                     root.meta.userId, root.meta.itemId,
                                     mediaSourceId, root.meta.seriesId || "")
    }

    // 分集切换:当前集在分集列表中的索引。
    function findEpisodeIndex() {
        for (let i = 0; i < root.episodePlaylist.length; ++i) {
            if (root.episodePlaylist[i].id === root.meta.itemId)
                return i
        }
        return -1
    }
    // 分集切换:mpv 播放列表已预载对齐,上一项/下一项即上一集/下一集。
    function playPrevEpisode() { mpv.command(["playlist-prev"]) }
    function playNextEpisode() { mpv.command(["playlist-next"]) }

    // 自动隐藏控制栏。
    Timer {
        id: hideControlsTimer
        interval: 3000
        repeat: false
        onTriggered: {
            if (!controlBarArea.containsMouse)
                root.controlsVisible = false
        }
    }
    function showControls() {
        root.controlsVisible = true
        hideControlsTimer.restart()
    }

    // 视频区域鼠标交互:移动显示控件,点击播放/暂停,双击全屏,滚轮音量,
    // Ctrl+左键拖拽平移(官方 Ctrl+MBTN_LEFT drag-to-pan)。
    MouseArea {
        id: overlayMouse
        anchors.fill: parent
        hoverEnabled: true
        property bool panDragging: false
        property point panStart
        onPositionChanged: function (mouse) {
            if (panDragging) {
                const dx = (mouse.x - panStart.x) / overlayMouse.width
                const dy = (mouse.y - panStart.y) / overlayMouse.height
                if (dx !== 0) mpv.command(["add", "video-pan-x", dx.toFixed(3)])
                if (dy !== 0) mpv.command(["add", "video-pan-y", dy.toFixed(3)])
                panStart = Qt.point(mouse.x, mouse.y)
            } else {
                root.showControls()
            }
        }
        onPressed: function (mouse) {
            root.showControls()
            const ctrl = mouse.modifiers & Qt.ControlModifier
            if (ctrl && mouse.button === Qt.LeftButton) {
                panDragging = true
                panStart = Qt.point(mouse.x, mouse.y)
                return
            }
            // 右键 = 上下文菜单(官方 MBTN_RIGHT script-binding select/context-menu
            // → 本项目的设置弹窗);侧键 = 播放列表切换;左键点击非控件区暂停。
            if (mouse.button === Qt.RightButton) {
                root.openPlaylistMenu()
            } else if (mouse.button === Qt.BackButton) {
                root.playPrevEpisode()
            } else if (mouse.button === Qt.ForwardButton) {
                root.playNextEpisode()
            } else if (!controlBarArea.containsMouse) {
                root.playPause()
            }
        }
        onReleased: panDragging = false
        onDoubleClicked: root.toggleFullscreen()
        onWheel: function (wheel) {
            root.showControls()
            const ctrl = wheel.modifiers & Qt.ControlModifier
            if (ctrl) {
                // Ctrl+滚轮:光标缩放(官方 positioning/cursor-centric-zoom 近似)。
                mpv.command(["add", "video-zoom", wheel.angleDelta.y > 0 ? "0.1" : "-0.1"])
                return
            }
            if (wheel.angleDelta.x !== 0) {
                // 横向滚轮:seek ±10(官方 WHEEL_LEFT/RIGHT)。
                mpv.seek(mpv.position + (wheel.angleDelta.x > 0 ? 10 : -10))
                return
            }
            // 官方 WHEEL_UP/DOWN:音量 ±2。
            root.adjustVolume(wheel.angleDelta.y / 120 * 2)
        }
    }

    // 底部控制栏:官方 osc bottombar 布局(高 56,两行:上排工具行
    // menu/播放列表/标题/缓存,下排控制行 播放/章节/时间/seekbar/轨道/音量/全屏)。
    Rectangle {
        id: controlBar
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 56
        color: Qt.rgba(0, 0, 0, 0.69) // 官方 boxalpha=80
        opacity: root.controlsVisible ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 220 } }

        MouseArea {
            id: controlBarArea
            anchors.fill: parent
            hoverEnabled: true
            onPositionChanged: root.showControls()
        }

        // 上排(官方 line1,高 27)。
        Row {
            id: oscTopRow
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 27
            leftPadding: 9
            spacing: 9

            // 菜单(官方 menu ≡:select/menu → 本项目设置弹窗)。
            OscButton {
                id: menuBtn
                width: 18
                height: 27
                iconScale: 0.8
                oscIcon: "menu"
                onClicked: root.openPlaylistMenu()
            }
            // 标题(官方 title:${playlist-pos}/${count} ${media-title};
            // seekbar 悬停到章节时显示 "Chapter: 名称")。
            AppText {
                id: oscTitle
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 90 - 9 - (oscCache.visible ? 159 : 0)
                text: root.oscTitleText
                color: "white"
                font.pixelSize: 13
                elide: Text.ElideRight
            }
            // 缓存文本(官方 cache,无缓存隐藏)。
            AppText {
                id: oscCache
                anchors.verticalCenter: parent.verticalCenter
                width: 150
                text: root.cacheLabel()
                color: "white"
                font.pixelSize: 13
                horizontalAlignment: Text.AlignRight
                visible: text !== ""
            }
        }

        // 下排(官方 line2,高 29)。
        Row {
            id: oscBotRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 2
            height: 29
            leftPadding: 9
            spacing: 9

            // 播放列表上一项(官方 playlist_prev,仅多于一集时显示)。
            OscButton {
                id: oscPlaylistPrev
                width: 27
                height: 29
                oscIcon: "prev"
                visible: root.hasEpisodePlaylist || mpv.playlistCount > 1
                onClicked: root.playPrevEpisode()
            }
            // 播放/暂停(官方 play_pause;缓冲中显示时钟图标)。
            OscButton {
                id: ppBtn
                width: 27
                height: 29
                oscIcon: mpv.pausedForCache ? "clock"
                        : (mpv.state === "paused" ? "play" : "pause")
                onClicked: root.playPause()
            }
            // 播放列表下一项(官方 playlist_next,仅多于一集时显示)。
            OscButton {
                id: oscPlaylistNext
                width: 27
                height: 29
                oscIcon: "next"
                visible: root.hasEpisodePlaylist || mpv.playlistCount > 1
                onClicked: root.playNextEpisode()
            }
            // 左时间码(官方 tc_left:当前时间,点击切毫秒)。
            AppText {
                id: tcLeft
                anchors.verticalCenter: parent.verticalCenter
                width: 110
                text: root.formatTime(mpv.position, root.tcMs)
                color: "white"
                font.pixelSize: 13
                horizontalAlignment: Text.AlignRight
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.tcMs = !root.tcMs
                }
            }
            // 进度条(官方 seekbar,bar 样式:白轨道 + 白进度 + 章节标记 +
            // 悬停竖线与时间提示 + 拖动 absolute-percent)。
            Item {
                id: seekBar
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(80, parent.width - 625)
                height: 29
                property real progress: mpv.duration > 0 ? mpv.position / mpv.duration : 0
                property real hoverX: 0
                property real hoverRatio: 0
                property bool hoverActive: false

                // 轨道(官方 bgbar1:白,alpha boxalpha+(255-boxalpha)*0.8≈220)。
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: 4
                    color: Qt.rgba(1, 1, 1, 0.86)
                }
                // 缓存范围(覆盖在未播区,浅白)。
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    x: parent.width * seekBar.progress
                    width: Math.max(0, Math.min(parent.width - x,
                                                  parent.width * (mpv.demuxerCacheDuration / mpv.duration)))
                    height: 4
                    color: Qt.rgba(1, 1, 1, 0.4)
                    visible: mpv.demuxerCacheDuration > 0 && mpv.duration > 0
                }
                // 已播部分。
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * seekBar.progress
                    height: 4
                    color: "white"
                }
                // 章节标记(官方 nibbles:轨道上下缘 2px 小齿)。
                Repeater {
                    model: mpv.chapterList
                    delegate: Rectangle {
                        required property var modelData
                        anchors.verticalCenter: parent.verticalCenter
                        visible: mpv.duration > 0
                        x: (modelData.time / mpv.duration) * parent.width - 1
                        width: 2
                        height: 4
                        color: "white"
                        opacity: 0.7
                    }
                }
                // 悬停竖线(官方 hover_bar)。
                Rectangle {
                    x: seekBar.hoverX - 0.75
                    y: 0
                    width: 1.5
                    height: parent.height
                    color: "white"
                    opacity: seekBar.hoverActive ? 0.8 : 0
                }
                // 悬停时间提示(官方 tooltip:白字黑描边,上浮)。
                AppText {
                    id: seekTooltipText
                    x: Math.max(0, Math.min(parent.width - width, seekBar.hoverX - width / 2))
                    y: -22
                    text: root.formatTime(seekBar.hoverRatio * mpv.duration)
                    color: "white"
                    font.pixelSize: 15
                    style: Text.Outline
                    styleColor: "black"
                    visible: seekBar.hoverActive && mpv.duration > 0
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onPressed: function (mouse) {
                        if (mouse.button === Qt.RightButton) {
                            root.seekToNearestChapter(mouse.x / seekBar.width)
                            return
                        }
                        root.seekToExact(mouse.x / seekBar.width)
                    }
                    onPositionChanged: {
                        if (pressed && (mouse.buttons & Qt.LeftButton))
                            root.seekToExact(mouse.x / seekBar.width)
                        seekBar.hoverX = mouse.x
                        seekBar.hoverRatio = Math.max(0, Math.min(1, mouse.x / seekBar.width))
                        // 官方:悬停位置有章节时标题栏显示 "Chapter: 名称"。
                        if (mpv.chapterList.length > 0 && mpv.duration > 0) {
                            const sec = seekBar.hoverRatio * mpv.duration
                            let ch = null
                            for (const c of mpv.chapterList) {
                                if (c.time <= sec) ch = c
                                else break
                            }
                            root.oscTitleText = ch && ch.title ? "Chapter: " + ch.title : root.mediaDisplayName()
                        }
                    }
                    onEntered: seekBar.hoverActive = true
                    onExited: {
                        seekBar.hoverActive = false
                        root.oscTitleText = root.mediaDisplayName()
                    }
                    // 官方 scrollcontrols:seekbar 悬停滚轮 seek ±10。
                    onWheel: mpv.seek(mpv.position + (wheel.angleDelta.y > 0 ? 10 : -10))
                }
            }
            // 右时间码(官方 tc_right:剩余时长,点击切总时长)。
            AppText {
                id: tcRight
                anchors.verticalCenter: parent.verticalCenter
                width: 110
                text: root.tcTotal
                        ? root.formatTime(mpv.duration, root.tcMs)
                        : "-" + root.formatTime(Math.max(0, mpv.duration - mpv.position), root.tcMs)
                color: "white"
                font.pixelSize: 13
                horizontalAlignment: Text.AlignLeft
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.tcTotal = !root.tcTotal
                }
            }
            // 音轨按钮(官方 audio_track:图标 + 当前/总数;左键 cycle,右键菜单)。
            OscButton {
                id: oscAudio
                width: 90
                height: 29
                oscIcon: "audio"
                inlineText: root.audioStreams.length > 0
                        ? (root.currentAudioIndex >= 0 ? root.currentAudioIndex + 1 : "-")
                          + "/" + root.audioStreams.length
                        : ""
                onClicked: mpv.command(["cycle", "audio"])
                onSecondaryClicked: root.openAudioTrackMenu()
                WheelHandler {
                    acceptedModifiers: Qt.NoModifier
                    onWheel: function (event) {
                        mpv.command(event.angleDelta.y > 0 ? ["cycle", "audio", "up"] : ["cycle", "audio"])
                    }
                }
            }
            // 字幕按钮(官方 sub_track)。
            OscButton {
                id: oscSub
                width: 90
                height: 29
                oscIcon: "subtitle"
                inlineText: root.subtitleStreams.length > 0
                        ? (root.currentSubtitleIndex >= 0 ? root.currentSubtitleIndex + 1 : "-")
                          + "/" + root.subtitleStreams.length
                        : ""
                onClicked: mpv.command(["cycle", "sub"])
                onSecondaryClicked: root.openSubtitleTrackMenu()
                WheelHandler {
                    acceptedModifiers: Qt.NoModifier
                    onWheel: function (event) {
                        mpv.command(event.angleDelta.y > 0 ? ["cycle", "sub", "up"] : ["cycle", "sub"])
                    }
                }
            }
            // 版本切换(Emby 多版本影片特有,mpv 原生无此概念)。
            OscButton {
                id: oscVersion
                width: 70
                height: 29
                oscIcon: ""
                inlineText: "版本"
                visible: root.mediaSources.length > 1
                onClicked: root.openVersionMenu()
            }
            // 音量(官方 volume:点击静音,悬停滚轮 ±5,图标四档;右键音频设备)。
            OscButton {
                id: oscVol
                width: 27
                height: 29
                oscIcon: root.volIcon()
                onClicked: mpv.toggleMute()
                onSecondaryClicked: root.openAudioDeviceMenu()
                WheelHandler {
                    acceptedModifiers: Qt.NoModifier
                    onWheel: function (event) {
                        root.adjustVolume(event.angleDelta.y / 120 * 5)
                    }
                }
            }
        }
    }

    // 右键 select 菜单(音轨 / 字幕 / 音频设备)。
    SelectMenu {
        id: selectMenu
        visible: false
        z: 30
    }
    MouseArea {
        anchors.fill: parent
        visible: selectMenu.visible
        onClicked: selectMenu.close()
        z: 29
    }

    // 键盘处理:完整对齐 mpv 官方 etc/input.conf 默认绑定(逐条核对,含
    // 修饰组合)。冲突决策:1-8 画质、9/0 音量(官方语义,原 0-9 跳转
    // 百分比移除,自定义阶段再加回);F 全屏(官方 f;官方 F=字幕字号
    // 改由 G/Shift+G);t/T 区分大小写(字幕位置/置顶);q/Ctrl+w 关窗
    // (官方 quit,本项目关播放窗不退出主程序);stats/console/osd-level/
    // select 脚本绑定不适用,菜单类映射到设置弹窗;KP 键系(无小键盘)
    // 与 legacy !/@ 章节省略。
    Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function (event) {
            const key = event.key
            const shift = event.modifiers & Qt.ShiftModifier
            const ctrl = event.modifiers & Qt.ControlModifier
            const alt = event.modifiers & Qt.AltModifier

            // 菜单(官方 ctrl+p select/menu、MENU、Shift+F10 context-menu → 设置弹窗)
            if ((ctrl && key === Qt.Key_P) || key === Qt.Key_Menu
                    || (shift && key === Qt.Key_F10)) { root.openPlaylistMenu(); event.accepted = true }
            // 播放控制
            else if (key === Qt.Key_Space || (key === Qt.Key_P && !shift)) { root.playPause(); event.accepted = true }
            else if (key === Qt.Key_Q) { root.close(); event.accepted = true }
            else if (key === Qt.Key_O || (key === Qt.Key_P && shift)) { mpv.command(["show-progress"]); event.accepted = true }
            else if (key === Qt.Key_L) { shift ? mpv.command(["cycle-values", "loop-file", "inf", "no"])
                                               : mpv.command(["ab-loop"]); event.accepted = true }
            else if (key === Qt.Key_D) { mpv.command(["cycle", "deinterlace"]); event.accepted = true }
            else if (key === Qt.Key_B) { mpv.command(["cycle", "deband"]); event.accepted = true }

            // 视频平移/重置(Alt 组合须在普通方向/BS 分支之前)
            else if (alt && key === Qt.Key_Left) { mpv.command(["add", "video-pan-x", "0.1"]); event.accepted = true }
            else if (alt && key === Qt.Key_Right) { mpv.command(["add", "video-pan-x", "-0.1"]); event.accepted = true }
            else if (alt && key === Qt.Key_Up) { mpv.command(["add", "video-pan-y", "0.1"]); event.accepted = true }
            else if (alt && key === Qt.Key_Down) { mpv.command(["add", "video-pan-y", "-0.1"]); event.accepted = true }
            else if (alt && key === Qt.Key_Backspace) {
                mpv.command(["set", "video-zoom", "0"])
                mpv.command(["no-osd", "set", "panscan", "0"])
                mpv.command(["no-osd", "set", "video-pan-x", "0"])
                mpv.command(["no-osd", "set", "video-pan-y", "0"])
                mpv.command(["no-osd", "set", "video-align-x", "0"])
                mpv.command(["no-osd", "set", "video-align-y", "0"])
                event.accepted = true
            }
            // 字幕定位 seek(官方 Ctrl+Shift+←/→ sub-step、Ctrl+←/→ sub-seek)
            else if (ctrl && shift && key === Qt.Key_Left) { mpv.command(["no-osd", "sub-step", "-1"]); event.accepted = true }
            else if (ctrl && shift && key === Qt.Key_Right) { mpv.command(["no-osd", "sub-step", "1"]); event.accepted = true }
            else if (ctrl && key === Qt.Key_Left) { mpv.command(["no-osd", "sub-seek", "-1"]); event.accepted = true }
            else if (ctrl && key === Qt.Key_Right) { mpv.command(["no-osd", "sub-seek", "1"]); event.accepted = true }
            // 常规 seek(官方方向键;Shift 精确 seek)
            else if (key === Qt.Key_Left) { root.seekRelativeExact(shift ? -1 : -5); event.accepted = true }
            else if (key === Qt.Key_Right) { root.seekRelativeExact(shift ? 1 : 5); event.accepted = true }
            else if (key === Qt.Key_Up) { root.seekRelativeExact(shift ? 5 : 60); event.accepted = true }
            else if (key === Qt.Key_Down) { root.seekRelativeExact(shift ? -5 : -60); event.accepted = true }
            else if (key === Qt.Key_PageUp) { root.seekChapterOr(shift ? 600 : 1, 600); event.accepted = true }
            else if (key === Qt.Key_PageDown) { root.seekChapterOr(shift ? -600 : -1, -600); event.accepted = true }
            else if (key === Qt.Key_Home) { shift ? mpv.command(["no-osd", "set", "playlist-pos", "0"])
                                                  : mpv.seek(0); event.accepted = true }
            else if (key === Qt.Key_End && shift) { mpv.command(["no-osd", "set", "playlist-pos-1", "${playlist-count}"]); event.accepted = true }
            // 倍速/回退(官方 BS 速度重置、Shift+BS revert-seek、Shift+Ctrl+BS 标记)
            else if (key === Qt.Key_Backspace) {
                if (shift && ctrl) mpv.command(["revert-seek", "mark"])
                else if (shift) mpv.command(["revert-seek"])
                else root.changeSpeed(1.0, true)
                event.accepted = true
            }
            else if (key === Qt.Key_Period) { mpv.command(["frame-step"]); event.accepted = true }
            else if (key === Qt.Key_Comma) { mpv.command(["frame-back-step"]); event.accepted = true }
            else if (key === Qt.Key_Greater || key === Qt.Key_Return || key === Qt.Key_Enter) { root.playNextEpisode(); event.accepted = true }
            else if (key === Qt.Key_Less) { root.playPrevEpisode(); event.accepted = true }

            // 窗口缩放(官方 Alt+0/1/2;须在画质/音量分支前)
            else if (alt && key === Qt.Key_0) { root.setWindowScale(0.5); event.accepted = true }
            else if (alt && key === Qt.Key_1) { root.setWindowScale(1.0); event.accepted = true }
            else if (alt && key === Qt.Key_2) { root.setWindowScale(2.0); event.accepted = true }

            // 倍速(官方 [ ] { } 与 BS 重置)
            else if (key === Qt.Key_BracketLeft) { root.changeSpeed(1 / 1.1); event.accepted = true }
            else if (key === Qt.Key_BracketRight) { root.changeSpeed(1.1); event.accepted = true }
            else if (key === Qt.Key_BraceLeft) { root.changeSpeed(0.5); event.accepted = true }
            else if (key === Qt.Key_BraceRight) { root.changeSpeed(2.0); event.accepted = true }

            // 轨道/字幕
            else if (key === Qt.Key_J) { mpv.command(shift ? ["cycle", "sub", "down"] : ["cycle", "sub"]); event.accepted = true }
            else if (key === Qt.Key_NumberSign) { mpv.command(["cycle", "audio"]); event.accepted = true }
            else if (key === Qt.Key_Underscore) { mpv.command(["cycle", "video"]); event.accepted = true }
            else if (!ctrl && key === Qt.Key_V) {
                if (alt) mpv.command(["cycle", "secondary-sub-visibility"])
                else if (shift) mpv.command(["cycle", "sub-ass-use-video-data"])
                else mpv.command(["cycle", "sub-visibility"])
                event.accepted = true
            }
            else if (key === Qt.Key_U) { mpv.command(["cycle-values", "sub-ass-override", "force", "scale"]); event.accepted = true }
            else if (key === Qt.Key_G) { mpv.command(["add", "sub-scale", shift ? "-0.1" : "0.1"]); event.accepted = true }
            else if (!ctrl && key === Qt.Key_R) { mpv.command(["add", "sub-pos", shift ? "1" : "-1"]); event.accepted = true }
            else if (!shift && key === Qt.Key_T) { mpv.command(["add", "sub-pos", "1"]); event.accepted = true }
            else if (key === Qt.Key_Z) { mpv.command(["add", "sub-delay", shift ? "0.1" : "-0.1"]); event.accepted = true }
            else if (key === Qt.Key_X) { mpv.command(["add", "sub-delay", "0.1"]); event.accepted = true }

            // 画质(官方 1-8)
            else if (key === Qt.Key_1) { mpv.command(["add", "contrast", "-1"]); event.accepted = true }
            else if (key === Qt.Key_2) { mpv.command(["add", "contrast", "1"]); event.accepted = true }
            else if (key === Qt.Key_3) { mpv.command(["add", "brightness", "-1"]); event.accepted = true }
            else if (key === Qt.Key_4) { mpv.command(["add", "brightness", "1"]); event.accepted = true }
            else if (key === Qt.Key_5) { mpv.command(["add", "gamma", "-1"]); event.accepted = true }
            else if (key === Qt.Key_6) { mpv.command(["add", "gamma", "1"]); event.accepted = true }
            else if (key === Qt.Key_7) { mpv.command(["add", "saturation", "-1"]); event.accepted = true }
            else if (key === Qt.Key_8) { mpv.command(["add", "saturation", "1"]); event.accepted = true }

            // 音量(官方 9 / 0 * 与媒体键)
            else if (key === Qt.Key_9 || key === Qt.Key_Slash) { root.adjustVolume(-2); event.accepted = true }
            else if (key === Qt.Key_0 || key === Qt.Key_Asterisk) { root.adjustVolume(2); event.accepted = true }
            else if (key === Qt.Key_M) { mpv.toggleMute(); event.accepted = true }

            // 视频几何(官方 Alt++/Alt+-/ZOOMIN/ZOOMOUT 缩放、w/W/e panscan、A 纵横比)
            else if (!ctrl && key === Qt.Key_Plus) { mpv.command(["add", "video-zoom", "0.1"]); event.accepted = true }
            else if (!ctrl && key === Qt.Key_Minus) { mpv.command(["add", "video-zoom", "-0.1"]); event.accepted = true }
            else if (key === Qt.Key_ZoomIn) { mpv.command(["add", "video-zoom", "0.1"]); event.accepted = true }
            else if (key === Qt.Key_ZoomOut) { mpv.command(["add", "video-zoom", "-0.1"]); event.accepted = true }
            else if (!ctrl && key === Qt.Key_W) { mpv.command(["add", "panscan", shift ? "0.1" : "-0.1"]); event.accepted = true }
            else if (key === Qt.Key_E) { shift ? mpv.command(["cycle", "edition"])
                                               : mpv.command(["add", "panscan", "0.1"]); event.accepted = true }
            else if (key === Qt.Key_A) { mpv.command(["cycle-values", "video-aspect-override", "16:9", "4:3", "2.35:1", "no"]); event.accepted = true }

            // 窗口
            else if (key === Qt.Key_F) { root.toggleFullscreen(); event.accepted = true }
            else if (key === Qt.Key_Escape) {
                if (root.isFullScreen) { root.visibility = Window.Windowed; event.accepted = true }
            }
            else if (key === Qt.Key_T && shift) { root.toggleOnTop(); event.accepted = true }
            else if (key === Qt.Key_Delete) { root.toggleControls(); event.accepted = true }

            // 系统/同步(Ctrl 组合)
            else if (ctrl && key === Qt.Key_Plus) { mpv.command(["add", "audio-delay", "0.1"]); event.accepted = true }
            else if (ctrl && key === Qt.Key_Minus) { mpv.command(["add", "audio-delay", "-0.1"]); event.accepted = true }
            else if (ctrl && key === Qt.Key_H) { mpv.command(["cycle-values", "hwdec", "no", "auto"]); event.accepted = true }
            else if (ctrl && key === Qt.Key_S) { mpv.command(["screenshot", "window"]); event.accepted = true }
            else if (ctrl && key === Qt.Key_W) { root.close(); event.accepted = true }
            else if (ctrl && key === Qt.Key_C) { root.close(); event.accepted = true }
            else if (ctrl && key === Qt.Key_R) {
                // 官方 Ctrl+r:记住当前位置重载当前文件。
                mpv.command(["no-osd", "set", "file-local-options/start", "${=time-pos}"])
                mpv.command(["playlist-play-index", "current"])
                event.accepted = true
            }

            // 截图(官方 s/S/Ctrl+s/Alt+s)
            else if (key === Qt.Key_S) {
                if (alt) mpv.command(["screenshot", "each-frame"])
                else mpv.command(shift ? ["screenshot", "video"] : ["screenshot"])
                event.accepted = true
            }

            // 媒体键(官方 PLAY/PAUSE/PLAYPAUSE/PLAYONLY/PAUSEONLY/STOP/NEXT/PREV/
            // FORWARD/REWIND/VOLUME_UP/DOWN/MUTE/POWER/CLOSE_WIN)
            else if (key === Qt.Key_MediaTogglePlayPause) { root.playPause(); event.accepted = true }
            else if (key === Qt.Key_MediaPlay) { mpv.setPause(false); event.accepted = true }
            else if (key === Qt.Key_MediaPause) { mpv.setPause(true); event.accepted = true }
            else if (key === Qt.Key_MediaNext) { mpv.command(["playlist-next"]); event.accepted = true }
            else if (key === Qt.Key_MediaPrevious) { mpv.command(["playlist-prev"]); event.accepted = true }
            else if (key === Qt.Key_MediaStop || key === Qt.Key_Power || key === Qt.Key_Close) { root.close(); event.accepted = true }
            else if (key === Qt.Key_MediaForward) { mpv.seek(mpv.position + 60); event.accepted = true }
            else if (key === Qt.Key_MediaRewind) { mpv.seek(mpv.position - 60); event.accepted = true }
            else if (key === Qt.Key_VolumeUp) { root.adjustVolume(2); event.accepted = true }
            else if (key === Qt.Key_VolumeDown) { root.adjustVolume(-2); event.accepted = true }
            else if (key === Qt.Key_VolumeMute) { mpv.toggleMute(); event.accepted = true }

            // 信息(osd 文本;官方 F8 播放列表/F9 轨道列表)
            else if (key === Qt.Key_F8) { root.osd(root.playlistSummary()); event.accepted = true }
            else if (key === Qt.Key_F9) { root.osd(root.trackSummary()); event.accepted = true }

            root.showControls()
        }
    }

    // 协商加载/失败覆盖层:窗口创建即显示加载态,startPlayback 后隐藏;
    // 协商失败显示错误文案 + 关闭按钮(不自动关,用户可查错误信息)。
    Item {
        anchors.fill: parent
        visible: root.loading || root.loadError !== ""
        z: 10
        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0.07, 0.05, 0.09, 0.9)
        }
        Column {
            anchors.centerIn: parent
            spacing: 20
            // 粉圈转圈:Canvas 画 270° 圆弧 + 旋转动画。
            BusyIndicator {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.loading
                running: root.loading
                implicitWidth: 44
                implicitHeight: 44
                contentItem: Canvas {
                    id: spinCanvas
                    width: 44
                    height: 44
                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.reset()
                        ctx.strokeStyle = Constants.moePink
                        ctx.lineWidth = 4
                        ctx.lineCap = "round"
                        ctx.beginPath()
                        ctx.arc(width / 2, height / 2, width / 2 - 6,
                                -Math.PI / 2, Math.PI * 1.4)
                        ctx.stroke()
                    }
                    RotationAnimator on rotation {
                        from: 0; to: 360
                        duration: 900
                        loops: Animation.Infinite
                    }
                }
            }
            AppText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.loading ? "正在获取播放地址…" : "获取播放地址失败"
                color: root.loading ? Theme.textPrimary : Theme.danger
                font.pixelSize: 18
            }
            AppText {
                visible: root.loadError !== ""
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.loadError
                color: Theme.textMuted
                font.pixelSize: 13
                wrapMode: Text.Wrap
                width: Math.min(root.width - 120, 480)
                horizontalAlignment: Text.AlignHCenter
            }
            Button {
                id: errCloseBtn
                visible: root.loadError !== ""
                anchors.horizontalCenter: parent.horizontalCenter
                width: 120
                height: 38
                text: "关闭"
                onClicked: root.close()
                background: Rectangle {
                    radius: height / 2
                    color: errCloseBtn.hovered ? Constants.moePinkDark : Constants.moePink
                }
                contentItem: AppText {
                    text: errCloseBtn.text
                    color: "white"
                    font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }
}
