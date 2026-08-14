import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import "qrc:/qml/theme"

//! 条目详情页(Hero + 左栏正文 + 右侧竖向选集条)。
//! 无状态浏览:详情/播放协商/已看/收藏/相似推荐均按 serverUrl 凭据路由。
//! 选集条替代原"分季→全屏分集网格":剧集页与集详情页共用右侧竖向列表,
//! 滚轮/上下键滚动,hover 放大;点集原地替换(集详情页内切集,不叠栈)。
Item {
    id: root

    property string itemId: ""
    property string posterId: ""
    property string title: ""
    // 条目所在服务器:所有请求按该服务器凭据路由(无状态)。
    property string serverUrl: ""

    signal playRequested(string url, var headers, var meta)
    signal backRequested()

    // 详情间导航历史(相似推荐原地替换):栈内保存被替换前的条目,
    // back 时逐级恢复,替代"压新页再 pop"的整页重建。
    property var detailHistory: []
    // 相似推荐数据已过期(条目切换后、新推荐到达前):隐藏旧推荐防误导。
    property bool similarStale: true
    // 相似推荐双击防抖(沿用原 Main 侧逻辑)。
    property string lastItemPush: ""
    property int lastItemPushTime: 0
    // 原地替换动画:数据落地前先淡出旧正文(replacing 期间 detail 暂存
    // pendingDetail),动画中 applyDetail 落地并淡入,完成后复位。
    // 只对文字层淡入淡出(textFade),图片各自走圆形扩散溶解(CrossfadeImage)。
    property bool replacing: false
    property var pendingDetail: null
    // 文字层透明度:详情切换时正文文字淡出→换字→淡入;图片不受此影响。
    property real textFade: 1

    // 该服务器凭据(账号缺失返回空 map)。
    function creds() {
        return AccountManager.credsForServer(root.serverUrl)
    }

    // 标识本页为详情页(Main 据此防止双击卡片重复 push)。
    readonly property bool isDetailPage: true

    property var detail: ({})
    property bool isFavorite: false
    // 海报莫奈取色背景顶色(heroBackdrop 渐变起点);取色未完成/失败回退 surface。
    property color heroFrom: {
        const pid = root.detail.posterId || root.posterId
        const c = ColorProvider.colors[pid]
        return c ? c.heroFrom : Theme.surface
    }
    // 莫奈强调色(播放按钮/季胶囊选中/选集行/进度条);取色未完成/失败回退 accent。
    property color accentColor: {
        const pid = root.detail.posterId || root.posterId
        const c = ColorProvider.colors[pid]
        return c ? c.accent : Theme.accent
    }
    // 分裂互补辅助色(次要按钮/描边/焦点,30% 层)与极暗藏色(渐变暗部埋补色)。
    property color complementColor: {
        const pid = root.detail.posterId || root.posterId
        const c = ColorProvider.colors[pid]
        return c ? c.complement : Theme.textMuted
    }
    property color complementDark: {
        const pid = root.detail.posterId || root.posterId
        const c = ColorProvider.colors[pid]
        return c ? c.complementDark : Theme.bg
    }
    // 背景藏色倾向(带海报色相,取代中性灰);surfaceTint 用于卡片底色。
    property color bgTint: {
        const pid = root.detail.posterId || root.posterId
        const c = ColorProvider.colors[pid]
        return c ? c.bgTint : Theme.bg
    }
    property color surfaceTint: {
        const pid = root.detail.posterId || root.posterId
        const c = ColorProvider.colors[pid]
        return c ? c.surfaceTint : Theme.surface
    }
    // detail 是否已加载完成(首次进入/切集前为 false → 显示加载动画,
    // 到达后一次性渲染完整结构,避免介绍/演员逐块出现推动按钮位置)。
    property bool loaded: false
    // 选集条当前季(Season id);空=尚未选择。
    property string currentSeasonId: ""
    // 选季胶囊状态:候选季号(滚轮调整,按服务器实际季遍历)、实际季号列表。
    property int seasonCandidate: 1
    property var seasonNos: []

    // ---- 播放:Series/Episode/Movie 统一走 playItem,按目标条目 id 协商。 ----
    property string pendingPlayItemId: ""
    property double resumeTicks: 0
    property bool playbackPending: false

    function playItem(itemId, resume) {
        if (root.playbackPending || !itemId)
            return
        root.playbackPending = true
        root.pendingPlayItemId = itemId
        root.resumeTicks = resume
        const c = root.creds()
        EmbyClient.fetchPlaybackInfo(root.serverUrl, c.token, c.userId, itemId)
    }
    // 播放当前详情条目:resume 为 true 时从上次位置续播。
    function startPlayback(resume) {
        const t = resume && root.detail.positionTicks > 0 && !root.detail.played
                ? root.detail.positionTicks : 0
        root.playItem(root.itemId, t)
    }
    // 剧集页播放:跨季续播(全部集里第一条有进度的),否则第一集。
    function playSeries() {
        const model = EmbyClient.allEpisodesModelFor(root.serverUrl)
        let target = null
        for (let i = 0; i < model.count; i++) {
            const it = model.itemAt(i)
            if (it.positionTicks > 0 && !it.played) { target = it; break }
        }
        if (!target && model.count > 0)
            target = model.itemAt(0)
        if (!target)
            return
        root.playItem(target.id, target.positionTicks > 0 && !target.played ? target.positionTicks : 0)
    }
    function playButtonText() {
        if (root.detail.positionTicks > 0 && !root.detail.played)
            return "从 " + formatTime(root.detail.positionTicks / Constants.ticksPerSecond) + " 继续播放"
        return "播放"
    }
    function seriesPlayText() {
        const model = EmbyClient.allEpisodesModelFor(root.serverUrl)
        for (let i = 0; i < model.count; i++) {
            const it = model.itemAt(i)
            if (it.positionTicks > 0 && !it.played)
                return "继续观看" + (it.seasonNo > 0 && it.episodeNo > 0 ? " S" + it.seasonNo + "E" + it.episodeNo : "")
        }
        return "播放"
    }

    function toggleFavorite() {
        root.isFavorite = !root.isFavorite
        const c = root.creds()
        EmbyClient.setFavorite(root.serverUrl, c.token, c.userId, root.itemId, root.isFavorite)
    }
    function toggleWatched() {
        const played = !root.detail.played
        const c = root.creds()
        EmbyClient.setWatched(root.serverUrl, c.token, c.userId,
                              root.itemId, played, 0, played ? 100 : 0)
    }

    // ---- 原地替换(切集/相似推荐/返回恢复):更新自身 id 触发
    // onItemIdChanged 重拉,不重建页面。旧正文保持显示直到新 detail
    // 到达,选集/推荐区先行清空,图片经 retainWhileLoading 无空白换新。 ----
    function replaceItem(newItemId, newPosterId, newTitle) {
        root.itemId = newItemId
        root.posterId = newPosterId
        root.title = newTitle
        // 重置条目相关状态:季与收藏(新 detail 到达前不显示旧条目状态)、
        // 候选季、相似推荐(stale 隐藏旧推荐)、滚动回顶。
        root.currentSeasonId = ""
        root.isFavorite = false
        root.seasonNos = []
        root.seasonCandidate = 1
        root.similarStale = true
        root.replacing = true
        overview.contentY = 0
    }
    // 相似推荐点击:压历史(记录当前条目)后原地替换,不 push 新页。
    function openItemDetail(itemId, posterId, title, serverUrl) {
        const now = Date.now()
        if (itemId === root.lastItemPush && now - root.lastItemPushTime < Constants.episodePushDebounceMs)
            return
        root.lastItemPush = itemId
        root.lastItemPushTime = now
        // 历史深度上限,防相似推荐链无限增长。
        if (root.detailHistory.length >= 16)
            root.detailHistory.shift()
        root.detailHistory.push({
            itemId: root.itemId, posterId: root.posterId,
            title: root.title, serverUrl: root.serverUrl
        })
        root.replaceItem(itemId, posterId, title)
    }
    // 返回键:集详情先原地回父剧详情;否则沿详情历史逐级恢复;
    // 历史空则 pop 回上层页(首页/库)。
    function back() {
        if (root.detail.type === "Episode" && root.detail.seriesId) {
            root.replaceItem(root.detail.seriesId, "", root.detail.seriesName)
            return
        }
        if (root.detailHistory.length > 0) {
            const prev = root.detailHistory.pop()
            root.replaceItem(prev.itemId, prev.posterId, prev.title)
            return
        }
        root.backRequested()
    }
    // 数据落地:赋值 detail 并拉选集/推荐(正文替换的"换字"一步)。
    // fromReplace 时正文已淡出,落地后触发标题推入(fadeInOut 后半段淡入)。
    function applyDetail(d, fromReplace) {
        root.detail = d
        root.isFavorite = d.isFavorite
        // 海报莫奈取色(背景渐变顶色);幂等,后台线程执行,完成后淡入。
        // detail.posterId 为权威(带服务器前缀),缺省回退 push 参数。
        ColorProvider.requestColor(root.detail.posterId || root.posterId)
        const c = root.creds()
        // 选集条季列表:剧集自身 / 集详情的父剧。
        // 有选集(剧集/集详情)时 loaded 延迟到分集到达才置 true(见
        // onEpisodesReceived),避免选集栏先渲染旧数据再跳新数据。
        if (d.type === "Series") {
            EmbyClient.fetchSeasons(root.serverUrl, c.token, c.userId, d.id)
            // 全部集(跨季),供"继续观看"按进度定位目标集。
            EmbyClient.fetchAllEpisodes(root.serverUrl, c.token, c.userId, d.id)
        } else if (d.type === "Episode" && d.seriesId) {
            EmbyClient.fetchSeasons(root.serverUrl, c.token, c.userId, d.seriesId)
        } else {
            // 电影等无选集:detail 到达即渲染完整结构。
            root.loaded = true
        }
        // 相似推荐(剧集/电影/分集都拉,空则整段隐藏)。
        // 拉取期间 stale 隐藏旧推荐,similarReady 到达后恢复。
        root.similarStale = true
        EmbyClient.fetchSimilar(root.serverUrl, c.token, c.userId, root.itemId)
        if (fromReplace) {
            // 标题推入:上移 8px(淡入由 textFade 统一驱动,不再手动置 opacity)。
            heroTitleShift.y = 8
            titleReveal.start()
        }
    }

    // 正文文字交叉淡化:淡出文字 → 落地新数据 → 淡入文字。
    // 图片(backdrop/海报/演职/缩略图)不走此层,各自圆形扩散溶解。
    SequentialAnimation {
        id: fadeInOut
        NumberAnimation {
            target: root
            property: "textFade"
            to: 0
            duration: 140
            easing.type: Easing.InQuad
        }
        ScriptAction {
            script: {
                const d = root.pendingDetail
                root.pendingDetail = null
                root.applyDetail(d, true)
            }
        }
        NumberAnimation {
            target: root
            property: "textFade"
            to: 1
            duration: 160
            easing.type: Easing.OutCubic
        }
        onFinished: root.replacing = false
        onStopped: {
            root.replacing = false
            root.textFade = 1
        }
    }
    // 标题推入:替换落地时标题区上移 8px(淡入由 textFade 统一驱动)。
    ParallelAnimation {
        id: titleReveal
        NumberAnimation {
            target: heroTitleShift
            property: "y"
            from: 8
            to: 0
            duration: 200
            easing.type: Easing.OutCubic
        }
    }
    // 首次进入/切集共用:原地替换时保持旧正文显示(loaded 不变,新
    // detail 到达后文字同帧替换),首次进入 loaded 默认 false 显示加载动画。
    function reload() {
        root.playbackPending = false
        const c = root.creds()
        if (root.itemId !== "")
            EmbyClient.fetchItemDetail(root.serverUrl, c.token, c.userId, root.itemId)
    }
    // 播放后刷新:保留当前结构与旧数据,静默重拉(不闪加载动画)。
    function refreshAfterPlayback() {
        const c = root.creds()
        if (root.itemId !== "")
            EmbyClient.fetchItemDetail(root.serverUrl, c.token, c.userId, root.itemId)
    }
    // 选集条选季:拉该季分集并回顶部。
    function selectSeason(seasonId) {
        root.currentSeasonId = seasonId
        const seriesId = root.detail.type === "Series" ? root.detail.id : root.detail.seriesId
        if (seriesId && seasonId) {
            const c = root.creds()
            EmbyClient.fetchEpisodes(root.serverUrl, c.token, c.userId, seriesId, seasonId)
        }
        episodeList.contentY = 0
    }

    // ---- 选季胶囊 ----
    // 两位数补零(季号显示两位)。
    function pad2(n) {
        return ("0" + n).slice(-2)
    }
    // 当前选中季的季号(seasons 模型中按 currentSeasonId 查;未选中返回 0)。
    function currentSeasonNo() {
        const m = EmbyClient.seasonsModelFor(root.serverUrl)
        for (let i = 0; i < m.count; ++i) {
            if (m.itemAt(i).id === root.currentSeasonId)
                return m.itemAt(i).seasonNo
        }
        return 0
    }
    // 提取服务器实际返回的季号列表(升序;季号可能不连续,如 1-17、23)。
    function refreshSeasonNos() {
        const m = EmbyClient.seasonsModelFor(root.serverUrl)
        const arr = []
        for (let i = 0; i < m.count; ++i)
            arr.push(m.itemAt(i).seasonNo)
        arr.sort((a, b) => a - b)
        root.seasonNos = arr
    }
    // 候选在当前实际季号列表中的索引;不在返回 -1。
    function seasonIndex() {
        for (let i = 0; i < root.seasonNos.length; ++i) {
            if (root.seasonNos[i] === root.seasonCandidate)
                return i
        }
        return -1
    }
    // 候选的上一季季号(列表内);无则 -1。
    function seasonPrevNo() {
        const i = root.seasonIndex()
        return i > 0 ? root.seasonNos[i - 1] : -1
    }
    // 候选的下一季季号(列表内);无则 -1。
    function seasonNextNo() {
        const i = root.seasonIndex()
        return i >= 0 && i < root.seasonNos.length - 1 ? root.seasonNos[i + 1] : -1
    }
    // 候选回到当前季(鼠标移开/点到别处,不跳转)。
    function resetSeasonCandidate() {
        root.seasonCandidate = root.currentSeasonNo()
        if (root.seasonIndex() === -1 && root.seasonNos.length > 0)
            root.seasonCandidate = root.seasonNos[0] // 当前季不在列表时取第一季
    }
    // 滚轮步进候选季(仅遍历服务器实际返回的季,跳过不存在的季号)。
    function stepCandidate(delta) {
        if (root.seasonNos.length === 0)
            return
        let i = root.seasonIndex()
        if (i === -1)
            i = delta > 0 ? -1 : root.seasonNos.length // 从端点进入
        i = Math.max(0, Math.min(root.seasonNos.length - 1, i + delta))
        root.seasonCandidate = root.seasonNos[i]
    }
    // 点击确认:候选即实际存在的季 → 直接按季号定位并跳转。
    function confirmSeason() {
        const target = root.seasonCandidate
        const m = EmbyClient.seasonsModelFor(root.serverUrl)
        let bestId = ""
        for (let i = 0; i < m.count; ++i) {
            if (m.itemAt(i).seasonNo === target) {
                bestId = m.itemAt(i).id
                break
            }
        }
        if (bestId)
            root.selectSeason(bestId)
    }

    // pop 回来时共享模型(seasons/episodes/similar/allEpisodes 按 serverUrl
    // 字典化)可能已被栈内其他详情页覆盖(同服务器单模型),重拉本页数据;
    // episodes 经 onSeasonsReceived → selectSeason 链重拉,季保持 currentSeasonId。
    function resyncModels() {
        if (root.itemId === "")
            return
        const c = root.creds()
        const seriesId = root.detail.type === "Series" ? root.detail.id : root.detail.seriesId
        if (seriesId)
            EmbyClient.fetchSeasons(root.serverUrl, c.token, c.userId, seriesId)
        if (root.detail.type === "Series")
            EmbyClient.fetchAllEpisodes(root.serverUrl, c.token, c.userId, root.detail.id)
        EmbyClient.fetchSimilar(root.serverUrl, c.token, c.userId, root.itemId)
    }


    // ---- 显示辅助 ----
    function heroTitle() {
        if (root.detail.type === "Episode") {
            let t = root.detail.seriesName || root.title
            if (root.detail.seasonNo > 0 && root.detail.episodeNo > 0)
                t += " · S" + root.detail.seasonNo + "E" + root.detail.episodeNo
            if (root.detail.name)
                t += " · " + root.detail.name
            return t
        }
        return root.detail.name || root.title
    }
    function metaLine() {
        let parts = []
        if (root.detail.rating > 0)
            parts.push("★ " + root.detail.rating.toFixed(1))
        if (root.detail.year > 0)
            parts.push(String(root.detail.year))
        if (root.detail.genres && root.detail.genres.length > 0)
            parts.push(root.detail.genres.join("/"))
        if (root.detail.runtimeSecs > 0)
            parts.push(formatTime(root.detail.runtimeSecs))
        return parts.join(" · ")
    }
    function heroPosterSource() {
        if (root.detail.posterId)
            return "image://emby/" + root.detail.posterId
        if (root.posterId !== "")
            return "image://emby/" + root.posterId
        return ""
    }
    function backdropSource() {
        if (root.detail.backdropId)
            return "image://emby/" + root.detail.backdropId
        if (root.detail.parentBackdropId)
            return "image://emby/" + root.detail.parentBackdropId
        return ""
    }
    function formatTime(s) {
        if (s < 0)
            s = 0
        const h = Math.floor(s / 3600)
        const m = Math.floor((s % 3600) / 60)
        const sec = Math.floor(s % 60)
        const mm = m < 10 ? "0" + m : m
        const ss = sec < 10 ? "0" + sec : sec
        return h > 0 ? h + ":" + mm + ":" + ss : mm + ":" + ss
    }
    function formatSize(bytes) {
        if (!bytes || bytes <= 0)
            return ""
        const gb = bytes / (1024 * 1024 * 1024)
        if (gb >= 1)
            return gb.toFixed(1) + " GB"
        const mb = bytes / (1024 * 1024)
        return mb.toFixed(0) + " MB"
    }
    function formatBitrate(bps) {
        if (!bps || bps <= 0)
            return ""
        const mbps = bps / 1000000
        if (mbps >= 1)
            return mbps.toFixed(1) + " Mbps"
        return (bps / 1000).toFixed(0) + " kbps"
    }
    function streamLabel(s) {
        if (s.type === "Video") {
            const parts = ["视频", s.codec ? s.codec.toUpperCase() : ""]
            if (s.profile)
                parts.push(s.profile)
            if (s.width > 0 && s.height > 0)
                parts.push(s.width + "×" + s.height)
            if (s.bitDepth > 0)
                parts.push(s.bitDepth + "bit")
            if (s.frameRate > 0)
                parts.push(s.frameRate.toFixed(2) + "fps")
            if (s.level > 0)
                parts.push("Lv" + s.level)
            if (s.videoRange)
                parts.push(s.videoRange)
            if (s.pixelFormat)
                parts.push(s.pixelFormat)
            if (s.isInterlaced)
                parts.push("隔行")
            return parts.filter(function (x) { return x !== "" }).join(" · ")
        }
        if (s.type === "Audio") {
            const parts = ["音轨", s.codec ? s.codec.toUpperCase() : ""]
            if (s.channelLayout)
                parts.push(s.channelLayout)
            else if (s.channels > 0)
                parts.push(s.channels + "声道")
            if (s.sampleRate > 0)
                parts.push((s.sampleRate / 1000).toFixed(s.sampleRate % 1000 === 0 ? 0 : 1) + "kHz")
            if (s.bitDepth > 0)
                parts.push(s.bitDepth + "bit")
            if (s.language)
                parts.push(s.language)
            if (s.isDefault)
                parts.push("默认")
            return parts.filter(function (x) { return x !== "" }).join(" · ")
        }
        if (s.type === "Subtitle") {
            const parts = ["字幕", s.codec ? s.codec.toUpperCase() : ""]
            if (s.language)
                parts.push(s.language)
            if (s.isForced)
                parts.push("强制")
            parts.push(s.isExternal ? "外挂" : "内嵌")
            if (s.isDefault)
                parts.push("默认")
            return parts.filter(function (x) { return x !== "" }).join(" · ")
        }
        return s.type
    }

    property bool _ready: false
    onItemIdChanged: {
        // 首次进入由 onCompleted 处理;之后(itemId 原地替换)在此重拉。
        if (root._ready)
            root.reload()
    }
    Component.onCompleted: {
        root._ready = true
        root.reload()
    }

    onVisibleChanged: {
        // StackView pop 回来(visible false→true)时重拉被覆盖的共享模型。
        if (root.visible && root._ready)
            root.resyncModels()
    }


    Rectangle {
        anchors.fill: parent
        color: Theme.bg
        // 莫奈色纵向延伸 + 藏色:顶部氛围色保持到正文起始,中部渐入
        // 带海报色相的底色(bgTint),最底部埋极暗互补色(暗部藏色)。
        gradient: Gradient {
            GradientStop { position: 0.0; color: root.heroFrom }
            GradientStop { position: 0.5; color: root.heroFrom }
            GradientStop { position: 0.8; color: root.bgTint }
            GradientStop { position: 1.0; color: root.complementDark }
        }

        // 全宽 Hero 背景(延伸到选集栏下方):无 backdrop 时纯色纵向渐变。
        Rectangle {
            id: heroBackdrop
            y: 0
            width: parent.width
            height: Constants.detailHeroH
            visible: root.loaded
            z: 0
            gradient: Gradient {
                GradientStop { position: 0.0; color: root.heroFrom }
                GradientStop { position: 1.0; color: root.bgTint }
            }
            // 背景图:圆形扩散溶解换图(Canvas drawImage 走 GPU,大图可承受;
            // 与海报同速,切换时氛围同步换新)。
            CrossfadeImage {
                anchors.fill: parent
                source: root.backdropSource()
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                duration: 800
                cache: true
            }
            // 底部渐变遮罩:保证标题/按钮文字可读,并让选集栏区域自然淡出;
            // 尾色用莫奈色与正文区纵向渐变衔接。
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.55; color: "transparent" }
                    GradientStop { position: 1.0; color: root.heroFrom }
                }
            }
        }
            // 选集栏莫奈色半透明 scrim:叠在全宽 Hero 之上,选集区透出
            // 海报色氛围;低透明度(0.35)更通透,不再是大块深灰。
            Rectangle {
                id: sidebarScrim
                width: Constants.detailSidebarW
                x: parent.width - width
                y: 0
                height: parent.height
                // 仅剧集/集详情(有选集栏)时显示;Movie 全宽正文不盖色带。
                visible: root.loaded && (root.detail.type === "Series" || root.detail.type === "Episode")
                z: 1
                color: Qt.rgba(root.heroFrom.r, root.heroFrom.g, root.heroFrom.b, 0.35)
            }

        // 加载动画:detail 未到(首次进入/切集)时显示,到达后隐藏,
        // 保证首次渲染即完整结构,介绍/演员不逐块出现推动按钮位置。
        Item {
            anchors.fill: parent
            visible: !root.loaded
            Column {
                anchors.centerIn: parent
                spacing: 12
                BusyIndicator {
                    anchors.horizontalCenter: parent.horizontalCenter
                    running: true
                }
                AppText {
                    text: "加载中…"
                    color: Theme.textMuted
                    font.pixelSize: 14
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }

        Row {
            anchors.fill: parent
            visible: root.loaded
            z: 2

            // ---- 左栏:正文(Hero + 演职人员 + 媒体信息 + 相似推荐) ----
            Flickable {
                id: overview
                width: parent.width - (sidebar.visible ? Constants.detailSidebarW : 0)
                height: parent.height
                clip: true
                contentHeight: overviewColumn.implicitHeight
                ScrollBar.vertical: ScrollBar {}

                Column {
                    id: overviewColumn
                    width: parent.width

                    // ================= Hero =================
                    Item {
                        width: parent.width
                        height: Constants.detailHeroH

                        Button {
                            anchors.left: parent.left
                            anchors.leftMargin: 16
                            anchors.top: parent.top
                            anchors.topMargin: 12
                            text: "← 返回"
                            onClicked: root.back()
                        }
                        Button {
                            anchors.right: parent.right
                            anchors.rightMargin: 16
                            anchors.top: parent.top
                            anchors.topMargin: 12
                            text: root.isFavorite ? "♥ 已收藏" : "♡ 收藏"
                            onClicked: root.toggleFavorite()
                        }

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: 32
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 24
                            spacing: 24

                            // 海报(2:3 竖版,独立前景锚点)
                            Rectangle {
                                width: Constants.detailPosterW
                                height: Constants.detailPosterH
                                color: root.surfaceTint
                                radius: 6
                                CrossfadeImage {
                                    id: posterFx
                                    anchors.fill: parent
                                    anchors.margins: 3
                                    source: root.heroPosterSource()
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    duration: 800
                                }
                            }

                            Column {
                                id: heroTextCol
                                width: Math.max(280, overview.width - Constants.detailPosterW - 32 - 24 - 48)
                                spacing: 8
                                // 文字层:切换时随 textFade 淡出淡入(图片溶解不走此层)。
                                opacity: root.textFade
                                // 推入动画位移(不干扰布局)。
                                transform: Translate {
                                    id: heroTitleShift
                                    y: 0
                                }

                                Row {
                                    width: parent.width
                                    spacing: 12

                                    AppText {
                                        text: root.heroTitle()
                                        color: Theme.textPrimary
                                        font.pixelSize: 30
                                        font.bold: true
                                        elide: Text.ElideRight
                                        width: parent.width
                                    }
                                }
                                AppText {
                                    text: root.metaLine()
                                    color: root.detail.rating > 0 ? Theme.rating : Theme.textMuted
                                    font.pixelSize: 14
                                    opacity: text !== "" ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 200 } }
                                }
                                AppText {
                                    text: root.detail.overview || ""
                                    color: Theme.textMuted
                                    font.pixelSize: 13
                                    wrapMode: Text.Wrap
                                    elide: Text.ElideRight
                                    maximumLineCount: root.detail.overview && root.detail.overview.length > 0 ? 2 : 0
                                    width: parent.width
                                    opacity: text !== "" ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 200 } }
                                }
                                Row {
                                    spacing: 10
                                    Button {
                                        text: root.detail.type === "Series" ? root.seriesPlayText() : root.playButtonText()
                                        width: 220
                                        height: 44
                                        font.pixelSize: 16
                                        onClicked: root.detail.type === "Series" ? root.playSeries() : root.startPlayback(true)
                                        background: Rectangle {
                                            radius: 10
                                            // 强调色半透明(75%):透出莫奈背景,不显实色块。
                                            color: Qt.rgba(root.accentColor.r, root.accentColor.g,
                                                          root.accentColor.b, 0.75)
                                            Behavior on color { ColorAnimation { duration: Constants.animMaxMs } }
                                        }
                                        contentItem: AppText {
                                            text: parent.text
                                            color: "white"
                                            font.pixelSize: 16
                                            horizontalAlignment: Text.AlignHCenter
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                    }
                                    Button {
                                        text: "从头播放"
                                        visible: root.detail.type !== "Series" && root.detail.positionTicks > 0 && !root.detail.played
                                        height: 44
                                        onClicked: root.startPlayback(false)
                                        // 辅助色(分裂互补)半透明底:30% 层,与强调按钮拉开层级。
                                        background: Rectangle {
                                            radius: 10
                                            color: Qt.rgba(root.complementColor.r, root.complementColor.g,
                                                          root.complementColor.b, 0.28)
                                            border.width: 1
                                            border.color: root.complementColor
                                        }
                                        contentItem: AppText {
                                            text: parent.text
                                            font.pixelSize: 14
                                            horizontalAlignment: Text.AlignHCenter
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                    }
                                    Button {
                                        text: root.detail.played ? "标记未看" : "标记已看"
                                        visible: root.detail.type !== "Series"
                                        height: 44
                                        onClicked: root.toggleWatched()
                                    }
                                    Button {
                                        text: root.detail.played ? "标记未看" : "标记已看"
                                        visible: root.detail.type === "Series"
                                        height: 44
                                        onClicked: root.toggleWatched()
                                    }
                                }
                            }
                        }
                    }

                    // ================= 演职人员 =================
                    Column {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.min(parent.width - 48, Constants.detailBodyMaxW)
                        spacing: 8
                        visible: !!root.detail.people && root.detail.people.length > 0
                        opacity: root.textFade * (visible ? 1 : 0)
                        Behavior on opacity { NumberAnimation { duration: 200 } }

                        AppText {
                            text: "演职人员"
                            color: Theme.textPrimary
                            font.pixelSize: 18
                            font.bold: true
                        }
                        Flickable {
                            width: parent.width
                            height: 110
                            clip: true
                            contentWidth: peopleRow.implicitWidth
                            Row {
                                id: peopleRow
                                spacing: 16
                                Repeater {
                                    model: root.detail.people
                                    delegate: Item {
                                        width: 72
                                        height: 100
                                        Column {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            spacing: 4
                                            Rectangle {
                                                width: 60
                                                height: 60
                                                radius: 30
                                                clip: true
                                                color: root.surfaceTint
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                CrossfadeImage {
                                                    anchors.fill: parent
                                                    source: modelData.posterId ? "image://emby/" + modelData.posterId : ""
                                                    fillMode: Image.PreserveAspectCrop
                                                    asynchronous: true
                                                    duration: 500
                                                    cache: true
                                                }
                                                AppText {
                                                    anchors.centerIn: parent
                                                    text: modelData.name ? modelData.name.charAt(0) : ""
                                                    color: Theme.textMuted
                                                    font.pixelSize: 20
                                                    visible: !(modelData.posterId)
                                                }
                                            }
                                            AppText {
                                                text: modelData.name || ""
                                                color: Theme.textPrimary
                                                font.pixelSize: 12
                                                elide: Text.ElideRight
                                                width: 72
                                                horizontalAlignment: Text.AlignHCenter
                                            }
                                            AppText {
                                                text: modelData.role || modelData.type || ""
                                                color: Theme.textMuted
                                                font.pixelSize: 11
                                                elide: Text.ElideRight
                                                width: 72
                                                horizontalAlignment: Text.AlignHCenter
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ================= 媒体信息 =================
                    Column {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.min(parent.width - 48, Constants.detailBodyMaxW)
                        spacing: 8
                        visible: !!root.detail.mediaSources && root.detail.mediaSources.length > 0
                        opacity: root.textFade * (visible ? 1 : 0)
                        Behavior on opacity { NumberAnimation { duration: 200 } }

                        AppText {
                            text: "媒体信息"
                            color: Theme.textPrimary
                            font.pixelSize: 18
                            font.bold: true
                        }
                        Repeater {
                            model: root.detail.mediaSources
                            delegate: Column {
                                width: parent.width
                                spacing: 2
                                AppText {
                                    text: (modelData.name || "版本") + " · "
                                            + (modelData.container ? modelData.container.toUpperCase() + " · " : "")
                                            + formatSize(modelData.sizeBytes)
                                            + (modelData.bitrate > 0 ? " · " + formatBitrate(modelData.bitrate) : "")
                                            + (modelData.runTimeTicks > 0 ? " · " + formatTime(modelData.runTimeTicks / Constants.ticksPerSecond) : "")
                                    color: Theme.textPrimary
                                    font.pixelSize: 14
                                }
                                Repeater {
                                    model: modelData.streams
                                    delegate: AppText {
                                        text: streamLabel(modelData)
                                        color: Theme.textMuted
                                        font.pixelSize: 13
                                    }
                                }
                            }
                        }
                    }

                    // ================= 相似推荐 =================
                    Column {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.min(parent.width - 48, Constants.detailBodyMaxW)
                        spacing: 8
                        visible: !root.similarStale && EmbyClient.similarModelFor(root.serverUrl).count > 0
                        opacity: root.textFade * (visible ? 1 : 0)
                        Behavior on opacity { NumberAnimation { duration: 200 } }

                        AppText {
                            text: "相似推荐"
                            color: Theme.textPrimary
                            font.pixelSize: 18
                            font.bold: true
                        }
                        ListView {
                            width: parent.width
                            height: Constants.detailCardH + 40
                            orientation: ListView.Horizontal
                            spacing: 12
                            clip: true
                            model: EmbyClient.similarModelFor(root.serverUrl)
                            delegate: Item {
                                width: Constants.detailCardW
                                height: Constants.detailCardH
                                Rectangle {
                                    width: Constants.detailCardW
                                    height: Constants.detailCardH
                                    color: root.surfaceTint
                                    radius: 6
                                    CrossfadeImage {
                                        anchors.fill: parent
                                        anchors.margins: 3
                                        source: model.posterId ? "image://emby/" + model.posterId : ""
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true
                                        duration: 500
                                        cache: true
                                    }
                                    AppText {
                                        anchors.bottom: parent.bottom
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.margins: 6
                                        text: model.name
                                        color: Theme.textPrimary
                                        font.pixelSize: 12
                                        elide: Text.ElideRight
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: root.openItemDetail(model.id, model.posterId, model.name, root.serverUrl)
                                }
                            }
                        }
                    }

                    // 底部留白
                    Item { width: 1; height: 32 }
                }
            }

            // ---- 右栏:竖向选集条(剧集/集详情) ----
            Column {
                id: sidebar
                width: Constants.detailSidebarW
                height: parent.height
                spacing: 10
                visible: root.detail.type === "Series" || root.detail.type === "Episode"
                opacity: visible ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 220 } }

                // 选季条:显示当前季,悬停时仅数字区变化(候选数字原位放大 +
                // 上下邻季淡入),条本身高度/背景/描边保持固定。
                // 背景用莫奈取色的 surfaceTint 半透明,与选集栏 scrim 同源。
                Rectangle {
                    id: seasonStrip
                    property bool stripHovered: seasonMa.containsMouse
                    width: parent.width
                    height: 96
                    radius: 10
                    color: Qt.rgba(root.surfaceTint.r, root.surfaceTint.g,
                                  root.surfaceTint.b, 0.38)
                    border.width: 1
                    border.color: root.complementColor
                    clip: true

                    // "第"/"季":锚定条顶固定位置(中心 y=48,与数字同线),
                    // hover 不移动。
                    AppText {
                        text: "第"
                        color: Theme.textPrimary
                        font.pixelSize: 14
                        anchors.left: parent.left
                        anchors.leftMargin: 18
                        anchors.top: parent.top
                        anchors.topMargin: 41
                    }
                    // 数字区:行高固定(上 18 + 候选牌 56 + 下 18),每行内容
                    // 垂直居中 → 候选牌原位缩放,不上下移动;上下邻季行
                    // 始终占位,折叠时仅透明(淡入淡出)。
                    Column {
                        id: digitCol
                        anchors.top: parent.top
                        anchors.topMargin: 2
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 62
                        height: 92
                        spacing: 0
                        // 上一季(列表内实际存在的季;无则隐藏)。
                        AppText {
                            id: upText
                            width: 62
                            height: 18
                            verticalAlignment: Text.AlignVCenter
                            text: seasonStrip.stripHovered && root.seasonPrevNo() > 0
                                  ? root.pad2(root.seasonPrevNo()) : ""
                            color: Theme.textMuted
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            opacity: seasonStrip.stripHovered
                                     && root.seasonPrevNo() > 0 ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 160 } }
                        }
                        // 候选季号:两位 Counter Girls 牌(十位/个位),牌原位
                        // 放大(中心不动),牌上的数字随季号切换。
                        Item {
                            width: 62
                            height: 56
                            Row {
                                anchors.centerIn: parent
                                spacing: 2
                                Repeater {
                                    model: 2
                                    AnimatedImage {
                                        readonly property int digit: model.index === 0
                                                                   ? Math.floor(root.seasonCandidate / 10) % 10
                                                                   : root.seasonCandidate % 10
                                        source: "qrc:/counter/" + digit + ".gif"
                                        width: seasonStrip.stripHovered ? 26 : 18
                                        height: seasonStrip.stripHovered ? 56 : 40
                                        smooth: true
                                        Behavior on width { NumberAnimation { duration: 160 } }
                                        Behavior on height { NumberAnimation { duration: 160 } }
                                    }
                                }
                            }
                        }
                        // 下一季(列表内实际存在的季;无则隐藏)。
                        AppText {
                            id: downText
                            width: 62
                            height: 18
                            verticalAlignment: Text.AlignVCenter
                            text: seasonStrip.stripHovered && root.seasonNextNo() > 0
                                  ? root.pad2(root.seasonNextNo()) : ""
                            color: Theme.textMuted
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            opacity: seasonStrip.stripHovered
                                     && root.seasonNextNo() > 0 ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 160 } }
                        }
                    }
                    // "季" 同样固定。
                    AppText {
                        text: "季"
                        color: Theme.textPrimary
                        font.pixelSize: 14
                        anchors.right: parent.right
                        anchors.rightMargin: 18
                        anchors.top: parent.top
                        anchors.topMargin: 41
                    }
                    MouseArea {
                        id: seasonMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: {
                            root.refreshSeasonNos()
                            root.resetSeasonCandidate()
                        }
                        onExited: root.resetSeasonCandidate()
                        onWheel: root.stepCandidate(wheel.angleDelta.y > 0 ? -1 : 1)
                        onClicked: root.confirmSeason()
                    }
                }

                ListView {
                    id: episodeList
                    width: parent.width
                    height: parent.height - seasonStrip.height - sidebar.spacing
                    clip: true
                    focus: true
                    keyNavigationWraps: true
                    model: EmbyClient.episodesModelFor(root.serverUrl)
                    ScrollBar.vertical: ScrollBar {}
                    delegate: Item {
                        width: episodeList.width - 12
                        height: Constants.detailEpisodeRowH
                        x: 6
                        // hover 放大(基础样式)
                        scale: mouse.containsMouse ? Constants.detailEpisodeHoverScale : 1.0
                        Behavior on scale { NumberAnimation { duration: Constants.animMaxMs } }

                        Rectangle {
                            anchors.fill: parent
                            radius: 6
                            color: model.id === root.itemId
                                   ? Qt.rgba(root.accentColor.r, root.accentColor.g,
                                             root.accentColor.b, 0.75)
                                   : (mouse.containsMouse || ListView.isCurrentItem) ? root.surfaceTint
                                   : "transparent"
                            Behavior on color { ColorAnimation { duration: Constants.animMinMs } }
                        }
                        Row {
                            anchors.fill: parent
                            anchors.margins: 6
                            spacing: 10
                            // 左:海报缩略图(16:9 剧照)
                            Rectangle {
                                width: 88
                                height: 50
                                anchors.verticalCenter: parent.verticalCenter
                                color: Theme.bg
                                radius: 4
                                CrossfadeImage {
                                    id: thumb
                                    anchors.fill: parent
                                    source: model.posterId ? "image://emby/" + model.posterId : ""
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    duration: 500
                                    cache: true
                                }
                                // 无海报/加载失败回退:播放图标
                                AppText {
                                    anchors.centerIn: parent
                                    text: "▶"
                                    color: model.id === root.itemId ? "white" : Theme.textMuted
                                    font.pixelSize: 16
                                    visible: !model.posterId || thumb.status === Image.Error
                                }
                            }
                            // 右:集名 + 进度/已看
                            Column {
                                width: parent.width - 88 - 10
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 3
                                AppText {
                                    width: parent.width
                                    text: model.episodeNo > 0 ? "E" + model.episodeNo + " · " + model.name : model.name
                                    color: model.id === root.itemId ? "white" : Theme.textPrimary
                                    font.pixelSize: 14
                                    elide: Text.ElideRight
                                    opacity: root.textFade
                                }
                                // 观看进度条
                                Item {
                                    width: parent.width
                                    height: 3
                                    visible: model.positionTicks > 0 && !model.played && model.runtimeTicks > 0
                                    Rectangle {
                                        anchors.fill: parent
                                        color: model.id === root.itemId ? Qt.rgba(1,1,1,0.4) : root.surfaceTint
                                    }
                                    Rectangle {
                                        width: parent.width * Math.min(1, model.positionTicks / model.runtimeTicks)
                                        height: parent.height
                                        color: model.id === root.itemId ? "white" : root.accentColor
                                        Behavior on color { ColorAnimation { duration: Constants.animMinMs } }
                                    }
                                }
                                AppText {
                                    text: "已看"
                                    color: model.id === root.itemId ? "white" : Theme.success
                                    font.pixelSize: 11
                                    visible: model.played
                                }
                            }
                        }
                        MouseArea {
                            id: mouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                // 选集条点集:原地替换(剧集页与集详情页一致,栈深恒为 1)。
                                root.replaceItem(model.id, model.posterId, model.name)
                            }
                        }
                    }
                }
            }
        }
    }

    Connections {
        target: EmbyClient
        function onItemDetailReady(serverUrl, d) {
            if (serverUrl !== root.serverUrl || d.id !== root.itemId)
                return
            // 原地替换且旧正文在显示:先淡出旧内容,动画中落地数据再淡入;
            // 首次进入(加载动画中)直接落地渲染。
            if (root.replacing && root.loaded) {
                root.pendingDetail = d
                fadeInOut.start()
            } else {
                root.applyDetail(d, false)
            }
        }
    }


    Connections {
        target: EmbyClient
        function onSeasonsReceived(serverUrl) {
            if (serverUrl !== root.serverUrl)
                return
            const model = EmbyClient.seasonsModelFor(root.serverUrl)
            let seasonId = ""
            // 优先保持当前季(重拉/pop 回来不丢失用户选择),其次集详情的季,再第一季。
            if (root.currentSeasonId) {
                for (let i = 0; i < model.count; i++) {
                    if (model.itemAt(i).id === root.currentSeasonId) { seasonId = root.currentSeasonId; break }
                }
            }
            if (!seasonId && root.detail.type === "Episode" && root.detail.seasonId) {
                for (let i = 0; i < model.count; i++) {
                    if (model.itemAt(i).id === root.detail.seasonId) { seasonId = root.detail.seasonId; break }
                }
            }
            if (!seasonId && model.count > 0)
                seasonId = model.itemAt(0).id
            if (seasonId)
                root.selectSeason(seasonId)
            else
                root.loaded = true // 无季/无分集:选集就绪,直接渲染结构
        }
        function onEpisodesReceived(serverUrl) {
            if (serverUrl !== root.serverUrl)
                return
            // 分集到达:剧集/集详情的结构可渲染(detail 文本早已就绪)。
            root.loaded = true
        }
        function onSimilarReady(serverUrl) {
            if (serverUrl !== root.serverUrl)
                return
            // 新条目推荐已填充模型,恢复显示。
            root.similarStale = false
        }
        function onPlaybackReady(serverUrl, url, headers, meta) {
            root.playbackPending = false
            if (serverUrl === root.serverUrl && meta.itemId === root.pendingPlayItemId) {
                const m = Object.assign({}, meta)
                m.resumePositionTicks = root.resumeTicks || 0
                root.playRequested(url, headers, m)
            }
        }
        // 播放协商失败时复位防抖,允许重试。
        function onErrorOccurred(serverUrl, message) {
            if (serverUrl !== root.serverUrl)
                return
            root.playbackPending = false
        }
    }

}

