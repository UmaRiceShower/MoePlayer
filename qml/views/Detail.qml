pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import MoePlayer.Core

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
    // hero 文字块双树揭示动画状态:换字前快照旧文字到旧树(heroOldTree,
    // 右缘固定),新树(heroNewTree,左缘固定)绑当前 detail;textReveal 1→0
    // 一趟:旧树宽度 W→0(从左往右消失)、新树 0→W(从左往右出现),配合
    // old/newOpacity 交叉淡化(旧淡出/新淡入),压住透明文字间隙透出对方的
    // 叠影。稳态 textReveal=0/oldOpacity=0/newOpacity=1(新树全宽全显)。
    property real textReveal: 0
    property real oldTextOpacity: 0
    property real newTextOpacity: 1
    // 旧树内容快照(换字前冻结旧值,动画期间旧树显示旧文字)。
    property string heroOldTitle: ""
    property string heroOldMeta: ""
    property string heroOldOverview: ""

    // 标识本页为详情页(Main 据此防止双击卡片重复 push)。
    readonly property bool isDetailPage: true

    property var detail: ({})
    property bool isFavorite: false
    // 莫奈取色缓存:单次 map 查找供全部颜色属性复用(原 7 个属性各自重复
    // 求值 pid + map 查找)。本页单卡,绑定重算开销可忽略。
    readonly property var _monet: ConfigManager.monetEnabled
                                     ? (ColorProvider.colors[root.detail.posterId || root.posterId] || null)
                                     : null
    // 海报莫奈取色背景顶色(heroBackdrop 渐变起点);取色未完成/失败回退 surface。
    property color heroFrom: root._monet ? root._monet.heroFrom : Theme.surface
    // hero 文字水平对齐:LayoutMirroring 不镜像 Text 内容,文字区靠右时
    // 须显式右对齐(靠文字区起始侧),与靠左时对称。
    readonly property int heroTextAlign: (ConfigManager.detailTextPos === "top-left"
                                          || ConfigManager.detailTextPos === "bottom-left")
                                         ? Text.AlignLeft : Text.AlignRight
    // 莫奈强调色(播放按钮/季胶囊选中/选集行/进度条);取色未完成/失败回退 accent。
    property color accentColor: root._monet ? root._monet.accent : Theme.accent
    // 分裂互补辅助色(次要按钮/描边/焦点,30% 层)与极暗藏色(渐变暗部埋补色)。
    property color complementColor: root._monet ? root._monet.complement : Theme.textMuted
    // 藏白:白色融入一点莫奈取色(强调色色相 20% 混白),供未激活图标
    // (未收藏爱心/未看勾圈),取代纯白与背景更协调。
    property color iconWhite: Qt.rgba(1 + (root.accentColor.r - 1) * 0.2,
                                      1 + (root.accentColor.g - 1) * 0.2,
                                      1 + (root.accentColor.b - 1) * 0.2)
    property color complementDark: root._monet ? root._monet.complementDark : Theme.bg
    // 背景藏色倾向(带海报色相,取代中性灰);surfaceTint 用于卡片底色。
    property color bgTint: root._monet ? root._monet.bgTint : Theme.bg
    property color surfaceTint: root._monet ? root._monet.surfaceTint : Theme.surface
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

    property bool _ready: false











    signal playRequested(string url, var headers, var meta)
    signal backRequested()
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

    // 该服务器凭据(账号缺失返回空 map)。
    function creds() {
        return AccountManager.credsForServer(root.serverUrl)
    }

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
    // 剧集页播放按钮文案:原绑定内每次重绘线性扫描全集(热点),改为
    // 缓存属性,在集数据/详情到达时刷新一次(onItemDetailReady/
    // onEpisodesReceived 见文件尾 Connections)。
    property string seriesPlayCache: ""
    function computeSeriesPlayText() {
        const model = EmbyClient.allEpisodesModelFor(root.serverUrl)
        for (let i = 0; i < model.count; i++) {
            const it = model.itemAt(i)
            if (it.positionTicks > 0 && !it.played)
                return "继续观看" + (it.seasonNo > 0 && it.episodeNo > 0 ? " S" + it.seasonNo + "E" + it.episodeNo : "")
        }
        return "播放"
    }
    function refreshSeriesPlayText() {
        root.seriesPlayCache = root.detail.type === "Series" ? root.computeSeriesPlayText() : ""
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
        // 本地同步已看状态(按钮即时反馈;服务器为准,下次重拉校正)。
        root.detail = Object.assign({}, root.detail, { played: played })
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
    // 落地详情数据(fadeInOut 动画中调用,正文已淡出;fromReplace 仅标记
    // 替换场景,文字揭示动画由 fadeInOut 自身编排)。
    function applyDetail(d, fromReplace) {
        root.detail = d
        root.isFavorite = d.isFavorite
        // 海报莫奈取色(背景渐变顶色);幂等,后台线程执行,完成后淡入。
        // detail.posterId 为权威(带服务器前缀),缺省回退 push 参数。
        // 配置关闭取色时不请求(colors 无该 id,_monet 已回退主题色)。
        if (ConfigManager.monetEnabled)
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

    // 快照旧文字并让旧树就位:旧树全宽全显盖住新树(此刻两者内容一致,
    // 无缝;新树随后被 applyDetail 换新值,但 opacity 已 0,不产生叠影)。
    function snapshotOldText() {
        root.heroOldTitle = root.heroTitle()
        root.heroOldMeta = root.metaLine()
        root.heroOldOverview = root.detail.overview || ""
        root.textReveal = 1
        root.oldTextOpacity = 1
        root.newTextOpacity = 0
    }
    // 动画结束复位:旧树隐藏,新树全宽全显(稳态)。
    function finishTextSwap() {
        root.textReveal = 0
        root.oldTextOpacity = 0
        root.newTextOpacity = 1
    }

    // hero 文字块滑动揭示:换字前快照旧文字 → 落地新值(新树在下层被旧树
    // 盖住)→ 单程动画:旧树右缘固定宽度 W→0(从左往右消失)+ 新树左缘
    // 固定 0→W(从左往右出现),同时交叉淡化(旧淡出/新淡入)。
    // 图片(backdrop/海报/演职/缩略图)不走此层,各自圆形扩散溶解。
    // 其余文字区(按钮行/演职/相似推荐/选集)仍乘 textFade 整体淡入淡出。
    SequentialAnimation {
        id: fadeInOut
        ScriptAction { script: root.snapshotOldText() }
        ScriptAction {
            script: {
                const d = root.pendingDetail
                root.pendingDetail = null
                root.applyDetail(d, true)
            }
        }
        ParallelAnimation {
            NumberAnimation {
                target: root
                property: "textReveal"
                to: 0
                duration: Constants.detailTextRevealMs
                easing.type: Easing.InQuad
            }
            NumberAnimation {
                target: root
                property: "oldTextOpacity"
                to: 0
                duration: Constants.detailTextRevealMs
                easing.type: Easing.InQuad
            }
            NumberAnimation {
                target: root
                property: "newTextOpacity"
                to: 1
                duration: Constants.detailTextRevealMs
                easing.type: Easing.OutCubic
            }
        }
        ScriptAction { script: root.finishTextSwap() }
        onFinished: root.replacing = false
        onStopped: {
            root.replacing = false
            root.finishTextSwap()
        }
    }


    Rectangle {
        anchors.fill: parent
        color: Theme.bg

        // 全宽 Hero 背景(延伸到选集栏下方):无 backdrop 时纯色纵向渐变。
        // 高度 = hero 内容区(400)+ 延伸 160,背景图"漏出"到正文起始区,
        // 底部经渐变遮罩(透明→bgTint)融入正文底色,自然沉入页面而非硬切。
        Rectangle {
            id: heroBackdrop
            y: 0
            width: parent.width
            height: Constants.detailBackdropH
            visible: root.loaded
            z: 0
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
            // 氛围色叠加层(Multiply 近似):顶部海报色相低透明染色,向下渐淡,
            // 背景图主导视觉;不遮挡图片细节。
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.rgba(root.heroFrom.r, root.heroFrom.g, root.heroFrom.b, 0.30) }
                    GradientStop { position: 0.35; color: Qt.rgba(root.heroFrom.r, root.heroFrom.g, root.heroFrom.b, 0.08) }
                    GradientStop { position: 0.65; color: "transparent" }
                }
            }
            // 底部渐隐遮罩(官方 Gradient 标准做法):透明→bgTint 盖色渐入,
            // 背景图在延伸区被涂成接近正文底色,自然沉入页面;同时压暗
            // hero 底部保证标题/按钮文字可读。不引入 shader 离屏采样。
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.55; color: "transparent" }
                    GradientStop { position: 1.0; color: root.bgTint }
                }
            }
        }
        // 侧栏莫奈氛围由侧栏自身渐变承载(见侧栏容器),不再叠 scrim
        // (叠加使颜色浑浊)。

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
            // 选季栏左/右:只镜像本 positioner 的子项顺序(官方 RTL 机制,
            // 不 childrenInherit,overview/sidebar 内部布局不受影响)。
            LayoutMirroring.enabled: ConfigManager.detailSidebarLeft

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
                        id: heroItem
                        width: parent.width
                        height: Constants.detailHeroH
                        // ===== 定位代理(slot):全部位置判断收敛于三个槽,
                        // 内容控件(海报/文字/按钮)静态锚定到槽,不再各自
                        // 计算坐标。新增配置维度时只改对应槽。=====

                        // 海报槽:posterLeft 决定左右,垂直沉底。
                        Item {
                            id: posterSlot
                            x: ConfigManager.detailPosterLeft ? 32 : parent.width - Constants.detailPosterW - 32
                            y: parent.height - Constants.detailPosterH - 24
                            width: Constants.detailPosterW
                            height: Constants.detailPosterH
                        }
                        // 文字槽:textPos 四角预设。
                        // 水平:与海报同侧 → 海报内侧;异侧 → 贴对侧边缘。
                        // 垂直:top → 返回按钮下方;bottom → follow poster 且
                        // 与海报同侧时避让按钮(贴其上方),否则沉底与海报
                        // 下缘对齐(异侧文字与按钮 x 错开,无需考虑按钮高)。
                        Item {
                            id: textSlot
                            width: ConfigManager.detailTextWidth
                            height: ConfigManager.detailTextHeight
                            readonly property bool _left: ConfigManager.detailTextPos === "top-left"
                                                          || ConfigManager.detailTextPos === "bottom-left"
                            readonly property bool _top: ConfigManager.detailTextPos === "top-left"
                                                         || ConfigManager.detailTextPos === "top-right"
                            x: _left
                                ? (ConfigManager.detailPosterLeft ? 32 + Constants.detailPosterW + 24 : 32)
                                : (parent.width - width
                                   - (ConfigManager.detailPosterLeft ? 32 : 32 + Constants.detailPosterW + 24))
                            y: _top
                                ? 64
                                : ((ConfigManager.detailButtonsFollow === "poster"
                                    && ConfigManager.detailPosterLeft === _left)
                                       ? Math.max(24, parent.height - 44 - 24 - height - 16)
                                       : Math.max(24, parent.height - height - 24))
                        }
                        // 按钮槽:follow poster → 海报内侧(左右对称锚距 256,
                        // 位置用按钮组实际宽回推);follow text → 标题文字外侧
                        // (标题文字宽 = heroNewTitle.implicitWidth,非文字区
                        // 边缘)。垂直:follow poster → 沉底;follow text → 与
                        // 标题同高(文字区 y + 内容偏移 heroNewCol.y)。
                        Item {
                            id: buttonSlot
                            readonly property bool _leftSide: ConfigManager.detailButtonsFollow === "poster"
                                ? ConfigManager.detailPosterLeft : textSlot._left
                            readonly property real _ref: ConfigManager.detailButtonsFollow === "poster"
                                ? 32 + Constants.detailPosterW + 24
                                : (textSlot._left
                                       ? textSlot.x + heroNewTitle.implicitWidth + 24
                                       : parent.width - (textSlot.x + textSlot.width - heroNewTitle.implicitWidth - 24))
                            // 播放键弹性宽:锚距内放不下时压缩(海报右+follow
                            // poster 时锚距 256 → 播放键 170,收藏/已看完整
                            // 可见;下限 120 保可点区域)。左/右锚统一公式,
                            // 不依赖按钮实际宽(避免绑定循环)。
                            readonly property real _playW: Math.min(220, Math.max(120,
                                parent.width - _ref - 16 - 44 - 44 - 20))
                            x: _leftSide ? _ref : parent.width - _ref - btnRow.width
                            y: ConfigManager.detailButtonsFollow === "poster"
                                ? parent.height - 44 - 24
                                : textSlot.y + heroNewCol.y
                        }

                        Button {
                            anchors.left: parent.left
                            anchors.leftMargin: 16
                            anchors.top: parent.top
                            anchors.topMargin: 12
                            text: "← 返回"
                            onClicked: root.back()
                        }

                            // 海报(2:3 竖版):静态锚定海报槽(位置由 posterSlot
                            // 决定,内容不再计算坐标)。
                            Rectangle {
                                width: Constants.detailPosterW
                                height: Constants.detailPosterH
                                color: root.surfaceTint
                                radius: 18
                                clip: true
                                anchors.fill: posterSlot
                                CrossfadeImage {
                                    id: posterFx
                                    anchors.fill: parent
                                    // 圆角在绘制层裁切(Item::clip 只裁矩形)。
                                    cornerRadius: 18
                                    source: root.heroPosterSource()
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    duration: 800
                                }
                            }

                            // hero 文字块:双树滑动揭示(结构不变)。宽高与位置
                            // 全部由 textSlot 决定(静态锚定,判断在槽内)。
                            Item {
                                id: heroTextArea
                                anchors.fill: textSlot

                                Item {
                                    id: heroOldTree
                                    anchors.right: heroTextArea.right
                                    width: heroTextArea.width * root.textReveal
                                    // Item 的 implicitHeight 默认 0(不随子项传播),
                                    // 显式取列高,否则 clip 后文字被裁没。
                                    height: heroTextArea.height
                                    clip: true
                                    opacity: root.oldTextOpacity
                                    visible: root.oldTextOpacity > 0
                                    Column {
                                        id: heroOldCol
                                        // 右缘贴容器右缘:容器右缘固定、宽度收缩时
                                        // 列原点恒 0,裁剪落在列右半(左先消失)。
                                        anchors.right: heroOldTree.right
                                        width: heroTextArea.width
                                        // 内容垂直:top 预设顶部对齐;bottom 预设
                                        // 沉底——用户看的是简介文字底缘而非容器下缘,
                                        // 沉底后简介底缘 = 容器底 = 海报下缘。
                                        y: (ConfigManager.detailTextPos === "top-left"
                                            || ConfigManager.detailTextPos === "top-right")
                                            ? 0 : parent.height - implicitHeight
                                        spacing: 8
                                        Row {
                                            width: parent.width
                                            spacing: 12
                                            AppText {
                                                text: root.heroOldTitle
                                                color: Theme.textPrimary
                                                font.pixelSize: 30
                                                font.bold: true
                                                elide: Text.ElideRight
                                                width: parent.width
                                                horizontalAlignment: root.heroTextAlign
                                            }
                                        }
                                        AppText {
                                            text: root.heroOldMeta
                                            color: root.detail.rating > 0 ? Theme.rating : Theme.textMuted
                                            font.pixelSize: 14
                                            // 显式宽 + 对齐跟随:文字区靠右时评分/
                                            // 时间行右对齐(隐式宽下对齐无效)。
                                            width: parent.width
                                            horizontalAlignment: root.heroTextAlign
                                            opacity: text !== "" ? 1 : 0
                                            Behavior on opacity { NumberAnimation { duration: 200 } }
                                        }
                                        AppText {
                                            text: root.heroOldOverview
                                            color: Theme.textMuted
                                            font.pixelSize: 13
                                            wrapMode: Text.Wrap
                                            elide: Text.ElideRight
                                            maximumLineCount: 2
                                            width: parent.width
                                            horizontalAlignment: root.heroTextAlign
                                            opacity: text !== "" ? 1 : 0
                                            Behavior on opacity { NumberAnimation { duration: 200 } }
                                        }
                                    }
                                }
                                Item {
                                    id: heroNewTree
                                    anchors.left: heroTextArea.left
                                    width: heroTextArea.width * (1 - root.textReveal)
                                    height: heroTextArea.height
                                    clip: true
                                    opacity: root.newTextOpacity
                                    Column {
                                        id: heroNewCol
                                        width: heroTextArea.width
                                        // 内容垂直:top 顶部对齐;bottom 沉底(简介
                                        // 文字底缘 = 海报下缘,同 heroOldCol)。
                                        y: (ConfigManager.detailTextPos === "top-left"
                                            || ConfigManager.detailTextPos === "top-right")
                                            ? 0 : parent.height - implicitHeight
                                        spacing: 8
                                        Row {
                                            width: parent.width
                                            spacing: 12
                                            AppText {
                                                id: heroNewTitle
                                                text: root.heroTitle()
                                                color: Theme.textPrimary
                                                font.pixelSize: 30
                                                font.bold: true
                                                elide: Text.ElideRight
                                                width: parent.width
                                                horizontalAlignment: root.heroTextAlign
                                            }
                                        }
                                        AppText {
                                            text: root.metaLine()
                                            color: root.detail.rating > 0 ? Theme.rating : Theme.textMuted
                                            font.pixelSize: 14
                                            width: parent.width
                                            horizontalAlignment: root.heroTextAlign
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
                                            horizontalAlignment: root.heroTextAlign
                                            opacity: text !== "" ? 1 : 0
                                            Behavior on opacity { NumberAnimation { duration: 200 } }
                                        }
                                    }
                                }
                            }
                            // 按钮行(播放/收藏/已看)作为整体独立锚定,
                            // 水平锚由 btnLeft/btnMargin 驱动(见 root 属性)。

                        Row {
                            id: btnRow
                            // 按钮行:位置由 buttonSlot 决定(跟随海报内侧或
                            // 标题文字外侧;垂直沉底或标题同高)。
                            // 顺序:按钮组右缘锚定参考点(在参考左侧)时反转
                            // 为 [已看][收藏][播放],主播放键仍贴参考;左缘
                            // 锚定时保持 [播放][收藏][已看]。官方 Row
                            // LayoutMirroring(不 childrenInherit,仅反转子项,
                            // 按钮内容不镜像)。
                            LayoutMirroring.enabled: !buttonSlot._leftSide
                            spacing: 10
                            opacity: root.textFade
                            x: buttonSlot.x
                            y: buttonSlot.y
                            Button {
                                id: playBtn
                                text: root.detail.type === "Series" ? root.seriesPlayCache : root.playButtonText()
                                // 弹性宽由 buttonSlot._playW 决定(锚距内放不
                                // 下时压缩,下限 120 保可点区域)。
                                width: buttonSlot._playW
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
                                    text: playBtn.text
                                    color: "white"
                                    font.pixelSize: 16
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                            }
                            // 收藏:爱心图标。未收藏藏白实心,已收藏红(粉)实心。
                            Button {
                                width: 44
                                height: 44
                                onClicked: root.toggleFavorite()
                                background: Rectangle {
                                    radius: 10
                                    color: Qt.rgba(root.complementColor.r, root.complementColor.g,
                                                  root.complementColor.b, 0.28)
                                    border.width: 1
                                    border.color: root.complementColor
                                }
                                contentItem: AppText {
                                    text: "♥"
                                    color: root.isFavorite ? Theme.favorite : root.iconWhite
                                    font.pixelSize: 24
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                    Behavior on color { ColorAnimation { duration: Constants.animMinMs } }
                                }
                            }
                            // 已看/未看:圆圈 + 勾。已看绿色,未看藏白。
                            Button {
                                width: 44
                                height: 44
                                onClicked: root.toggleWatched()
                                background: Rectangle {
                                    radius: 10
                                    color: Qt.rgba(root.complementColor.r, root.complementColor.g,
                                                  root.complementColor.b, 0.28)
                                    border.width: 1
                                    border.color: root.complementColor
                                }
                                contentItem: Item {
                                    // 圈:声明式边框,随已看状态变色。
                                    Rectangle {
                                        anchors.fill: parent
                                        anchors.margins: 8
                                        radius: width / 2
                                        color: "transparent"
                                        border.width: 2.5
                                        border.color: root.detail.played ? Theme.success : root.iconWhite
                                    }
                                    // 勾:字符叠加在圈上(与爱心同机制,渲染可靠)。
                                    AppText {
                                        text: "✓"
                                        color: root.detail.played ? Theme.success : root.iconWhite
                                        font.pixelSize: 13
                                        font.bold: true
                                        anchors.centerIn: parent
                                    }
                                }
                            }
                            Button {
                                id: replayBtn
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
                                    text: replayBtn.text
                                    font.pixelSize: 14
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                            }
                        }                    }

                    // ================= 演职人员 =================
                    Column {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.min(parent.width - 48, Constants.detailBodyMaxW)
                        spacing: 8
                        visible: !!root.detail.people && root.detail.people.length > 0
                        opacity: root.textFade * visible
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
                                        id: peopleCard
                                        // Repeater 注入的元素;显式 required 声明让 qmllint
                                        // 静态识别 modelData(否则复杂文件内注入失效报 unqualified)。
                                        required property var modelData
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
                                                    // 60x60 卡:半径=短边一半,呈圆形。
                                                    cornerRadius: 30
                                                    source: peopleCard.modelData.posterId ? "image://emby/" + peopleCard.modelData.posterId : ""
                                                    fillMode: Image.PreserveAspectCrop
                                                    asynchronous: true
                                                    duration: 500
                                                    cache: true
                                                }
                                                AppText {
                                                    anchors.centerIn: parent
                                                    text: peopleCard.modelData.name ? peopleCard.modelData.name.charAt(0) : ""
                                                    color: Theme.textMuted
                                                    font.pixelSize: 20
                                                    visible: !(peopleCard.modelData.posterId)
                                                }
                                            }
                                            AppText {
                                                text: peopleCard.modelData.name || ""
                                                color: Theme.textPrimary
                                                font.pixelSize: 12
                                                elide: Text.ElideRight
                                                width: 72
                                                horizontalAlignment: Text.AlignHCenter
                                            }
                                            AppText {
                                                text: peopleCard.modelData.role || peopleCard.modelData.type || ""
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
                        opacity: root.textFade * visible
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
                                id: mediaSourceItem
                                // 同 people delegate:required 声明让 qmllint 识别 modelData。
                                required property var modelData
                                width: parent.width
                                spacing: 2
                                AppText {
                                    text: (mediaSourceItem.modelData.name || "版本") + " · "
                                            + (mediaSourceItem.modelData.container ? mediaSourceItem.modelData.container.toUpperCase() + " · " : "")
                                            + root.formatSize(mediaSourceItem.modelData.sizeBytes)
                                            + (mediaSourceItem.modelData.bitrate > 0 ? " · " + root.formatBitrate(mediaSourceItem.modelData.bitrate) : "")
                                            + (mediaSourceItem.modelData.runTimeTicks > 0 ? " · " + root.formatTime(mediaSourceItem.modelData.runTimeTicks / Constants.ticksPerSecond) : "")
                                    color: Theme.textPrimary
                                    font.pixelSize: 14
                                }
                                Repeater {
                                    model: mediaSourceItem.modelData.streams
                                    delegate: AppText {
                                        required property var modelData
                                        text: root.streamLabel(modelData)
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
                        opacity: root.textFade * visible
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
                                id: similarCard
                                // 同上:required 声明让 qmllint 识别 C++ 模型的 model 角色访问。
                                required property var model
                                width: Constants.detailCardW
                                height: Constants.detailCardH
                                Rectangle {
                                    width: Constants.detailCardW
                                    height: Constants.detailCardH
                                    color: root.surfaceTint
                                    radius: 14
                                    clip: true
                                    CrossfadeImage {
                                        anchors.fill: parent
                                        // 不内缩(同 PosterCard):内缩露出深色卡片底,观感黑框。
                                        cornerRadius: 14
                                        source: similarCard.model.posterId ? "image://emby/" + similarCard.model.posterId : ""
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
                                        text: similarCard.model.name
                                        color: Theme.textPrimary
                                        font.pixelSize: 12
                                        elide: Text.ElideRight
                                    }
                                }
                                // 点击进详情:TapHandler(替代 MouseArea)。
                                TapHandler {
                                    onTapped: root.openItemDetail(similarCard.model.id, similarCard.model.posterId,
                                                                  similarCard.model.name, root.serverUrl)
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
                                        required property int index
                                        readonly property int digit: index === 0
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
                        id: episodeItem
                        // 同上:required 声明识别 C++ 模型角色。
                        required property var model
                        width: episodeList.width - 12
                        height: Constants.detailEpisodeRowH
                        x: 6
                        // hover 放大(基础样式)
                        scale: episodeHover.hovered ? Constants.detailEpisodeHoverScale : 1.0
                        Behavior on scale { NumberAnimation { duration: Constants.animMaxMs } }

                        Rectangle {
                            anchors.fill: parent
                            radius: 6
                            color: episodeItem.model.id === root.itemId
                                   ? Qt.rgba(root.accentColor.r, root.accentColor.g,
                                             root.accentColor.b, 0.75)
                                   : (episodeHover.hovered || ListView.isCurrentItem) ? root.surfaceTint
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
                                radius: 12
                                clip: true
                                CrossfadeImage {
                                    id: thumb
                                    anchors.fill: parent
                                    cornerRadius: 12
                                    source: episodeItem.model.posterId ? "image://emby/" + episodeItem.model.posterId : ""
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    duration: 500
                                    cache: true
                                }
                                // 无海报/加载失败回退:播放图标
                                AppText {
                                    anchors.centerIn: parent
                                    text: "▶"
                                    color: episodeItem.model.id === root.itemId ? "white" : Theme.textMuted
                                    font.pixelSize: 16
                                    visible: !episodeItem.model.posterId || thumb.status === Image.Error
                                }
                            }
                            // 右:集名 + 进度/已看
                            Column {
                                width: parent.width - 88 - 10
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 3
                                AppText {
                                    width: parent.width
                                    text: episodeItem.model.episodeNo > 0 ? "E" + episodeItem.model.episodeNo + " · " + episodeItem.model.name : episodeItem.model.name
                                    color: episodeItem.model.id === root.itemId ? "white" : Theme.textPrimary
                                    font.pixelSize: 14
                                    elide: Text.ElideRight
                                    opacity: root.textFade
                                }
                                // 观看进度条
                                Item {
                                    width: parent.width
                                    height: 3
                                    visible: episodeItem.model.positionTicks > 0 && !episodeItem.model.played && episodeItem.model.runtimeTicks > 0
                                    Rectangle {
                                        anchors.fill: parent
                                        color: episodeItem.model.id === root.itemId ? Qt.rgba(1,1,1,0.4) : root.surfaceTint
                                    }
                                    Rectangle {
                                        width: parent.width * Math.min(1, episodeItem.model.positionTicks / episodeItem.model.runtimeTicks)
                                        height: parent.height
                                        color: episodeItem.model.id === root.itemId ? "white" : root.accentColor
                                        Behavior on color { ColorAnimation { duration: Constants.animMinMs } }
                                    }
                                }
                                AppText {
                                    text: "已看"
                                    color: episodeItem.model.id === root.itemId ? "white" : Theme.success
                                    font.pixelSize: 11
                                    visible: episodeItem.model.played
                                }
                            }
                        }
                        // 悬停高亮/点击选集:Pointer Handler 组合(替代
                        // MouseArea hover+click)。
                        HoverHandler {
                            id: episodeHover
                        }
                        TapHandler {
                            onTapped: {
                                // 选集条点集:原地替换(剧集页与集详情页一致,栈深恒为 1)。
                                root.replaceItem(episodeItem.model.id, episodeItem.model.posterId, episodeItem.model.name)
                            }
                        }
                    }
                }
            }
        }
        // 莫奈色纵向延伸:顶部氛围色保持到 35%,中部平滑渐入带海报色相的
        // 极暗底色(bgTint),底部与正文底色衔接;不引入互补藏色(异色相在
        // 暗底上显脏)。
        gradient: Gradient {
            GradientStop { position: 0.0; color: root.heroFrom }
            GradientStop { position: 0.35; color: root.heroFrom }
            GradientStop { position: 0.70; color: root.bgTint }
            GradientStop { position: 1.0; color: root.bgTint }
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
            root.refreshSeriesPlayText()
        }
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
            root.refreshSeriesPlayText()
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

