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
    // 条目所在服务器:请求路由用;凭据用 accountId 精确定位(多账号不串)。
    property string serverUrl: ""
    // 浏览用账号 id(主窗口导航时注入)。
    property string accountId: ""

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
    // 当前替换是否同剧换集(保留正文/选集滚动;换其它条目复位)。
    property bool replaceKeepScroll: false
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
    property string heroOldEpisode: ""

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
    readonly property int heroTextAlign: root.textSide() === "right" ? Text.AlignRight
                                         : root.textSide() === "center" ? Text.AlignHCenter
                                         : Text.AlignLeft
    // 海报水平侧(left/center/right):posterPos 字符串推导。
    function posterSide() {
        const p = ConfigManager.detailPosterPos
        if (p.endsWith("-right")) return "right"
        if (p.endsWith("-center")) return "center"
        return "left"
    }
    // 文字区水平侧:followPoster → 取海报侧;否则取 textPos 侧。
    function textSide() {
        const t = ConfigManager.detailTextPos
        if (t === "followPoster") return root.posterSide()
        if (t.endsWith("-right")) return "right"
        if (t.endsWith("-center")) return "center"
        return "left"
    }
    // 文字区垂直预设:top/middle/bottom(揭示列内容锚位;followPoster 沉底)。
    function textSlotVertical() {
        const t = ConfigManager.detailTextPos
        if (t === "followPoster" || t.startsWith("bottom-")) return "bottom"
        if (t.startsWith("top-")) return "top"
        return "middle"
    }
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
    // ---- 播放选项(版本/音频/字幕,Q2=B:持久选择,非一次性指令)。----
    // 默认跟随服务器默认轨;切换版本时音轨/字幕按新源默认轨重设。
    // 字幕 -2 = 显式关闭;-1 = 未选(用服务器默认)。
    property string selMediaSourceId: ""
    property int selAudioIndex: -1
    property int selSubtitleIndex: -1
    // 摘要行当前展开段:""/"version"/"audio"/"subtitle"(三段互斥,开新收旧)。
    property string expandedSection: ""
    property bool _ready: false
    signal playWindowRequested(var meta)
    signal playbackDelivered(string url, var headers, var meta)
    signal playbackFailed(string itemId, string message)
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

    // 该服务器凭据:按账号 id 精确定位(多账号不串)。
    function creds() {
        return AccountManager.credsForAccount(root.accountId)
    }

    function playItem(itemId, resume) {
        if (root.playbackPending || !itemId)
            return
        console.info("Detail: 播放发起", itemId, resume > 0 ? "续播" : "从头")
        root.playbackPending = true
        root.pendingPlayItemId = itemId
        root.resumeTicks = resume
        // 先开窗(加载态),播放地址后台协商,避免网络延迟期间无反馈。
        const isSeries = root.detail.type === "Series"
        const seriesId = isSeries ? root.detail.id : (root.detail.seriesId || "")
        const seriesName = isSeries ? root.detail.name : (root.detail.seriesName || "")
        root.playWindowRequested({
            serverUrl: root.serverUrl,
            itemId: itemId,
            displayName: root.heroFullTitle(),
            seriesId: seriesId,
            seriesName: seriesName
        })
        const c = root.creds()
        // 携带播放选项:版本 + 音轨/字幕轨 index。后端仅 >=0 写入请求体锁轨
        // (转码路径);-1 未选/-2 显式关均不落请求,由后端按所选轨解析进 meta,
        // mpv 起播后据 track-list 匹配选轨(-2 → sid no)。
        EmbyClient.fetchPlaybackInfo(root.serverUrl, c.token, c.userId, itemId,
                                     root.selMediaSourceId, seriesId,
                                     root.selAudioIndex,
                                     root.selSubtitleIndex)
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
        if (!target) {
            console.info("Detail: 无可用剧集(模型空或全已看)")
            return
        }
        console.debug("Detail: 剧集续播定位", target.id)
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
    function replaceItem(newItemId, newPosterId, newTitle, keepScroll) {
        root.itemId = newItemId
        root.posterId = newPosterId
        root.title = newTitle
        // 重置条目相关状态:季与收藏(新 detail 到达前不显示旧条目状态)、
        // 候选季、相似推荐(stale 隐藏旧推荐)。
        root.currentSeasonId = ""
        root.isFavorite = false
        root.seasonNos = []
        root.seasonCandidate = 1
        root.similarStale = true
        root.replacing = true
        root.replaceKeepScroll = !!keepScroll
        // 同剧换集保留滚动位置(内容原地连续);换其它条目/返回回顶。
        if (!keepScroll)
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
        root.resetPlaybackSelection()
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
    // 选集条选季:拉该季分集;明确换季才回顶(见 resetScroll)。
    function selectSeason(seasonId, resetScroll) {
        root.currentSeasonId = seasonId
        // 候选季号跟随实际选中季:进入详情/切季/确认季都经此,
        // 否则初始显示停留在 resetDetail 的默认 1,仅 hover 才纠正。
        root.seasonCandidate = root.currentSeasonNo()
        const seriesId = root.detail.type === "Series" ? root.detail.id : root.detail.seriesId
        if (seriesId && seasonId) {
            const c = root.creds()
            EmbyClient.fetchEpisodes(root.serverUrl, c.token, c.userId, seriesId, seasonId)
        }
        // 明确换季才回顶(列表从头展示);原地换集触发的重拉链保留位置。
        if (resetScroll)
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
            root.selectSeason(bestId, true)
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
    // 主标题:集时只显示剧名(集名+S*E* 另起副标题),季/剧/电影显示原名。
    function heroTitle() {
        if (root.detail.type === "Episode")
            return root.detail.seriesName || root.title
        return root.detail.name || root.title
    }
    // 集副标题:S*E* + 集名,比主标题小一号;非集返回空。
    function heroEpisodeLine() {
        if (root.detail.type !== "Episode")
            return ""
        let t = ""
        if (root.detail.seasonNo > 0 && root.detail.episodeNo > 0)
            t += "S" + root.detail.seasonNo + "E" + root.detail.episodeNo
        if (root.detail.name) {
            if (t) t += " · "
            t += root.detail.name
        }
        return t
    }
    // 播放用完整标题(单行):剧名 · S*E* · 集名。
    function heroFullTitle() {
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
    // ---- 播放选项辅助:版本/音频/字幕的当前源、默认轨、标签。----
    // 当前选中的版本对象(默认第一个,与后端"显式>第一个"一致)。
    function selVersion() {
        const ms = root.detail.mediaSources || []
        if (ms.length === 0)
            return null
        for (let i = 0; i < ms.length; ++i) {
            if (ms[i].id === root.selMediaSourceId)
                return ms[i]
        }
        return ms[0]
    }
    // 当前源内按类型筛流(kind 归一:Video/Audio/Subtitle/Attachment)。
    function streamsOfKind(kind) {
        const v = root.selVersion()
        const out = []
        if (!v)
            return out
        const ss = v.streams || []
        for (let i = 0; i < ss.length; ++i) {
            if (root.streamKind(ss[i]) === kind)
                out.push(ss[i])
        }
        return out
    }
    // 默认轨 index:优先版本级 defaultXxxStreamIndex,否则 IsDefault 标记。
    function defaultTrackIndex(kind, versionLevel) {
        const ss = root.streamsOfKind(kind)
        if (versionLevel >= 0) {
            for (let i = 0; i < ss.length; ++i) {
                if (ss[i].index === versionLevel)
                    return ss[i].index
            }
        }
        for (let i = 0; i < ss.length; ++i) {
            if (ss[i].isDefault)
                return ss[i].index
        }
        return ss.length > 0 ? ss[0].index : -1
    }
    // 重置为服务器默认轨(详情落地/换版本时调用)。
    function resetPlaybackSelection() {
        const v = root.selVersion()
        root.selMediaSourceId = v ? v.id : ""
        // 有轨选服务器默认轨(具体轨);无轨回「默认」(-1,仅此时显示"默认")。
        root.selAudioIndex = root.defaultTrackIndex("Audio", v ? (v.defaultAudioStreamIndex ?? -1) : -1)
        root.selSubtitleIndex = root.defaultTrackIndex("Subtitle", v ? (v.defaultSubtitleStreamIndex ?? -1) : -1)
    }
    // 切换版本:重设该源默认轨。
    function selectVersion(id) {
        root.selMediaSourceId = id
        const v = root.selVersion()
        root.selAudioIndex = root.defaultTrackIndex("Audio", v ? (v.defaultAudioStreamIndex ?? -1) : -1)
        root.selSubtitleIndex = root.defaultTrackIndex("Subtitle", v ? (v.defaultSubtitleStreamIndex ?? -1) : -1)
    }
    // 音轨标签:显示名 + 语言/声道。
    function audioLabel(s) {
        let t = s.displayTitle || s.title || root.codecLabel(s.codec)
        return t
    }
    // 字幕标签:显示名 + 位置(内封/外挂)。
    function subtitleLabel(s) {
        let t = s.displayTitle || s.title || root.codecLabel(s.codec)
        const loc = root.subtitleLocationLabel(s)
        return loc ? t + " · " + loc : t
    }
    // 音轨选项(常显):前置 关闭音轨(-2);有轨接各实际轨,无轨补「默认」(-1)。
    function audioOptions() {
        const out = [{ index: -2, "_off": true }]
        const ss = root.streamsOfKind("Audio")
        for (let i = 0; i < ss.length; ++i)
            out.push(ss[i])
        if (ss.length === 0)
            out.push({ index: -1, "_def": true })
        return out
    }
    // 字幕选项(常显):前置 关闭字幕(-2);有轨接各实际轨,无轨补「默认」(-1)。
    function subtitleOptionsFull() {
        const out = [{ index: -2, "_off": true }]
        const ss = root.streamsOfKind("Subtitle")
        for (let i = 0; i < ss.length; ++i)
            out.push(ss[i])
        if (ss.length === 0)
            out.push({ index: -1, "_def": true })
        return out
    }
    // 选项行标签:sentinel(-2 关/-1 默认)或实际轨标签。
    function trackOptionLabel(kind, e) {
        if (e._off)
            return kind === "Audio" ? "关闭音轨" : "关闭字幕"
        if (e._def)
            return "默认"
        return kind === "Audio" ? root.audioLabel(e) : root.subtitleLabel(e)
    }
    // 版本摘要副行:容器/大小/分辨率。
    function versionSubLabel(v) {
        if (!v)
            return ""
        let res = ""
        const ss = v.streams || []
        for (let i = 0; i < ss.length; ++i) {
            if (root.streamKind(ss[i]) === "Video" && ss[i].height > 0) {
                res = ss[i].height >= 2160 ? "4K" : ss[i].height + "p"
                break
            }
        }
        return [v.container ? v.container.toUpperCase() : "",
                v.sizeBytes > 0 ? root.formatSize(v.sizeBytes) : "",
                res].filter(function (s) { return s !== "" }).join(" · ")
    }
    // 当前选中摘要(三段行首行文字)。
    function currentVersionLabel() {
        const v = root.selVersion()
        return v ? (v.name || "版本") : ""
    }
    function currentAudioLabel() {
        if (root.selAudioIndex === -2)
            return "关闭音轨"
        if (root.selAudioIndex === -1)
            return "默认"
        const ss = root.streamsOfKind("Audio")
        for (let i = 0; i < ss.length; ++i) {
            if (ss[i].index === root.selAudioIndex)
                return root.audioLabel(ss[i])
        }
        return "默认"
    }
    function currentSubtitleLabel() {
        if (root.selSubtitleIndex === -2)
            return "关闭字幕"
        if (root.selSubtitleIndex === -1)
            return "默认"
        const ss = root.streamsOfKind("Subtitle")
        for (let i = 0; i < ss.length; ++i) {
            if (ss[i].index === root.selSubtitleIndex)
                return root.subtitleLabel(ss[i])
        }
        return "默认"
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
        if (mb >= 1)
            return mb.toFixed(0) + " MB"
        return Math.max(1, Math.round(bytes / 1024)) + " KB"
    }
    function formatBitrate(bps) {
        if (!bps || bps <= 0)
            return ""
        const mbps = bps / 1000000
        if (mbps >= 1)
            return mbps.toFixed(1) + " Mbps"
        return (bps / 1000).toFixed(0) + " kbps"
    }
    // 流归类:优先按 Type;Type 缺失/生僻时按 codec 推断;都不认识回退
    // 原始 Type(调用方对未知 Type 出通用卡,cap 原样显示)。
    function streamKind(s) {
        const t = s.type || ""
        if (t === "Video" || t === "Audio" || t === "Subtitle" || t === "Attachment")
            return t
        const c = String(s.codec || "").toLowerCase()
        if (["h264", "avc", "hevc", "h265", "av1", "vp8", "vp9", "mpeg2video", "mpeg4",
             "vc1", "wmv3", "prores", "theora", "mjpeg", "avs", "avs2"].indexOf(c) >= 0)
            return "Video"
        if (["aac", "ac3", "eac3", "dts", "dca", "truehd", "dtshd", "flac", "mp3", "mp2",
             "opus", "vorbis", "alac", "pcm_s16le", "pcm_s24le", "pcm_s32le", "wma",
             "wavpack", "ape", "mlp"].indexOf(c) >= 0)
            return "Audio"
        if (["subrip", "srt", "ass", "ssa", "pgs", "pgssub", "dvd_subtitle", "dvbsub",
             "mov_text", "webvtt", "sub", "xsub"].indexOf(c) >= 0)
            return "Subtitle"
        if (["ttf", "otf", "woff", "woff2"].indexOf(c) >= 0)
            return "Attachment"
        return t
    }
    // 流类型显示名:命中映射给中文,否则回退 API 原始 Type。
    function streamTypeLabel(t) {
        const m = { "Video": "视频", "Audio": "音频", "Subtitle": "字幕", "Attachment": "附件", "Data": "数据" }
        return m[t] || t
    }
    // 编码显示名:常见编码给标准写法,否则回退原始值大写。
    function codecLabel(c) {
        if (!c)
            return ""
        const m = {
            "h264": "H.264", "avc": "H.264", "hevc": "H.265", "h265": "H.265",
            "av1": "AV1", "vp8": "VP8", "vp9": "VP9", "mpeg2video": "MPEG-2",
            "mpeg4": "MPEG-4", "vc1": "VC-1", "wmv3": "WMV3", "prores": "ProRes",
            "aac": "AAC", "ac3": "AC-3", "eac3": "E-AC-3", "dts": "DTS", "dca": "DTS",
            "truehd": "TrueHD", "dtshd": "DTS-HD", "flac": "FLAC", "mp3": "MP3",
            "opus": "Opus", "vorbis": "Vorbis", "alac": "ALAC", "wma": "WMA",
            "wavpack": "WavPack", "ape": "APE", "mlp": "MLP",
            "pcm_s16le": "PCM", "pcm_s24le": "PCM", "pcm_s32le": "PCM",
            "subrip": "SRT", "srt": "SRT", "ass": "ASS", "ssa": "SSA",
            "pgs": "PGS", "pgssub": "PGS", "dvd_subtitle": "VobSub",
            "mov_text": "MOV_TEXT", "webvtt": "WebVTT",
            "ttf": "TTF", "otf": "OTF"
        }
        const k = String(c).toLowerCase()
        return m[k] || String(c).toUpperCase()
    }
    // 动态范围:VideoRangeType(新)优先,DOVI* 归一 Dolby Vision,
    // 其余(SDR/HDR10/HLG…)原样回退。
    function rangeLabel(s) {
        const r = s.videoRangeType || s.videoRange || ""
        if (r === "")
            return ""
        if (r.indexOf("DOVI") === 0)
            return "Dolby Vision"
        return r
    }
    function formatSampleRate(sr) {
        if (!sr || sr <= 0)
            return ""
        return (sr % 1000 === 0 ? sr / 1000 : (sr / 1000).toFixed(1)) + " kHz"
    }
    // 色彩三件套:一致时合并显示(如 bt709),不一致 / 拼接。
    function colorLabel(s) {
        const parts = []
        for (const v of [s.colorSpace, s.colorTransfer, s.colorPrimaries]) {
            if (v && parts.indexOf(v) < 0)
                parts.push(v)
        }
        return parts.join(" / ")
    }
    // 字幕位置:InternalStream=内嵌,ExternalStream=外挂;缺省按 isExternal。
    function subtitleLocationLabel(s) {
        if (s.locationType === "InternalStream")
            return "内嵌"
        if (s.locationType === "ExternalStream")
            return "外挂"
        return s.isExternal ? "外挂" : "内嵌"
    }
    // 快照旧文字并让旧树就位:旧树全宽全显盖住新树(此刻两者内容一致,
    // 无缝;新树随后被 applyDetail 换新值,但 opacity 已 0,不产生叠影)。
    function snapshotOldText() {
        root.heroOldTitle = root.heroTitle()
        root.heroOldMeta = root.metaLine()
        root.heroOldEpisode = root.heroEpisodeLine()
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


    // 页面底色 + Hero 背景:正文玻璃控件的采样源(在 overview 之下,不含
    // 正文控件 → 无自采样)。
    Rectangle {
        id: detailBg
        anchors.fill: parent
        color: Theme.bg

        // 全宽 Hero 背景(延伸到选集栏下方):无 backdrop 时纯色纵向渐变。
        // 高度 = 宽度按 16:9 推导(Emby backdrop 全为 16:9),任意窗口宽度
        // 下 PreserveAspectCrop 零裁切;"漏出"正文量随窗口宽度变化
        // (窄窗短、宽窗深),底部经 ShaderEffect 渐隐融入正文底色。
        Rectangle {
            id: heroBackdrop
            y: 0
            width: parent.width
            height: parent.width * 9 / 16
            visible: root.loaded
            z: 0
            // 底部渐隐:整块背景(图+氛围层)离屏合成后,底 10%
            // (y 0.90→1.0)alpha 1→0 淡出。取代原"透明→bgTint 盖色"
            // 遮罩——图片细节保留到最后一刻再溶解入页面底色,无平板色带;
            // 压暗职责由氛围层与页面底色(暗色)承担。
            layer.enabled: true
            layer.effect: ShaderEffect {
                property real u_fadeBand: Constants.detailHeroFadeBand
                fragmentShader: "qrc:/qt/qml/MoePlayer/Core/shaders/hero-fade.frag.qsb"
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
            // 滚轮步进走配置(页级 detailWheelStep,0=全局)。
            WheelStepHandler {
                targetItem: overview
                pageStep: ConfigManager.detailWheelStep
            }

            Column {
                id: overviewColumn
                width: parent.width

                // ================= Hero =================
                Item {
                    id: heroItem
                    width: parent.width
                    // 内容区与背景图同高(16:9 随窗口):bottom-* 位置即
                    // 背景图底部,海报/文字/按钮相对背景图定位成立。
                    height: root.width * 9 / 16
                    // ===== 定位代理(slot):三个槽各自用 states +
                    // AnchorChanges(官方推荐的条件锚切换机制,自动处理
                    // 解锚/设锚顺序,免手动坐标计算)。poster/text 槽按
                    // 9 宫格锚定,参考 heroItem 内容区(背景图 heroBackdrop
                    // 在槽的祖父级,Qt 锚仅限兄弟/直接父项,故以 heroItem
                    // 为参考——右侧位置天然避开选集栏);按钮槽按
                    // poster/text/backdrop 三模式。=====

                    // 海报槽:posterPos 9 宫格(边距 32/24)。AnchorChanges
                    // 只支持锚线(margin 属性不存在),边距走槽上的普通
                    // 绑定——仅对应边被锚定时生效,其余态惰性。
                    Item {
                        id: posterSlot
                        width: Constants.detailPosterW
                        height: Constants.detailPosterH
                        anchors.leftMargin: 32
                        anchors.rightMargin: 32
                        anchors.topMargin: 24
                        anchors.bottomMargin: 24
                        state: ConfigManager.detailPosterPos
                        states: [
                            State { name: "top-left"; AnchorChanges { target: posterSlot; anchors.left: heroItem.left; anchors.top: heroItem.top } },
                            State { name: "top-center"; AnchorChanges { target: posterSlot; anchors.horizontalCenter: heroItem.horizontalCenter; anchors.top: heroItem.top } },
                            State { name: "top-right"; AnchorChanges { target: posterSlot; anchors.right: heroItem.right; anchors.top: heroItem.top } },
                            State { name: "middle-left"; AnchorChanges { target: posterSlot; anchors.left: heroItem.left; anchors.verticalCenter: heroItem.verticalCenter } },
                            State { name: "middle-center"; AnchorChanges { target: posterSlot; anchors.horizontalCenter: heroItem.horizontalCenter; anchors.verticalCenter: heroItem.verticalCenter } },
                            State { name: "middle-right"; AnchorChanges { target: posterSlot; anchors.right: heroItem.right; anchors.verticalCenter: heroItem.verticalCenter } },
                            State { name: "bottom-left"; AnchorChanges { target: posterSlot; anchors.left: heroItem.left; anchors.bottom: heroItem.bottom } },
                            State { name: "bottom-center"; AnchorChanges { target: posterSlot; anchors.horizontalCenter: heroItem.horizontalCenter; anchors.bottom: heroItem.bottom } },
                            State { name: "bottom-right"; AnchorChanges { target: posterSlot; anchors.right: heroItem.right; anchors.bottom: heroItem.bottom } }
                        ]
                    }
                    // 文字槽:textPos 9 宫格(相对 heroItem,边距 32/24);
                    // followPoster → 跟随海报:水平贴海报外侧(海报左/中 →
                    // 右侧,海报右 → 左侧,边距 24),垂直底缘对齐海报底
                    // (按钮组跟随海报时上缩 60 避让)。边距绑定实时算。
                    Item {
                        id: textSlot
                        width: ConfigManager.detailTextWidth
                        height: ConfigManager.detailTextHeight
                        anchors.leftMargin: ConfigManager.detailTextPos === "followPoster"
                                             && root.textSide() !== "right" ? 24 : 32
                        anchors.rightMargin: ConfigManager.detailTextPos === "followPoster"
                                              && root.textSide() === "right" ? 24 : 32
                        anchors.topMargin: 24
                        anchors.bottomMargin: ConfigManager.detailTextPos === "followPoster"
                                               && ConfigManager.detailButtonsPos === "poster" ? 60 : 24
                        state: {
                            const t = ConfigManager.detailTextPos
                            if (t !== "followPoster")
                                return t
                            return "follow-" + (root.posterSide() === "right" ? "right" : "left")
                        }
                        states: [
                            State { name: "top-left"; AnchorChanges { target: textSlot; anchors.left: heroItem.left; anchors.top: heroItem.top } },
                            State { name: "top-center"; AnchorChanges { target: textSlot; anchors.horizontalCenter: heroItem.horizontalCenter; anchors.top: heroItem.top } },
                            State { name: "top-right"; AnchorChanges { target: textSlot; anchors.right: heroItem.right; anchors.top: heroItem.top } },
                            State { name: "middle-left"; AnchorChanges { target: textSlot; anchors.left: heroItem.left; anchors.verticalCenter: heroItem.verticalCenter } },
                            State { name: "middle-center"; AnchorChanges { target: textSlot; anchors.horizontalCenter: heroItem.horizontalCenter; anchors.verticalCenter: heroItem.verticalCenter } },
                            State { name: "middle-right"; AnchorChanges { target: textSlot; anchors.right: heroItem.right; anchors.verticalCenter: heroItem.verticalCenter } },
                            State { name: "bottom-left"; AnchorChanges { target: textSlot; anchors.left: heroItem.left; anchors.bottom: heroItem.bottom } },
                            State { name: "bottom-center"; AnchorChanges { target: textSlot; anchors.horizontalCenter: heroItem.horizontalCenter; anchors.bottom: heroItem.bottom } },
                            State { name: "bottom-right"; AnchorChanges { target: textSlot; anchors.right: heroItem.right; anchors.bottom: heroItem.bottom } },
                            State { name: "follow-left"; AnchorChanges { target: textSlot; anchors.left: posterSlot.right; anchors.bottom: posterSlot.bottom } },
                            State { name: "follow-right"; AnchorChanges { target: textSlot; anchors.right: posterSlot.left; anchors.bottom: posterSlot.bottom } }
                        ]
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
                                // 内容垂直:top 顶部对齐;middle 垂直居中;
                                // bottom/followPoster 沉底——简介文字底缘
                                // 对齐文字槽底(槽底随锚定 = 海报下缘)。
                                y: root.textSlotVertical() === "top"
                                    ? 0 : (root.textSlotVertical() === "middle"
                                            ? (parent.height - implicitHeight) / 2
                                            : parent.height - implicitHeight)
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
                                    text: root.heroOldEpisode
                                    color: Theme.textPrimary
                                    font.pixelSize: 18
                                    elide: Text.ElideRight
                                    width: parent.width
                                    horizontalAlignment: root.heroTextAlign
                                    visible: text !== ""
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
                                    Behavior on opacity { NumberAnimation { duration: 100 } }
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
                                // 内容垂直:top 顶部对齐;middle 垂直居中;
                                // bottom/followPoster 沉底(简介文字底缘
                                // 对齐文字槽底,同 heroOldCol)。
                                y: root.textSlotVertical() === "top"
                                    ? 0 : (root.textSlotVertical() === "middle"
                                            ? (parent.height - implicitHeight) / 2
                                            : parent.height - implicitHeight)
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
                                    text: root.heroEpisodeLine()
                                    color: Theme.textPrimary
                                    font.pixelSize: 18
                                    elide: Text.ElideRight
                                    width: parent.width
                                    horizontalAlignment: root.heroTextAlign
                                    visible: text !== ""
                                }
                                AppText {
                                    text: root.metaLine()
                                    color: root.detail.rating > 0 ? Theme.rating : Theme.textMuted
                                    font.pixelSize: 14
                                    width: parent.width
                                    horizontalAlignment: root.heroTextAlign
                                    opacity: text !== "" ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 100 } }
                                }
                            }
                        }
                    }
                    Item {
                        id: btnHolder
                        // 按钮行锚定容器:锚点放这里(自身无 LayoutMirroring,
                        // anchors 不反转);宽 = 行隐式宽(单向绑定,无环),
                        // 右锚时整块从参考点向左展开。行在内部只做子项
                        // 镜像(播放键贴参考端),不受锚点影响。
                        width: btnRow.width
                        height: btnRow.height
                        anchors.leftMargin: ConfigManager.detailButtonsPos === "backdrop"
                                             ? (ConfigManager.detailSidebarLeft
                                                    ? Constants.detailSidebarW + 32 : 32)
                                             : 24
                        anchors.rightMargin: 24
                        state: {
                            const b = ConfigManager.detailButtonsPos
                            if (b === "backdrop")
                                return "backdrop"
                            if (b === "poster")
                                return "poster-" + (root.posterSide() === "right" ? "right" : "left")
                            return "text-" + (root.textSide() === "right" ? "right" : "left")
                        }
                        states: [
                            State { name: "poster-left"; AnchorChanges { target: btnHolder; anchors.left: posterSlot.right } },
                            State { name: "poster-right"; AnchorChanges { target: btnHolder; anchors.right: posterSlot.left } },
                            State { name: "text-left"; AnchorChanges { target: btnHolder; anchors.left: textSlot.right } },
                            State { name: "text-right"; AnchorChanges { target: btnHolder; anchors.right: textSlot.left } },
                            State { name: "backdrop"; AnchorChanges { target: btnHolder; anchors.left: heroItem.left } }
                        ]
                        // 左锚参考距(弹性播放键宽用):poster → 海报外侧
                        // 256;text → 标题区外侧;backdrop → 左缘。
                        readonly property real _ref: {
                            const b = ConfigManager.detailButtonsPos
                            if (b === "backdrop")
                                return ConfigManager.detailSidebarLeft ? Constants.detailSidebarW + 32 : 32
                            if (b === "poster")
                                return 32 + Constants.detailPosterW + 24
                            return root.textSide() === "right"
                                   ? parent.width - textSlot.x + 24
                                   : textSlot.x + textSlot.width + 24
                        }
                        readonly property bool _leftSide: {
                            const b = ConfigManager.detailButtonsPos
                            if (b === "backdrop")
                                return true
                            if (b === "poster")
                                return root.posterSide() !== "right"
                            return root.textSide() !== "right"
                        }
                        // 播放键弹性宽:锚距内放不下时压缩(下限 120 保可点)。
                        readonly property real _playW: Math.min(220, Math.max(120,
                            parent.width - _ref - 16 - 44 - 20))
                        // 垂直:backdrop → 背景 16:9 底缘(背景高 = 宽*9/16,
                        // 与 heroBackdrop 同式);poster → 海报底对齐;
                        // text → 标题行顶(与标题对齐;标题在揭示树深处
                        // 不可锚,故 y 用绑定,与水平锚不同轴不冲突)。
                        y: ConfigManager.detailButtonsPos === "backdrop"
                            ? root.width * 9 / 16 - 44 - 24
                            : (ConfigManager.detailButtonsPos === "poster"
                                   ? posterSlot.y + posterSlot.height - 44
                                   : textSlot.y + heroNewCol.y)


                        Row {
                            id: btnRow
                            // 按钮行:位置由 btnHolder 锚定;仅在此反转子序——
                            // 右缘锚定(参考在行左侧)时 [已看][收藏][播放],
                            // 主播放键贴参考端;左缘锚定保持 [播放][收藏][已看]。
                            // LayoutMirroring 只反转子项,按钮内容不镜像;
                            LayoutMirroring.enabled: !btnHolder._leftSide
                            spacing: 10
                            opacity: root.textFade
                            Button {
                                id: playBtn
                                text: root.detail.type === "Series" ? root.seriesPlayCache : root.playButtonText()
                                // 弹性宽由 _playW 决定(锚距内放不下时压缩,
                                // 下限 120 保可点区域)。
                                width: btnHolder._playW
                                height: 44
                                font.pixelSize: 16
                                onClicked: root.detail.type === "Series" ? root.playSeries() : root.startPlayback(true)
                                background: FrostedGlass {
                                    radius: height / 2
                                    blurSource: detailBg
                                    scrollParent: overview
                                    // 主按钮:accent 色调玻璃(透出背景磨砂 + 主题色)。纯磨砂下
                                    // 0.45 太实会盖住模糊透出,降 0.30 留色调又透亮。
                                    glassColor: Qt.rgba(root.accentColor.r, root.accentColor.g,
                                                       root.accentColor.b, 0.30)
                                    borderColor: Qt.rgba(1, 1, 1, 0.30)
                                    thickness: 0
                                    frostAmount: 0.15
                                    edgeLight: 0.5
                                    saturation: 0.4
                                    blurRadius: 6
                                    sampleMargin: 48
                                    elevation: 6
                                }
                                contentItem: AppText {
                                    text: playBtn.text
                                    color: "white"
                                    font.pixelSize: 16
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                            }
                            // 收藏:Canvas 绘制爱心。未收藏藏白实心,已收藏粉实心。
                            Button {
                                id: favBtn
                                width: 44
                                height: 44
                                onClicked: root.toggleFavorite()
                                background: FrostedGlass {
                                    radius: height / 2
                                    blurSource: detailBg
                                    scrollParent: overview
                                    // 次要按钮:complement 色调玻璃,透出背景折射。
                                    glassColor: Qt.rgba(root.complementColor.r, root.complementColor.g,
                                                       root.complementColor.b, 0.22)
                                    borderColor: Qt.rgba(1, 1, 1, 0.28)
                                    thickness: 0
                                    frostAmount: 0.15
                                    edgeLight: 0.5
                                    saturation: 0.4
                                    blurRadius: 6
                                    sampleMargin: 48
                                    elevation: 5
                                }
                                contentItem: Item {
                                    anchors.fill: parent
                                    Canvas {
                                        anchors.centerIn: parent
                                        width: 22
                                        height: 22
                                        property color fillColor: root.isFavorite ? Constants.moePink : root.iconWhite
                                        onFillColorChanged: requestPaint()
                                        onPaint: {
                                            const ctx = getContext("2d")
                                            ctx.clearRect(0, 0, width, height)
                                            ctx.beginPath()
                                            ctx.moveTo(11, 19)
                                            ctx.bezierCurveTo(11, 19, 3, 13, 3, 8)
                                            ctx.bezierCurveTo(3, 5, 6, 3, 9, 5)
                                            ctx.bezierCurveTo(10, 5, 11, 6, 11, 7)
                                            ctx.bezierCurveTo(11, 6, 12, 5, 13, 5)
                                            ctx.bezierCurveTo(16, 3, 19, 5, 19, 8)
                                            ctx.bezierCurveTo(19, 13, 11, 19, 11, 19)
                                            ctx.closePath()
                                            ctx.fillStyle = fillColor
                                            ctx.fill()
                                        }
                                    }
                                }
                            }
                            // 已看/未看:Canvas 绘制圆圈 + 勾。已看绿色,未看藏白。
                            Button {
                                id: watchedBtn
                                width: 44
                                height: 44
                                onClicked: root.toggleWatched()
                                background: FrostedGlass {
                                    radius: height / 2
                                    blurSource: detailBg
                                    scrollParent: overview
                                    // 次要按钮:complement 色调玻璃,透出背景折射。
                                    glassColor: Qt.rgba(root.complementColor.r, root.complementColor.g,
                                                       root.complementColor.b, 0.22)
                                    borderColor: Qt.rgba(1, 1, 1, 0.28)
                                    thickness: 0
                                    frostAmount: 0.15
                                    edgeLight: 0.5
                                    saturation: 0.4
                                    blurRadius: 6
                                    sampleMargin: 48
                                    elevation: 5
                                }
                                contentItem: Item {
                                    anchors.fill: parent
                                    Canvas {
                                        anchors.centerIn: parent
                                        width: 22
                                        height: 22
                                        property color strokeColor: root.detail.played ? Theme.success : root.iconWhite
                                        onStrokeColorChanged: requestPaint()
                                        onPaint: {
                                            const ctx = getContext("2d")
                                            ctx.clearRect(0, 0, width, height)
                                            ctx.lineCap = "round"
                                            ctx.lineJoin = "round"
                                            ctx.lineWidth = 2.5
                                            ctx.strokeStyle = strokeColor
                                            // 圆圈
                                            ctx.beginPath()
                                            ctx.arc(width / 2, height / 2, 8, 0, Math.PI * 2)
                                            ctx.stroke()
                                            // 勾
                                            ctx.beginPath()
                                            ctx.moveTo(7, 11)
                                            ctx.lineTo(10, 14)
                                            ctx.lineTo(15, 8)
                                            ctx.stroke()
                                        }
                                    }
                                }
                            }
                            Button {
                                id: replayBtn
                                text: "从头播放"
                                visible: root.detail.type !== "Series" && root.detail.positionTicks > 0 && !root.detail.played
                                width: 110
                                height: 44
                                onClicked: root.startPlayback(false)
                                background: FrostedGlass {
                                    radius: height / 2
                                    blurSource: detailBg
                                    scrollParent: overview
                                    // 次要按钮:complement 色调玻璃,透出背景折射。
                                    glassColor: Qt.rgba(root.complementColor.r, root.complementColor.g,
                                                       root.complementColor.b, 0.22)
                                    borderColor: Qt.rgba(1, 1, 1, 0.28)
                                    thickness: 0
                                    frostAmount: 0.15
                                    edgeLight: 0.5
                                    saturation: 0.4
                                    blurRadius: 6
                                    sampleMargin: 48
                                    elevation: 5
                                }
                                contentItem: AppText {
                                    text: replayBtn.text
                                    color: "white"
                                    font.pixelSize: 14
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                            }
                        }
                    }                    
                }

                // ================= 播放选项(版本/音频/字幕) =================
                // 正文流一节(Hero 与简介之间),占自有空间不与 hero 标题/播放键重叠。
                // 三段摘要行常显当前选中;点行弹出该行下方的下拉浮层(Popup 覆盖
                // 在上层,点外/Esc 自动收起)。选中存 root.sel*,点播放带入协商。
                Column {
                    id: playOptsCol
                    anchors.left: parent.left
                    anchors.leftMargin: Constants.detailSectionMargin
                    width: parent.width - Constants.detailSectionMargin * 2
                    spacing: 6
                    visible: (root.detail.mediaSources || []).length > 0
                    opacity: root.textFade

                    // 通用行:图标 + 当前选中摘要 + ▾;点击弹出下拉浮层。
                    // 组件不引用外层 id(除 root),宽由 rowWidth 传入。
                    component OptRow: FrostedGlass {
                        id: optRow
                        property string sectionKey: ""
                        property string icon: ""
                        property string mainText: ""
                        property string subText: ""
                        property var listModel: []
                        property real rowWidth: 100
                        signal picked(var entry)
                        width: rowWidth
                        height: subText !== "" ? 52 : 40
                        radius: 10
                        // 摘要行玻璃:采样 detailBg(页面底色+hero,无自采样),
                        // 透出背景 + 选中时 accent 描边。
                        blurSource: detailBg
                            scrollParent: overview
                        glassColor: Qt.rgba(1, 1, 1, 0.06)
                        borderColor: drop.opened ? root.accentColor : Qt.rgba(1, 1, 1, 0.15)
                        thickness: 0
                        frostAmount: 0.15
                        edgeLight: 0.4
                        saturation: 0.3
                        blurRadius: 5
                        sampleMargin: 32
                        elevation: 3

                        Row {
                            id: headRow
                            anchors.fill: parent
                            spacing: 10
                            AppText {
                                width: 28
                                height: parent.height
                                text: optRow.icon
                                color: Theme.textMuted
                                font.pixelSize: 16
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                            Column {
                                width: parent.width - 28 - 24 - 10 * 3
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2
                                AppText {
                                    width: parent.width
                                    text: optRow.mainText
                                    color: Theme.textPrimary
                                    font.pixelSize: 13
                                    elide: Text.ElideRight
                                }
                                AppText {
                                    width: parent.width
                                    visible: optRow.subText !== ""
                                    text: optRow.subText
                                    color: Theme.textMuted
                                    font.pixelSize: 11
                                    elide: Text.ElideRight
                                }
                            }
                            AppText {
                                width: 24
                                height: parent.height
                                text: drop.opened ? "▴" : "▾"
                                color: Theme.textMuted
                                font.pixelSize: 13
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: drop.opened ? drop.close() : drop.open()
                        }

                        // 下拉浮层:贴行下方弹出,覆盖在上层内容之上;
                        // modal+CloseOnPressOutside:点行外任意处/Esc 收起;点行头 toggle。
                        Popup {
                            id: drop
                            y: optRow.height + 4
                            width: optRow.width
                            height: Math.min(optListCol.implicitHeight + 8, 288)
                            padding: 4
                            // modal:true 使打开时行头 press 被 modal 消费(只关不重开),非 modal
                            // 时 outside 事件透传行头会收起又重开。dim:false 不遮暗背景。
                            // 代价:下拉开着时点其他行只关不切(需二次点击),属预期。
                            modal: true
                            dim: false
                            focus: true
                            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                            background: Rectangle {
                                radius: 10
                                color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.98)
                                border.width: 1
                                border.color: Qt.rgba(1, 1, 1, 0.12)
                            }
                            contentItem: Flickable {
                                contentWidth: width
                                contentHeight: optListCol.implicitHeight
                                clip: true
                                Column {
                                    id: optListCol
                                    width: drop.width - 8
                                    spacing: 2
                                    Repeater {
                                        model: optRow.listModel
                                        delegate: Rectangle {
                                            id: optEntry
                                            required property var modelData
                                            width: optListCol.width
                                            height: 34
                                            radius: 8
                                            property bool sel: modelData._sel === true
                                            color: sel ? Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.22)
                                                       : (entryMa.containsMouse ? Qt.rgba(1, 1, 1, 0.06) : "transparent")
                                            Rectangle {
                                                anchors.left: parent.left
                                                anchors.leftMargin: 12
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 8
                                                height: 8
                                                radius: 4
                                                color: root.accentColor
                                                visible: optEntry.sel
                                            }
                                            AppText {
                                                anchors.left: parent.left
                                                anchors.leftMargin: 28
                                                anchors.right: parent.right
                                                anchors.rightMargin: 10
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: optEntry.modelData._label || ""
                                                color: optEntry.sel ? Theme.textPrimary : Theme.textMuted
                                                font.pixelSize: 13
                                                elide: Text.ElideRight
                                            }
                                            MouseArea {
                                                id: entryMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    optRow.picked(optEntry.modelData)
                                                    drop.close()
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ---- 版本行(多版本才显示) ----
                    OptRow {
                        sectionKey: "version"
                        icon: "🎞"
                        rowWidth: playOptsCol.width
                        visible: (root.detail.mediaSources || []).length > 0
                        mainText: root.currentVersionLabel()
                        subText: root.versionSubLabel(root.selVersion())
                        listModel: {
                            const ms = root.detail.mediaSources || []
                            const out = []
                            for (let i = 0; i < ms.length; ++i) {
                                const v = ms[i]
                                out.push({ id: v.id, _sel: v.id === root.selMediaSourceId,
                                           _label: (v.name || "版本") + (root.versionSubLabel(v) !== "" ? "  ·  " + root.versionSubLabel(v) : "") })
                            }
                            return out
                        }
                        onPicked: function (entry) { root.selectVersion(entry.id) }
                    }
                    // ---- 音频行(当前源有音频才显示) ----
                    OptRow {
                        sectionKey: "audio"
                        icon: "♪"
                        rowWidth: playOptsCol.width
                        visible: true
                        mainText: root.currentAudioLabel()
                        listModel: {
                            const ss = root.audioOptions()
                            const out = []
                            for (let i = 0; i < ss.length; ++i) {
                                const e = ss[i]
                                out.push({ index: e.index, _sel: e.index === root.selAudioIndex,
                                           _label: root.trackOptionLabel("Audio", e) })
                            }
                            return out
                        }
                        onPicked: function (entry) { root.selAudioIndex = entry.index }
                    }
                    // ---- 字幕行(常显;含 关闭字幕/默认/各轨) ----
                    OptRow {
                        sectionKey: "subtitle"
                        icon: "󰨗"
                        rowWidth: playOptsCol.width
                        visible: true
                        mainText: root.currentSubtitleLabel()
                        listModel: {
                            const ss = root.subtitleOptionsFull()
                            const out = []
                            for (let i = 0; i < ss.length; ++i) {
                                const e = ss[i]
                                out.push({ index: e.index, _sel: e.index === root.selSubtitleIndex,
                                           _label: root.trackOptionLabel("Subtitle", e) })
                            }
                            return out
                        }
                        onPicked: function (entry) { root.selSubtitleIndex = entry.index }
                    }
                }
                // ================= 简介 =================
                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: Constants.detailSectionMargin
                    width: parent.width - Constants.detailSectionMargin * 2
                    spacing: 8
                    // 空/缺失简介不显示该节。
                    visible: !!root.detail.overview && root.detail.overview.length > 0
                    opacity: root.textFade * visible
                    Behavior on opacity { NumberAnimation { duration: 200 } }

                    AppText {
                        text: "简介"
                        color: Theme.textPrimary
                        font.pixelSize: 18
                        font.bold: true
                    }
                    // 简介文字框:玻璃质感(透出下方背景),完整显示不截断。
                    FrostedGlass {
                        id: overviewBox
                        width: parent.width
                        height: overviewBoxText.implicitHeight + 24
                        radius: 12
                        blurSource: detailBg
                        scrollParent: overview
                        // 玻璃底色淡一点(白底微透,非黑底)——黑色太深会盖住
                        // 磨砂模糊的透亮感,淡色透出下方模糊内容才显玻璃质感。
                        glassColor: Qt.rgba(1, 1, 1, 0.06)
                        borderColor: Qt.rgba(1, 1, 1, 0.12)
                        thickness: 0
                        frostAmount: 0.15
                        edgeLight: 0.35
                        saturation: 0.3
                        blurRadius: 6
                        sampleMargin: 32
                        elevation: 3
                        AppText {
                            id: overviewBoxText
                            anchors.fill: parent
                            anchors.margins: 12
                            text: root.detail.overview || ""
                            color: "white"
                            font.pixelSize: 14
                            wrapMode: Text.Wrap
                        }
                    }
                }

                // ================= 演职人员 =================
                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: Constants.detailSectionMargin
                    width: parent.width - Constants.detailSectionMargin * 2
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
                                    property bool hovered: false
                                    HoverHandler {
                                        onHoveredChanged: peopleCard.hovered = hovered
                                    }
                                    Column {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.top: parent.top
                                        anchors.topMargin: 6
                                        spacing: 4
                                        Item {
                                            width: 60
                                            height: 60
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            Rectangle {
                                                anchors.fill: parent
                                                radius: 30
                                                clip: true
                                                color: root.surfaceTint
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
                                            // hover 粉色细环。
                                            Rectangle {
                                                anchors.centerIn: parent
                                                width: 66
                                                height: 66
                                                radius: 33
                                                color: "transparent"
                                                border.width: peopleCard.hovered ? 2 : 0
                                                border.color: Constants.moePink
                                                opacity: peopleCard.hovered ? 1 : 0
                                                Behavior on opacity { NumberAnimation { duration: 160 } }
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
                    anchors.left: parent.left
                    anchors.leftMargin: Constants.detailSectionMargin
                    width: parent.width - Constants.detailSectionMargin * 2
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
                        // 每版本一整块:头部版本名+徽章,下方流卡片横排。
                        delegate: FrostedGlass {
                            id: verBlock
                            required property var modelData
                            required property int index
                            // 销毁期间 parent 会被置 null(换集重建媒体源时),空防。
                            width: parent ? parent.width : 0
                            height: verCol.implicitHeight + 28
                            radius: 12
                            // 媒体信息卡玻璃:透出背景,微折射。
                            blurSource: detailBg
                            scrollParent: overview
                            glassColor: Qt.rgba(1, 1, 1, 0.05)
                            borderColor: Qt.rgba(1, 1, 1, 0.12)
                            thickness: 0
                            frostAmount: 0.15
                            edgeLight: 0.35
                            saturation: 0.3
                            blurRadius: 6
                            sampleMargin: 32
                            elevation: 3

                            // 本版本视频流(头部徽章取分辨率/动态范围)。
                            readonly property var videoStream: {
                                const ss = verBlock.modelData.streams || []
                                for (let i = 0; i < ss.length; ++i) {
                                    if (root.streamKind(ss[i]) === "Video")
                                        return ss[i]
                                }
                                return null
                            }
                            // 头部徽章:容器/大小/时长/总码率/分辨率/动态范围(空值不占位)。
                            readonly property var headBadges: {
                                const out = []
                                const m = verBlock.modelData
                                if (m.container)
                                    out.push(m.container.toUpperCase())
                                if (m.sizeBytes > 0)
                                    out.push(root.formatSize(m.sizeBytes))
                                if (m.runTimeTicks > 0)
                                    out.push(root.formatTime(m.runTimeTicks / Constants.ticksPerSecond))
                                if (m.bitrate > 0)
                                    out.push(root.formatBitrate(m.bitrate))
                                const vs = verBlock.videoStream
                                if (vs && vs.height > 0)
                                    out.push(vs.height >= 2160 ? "4K" : vs.height + "p")
                                const rg = vs ? root.rangeLabel(vs) : ""
                                if (rg)
                                    out.push(rg)
                                return out
                            }
                            // 流卡片模型:视频 + 音频×n + 字幕×n + 附件×n;空值行不出。
                            // 文件级信息(容器/大小/时长/总码率/路径)在版本块头部,不占卡。
                            readonly property var cardModels: {
                                const out = []
                                const m = verBlock.modelData
                                const ss = m.streams || []
                                const vs = verBlock.videoStream
                                if (vs) {
                                    const rows = []
                                    rows.push({ k: "编码", v: root.codecLabel(vs.codec) + (vs.profile ? " · " + vs.profile : "") })
                                    if (vs.width > 0 && vs.height > 0)
                                        rows.push({ k: "分辨率", v: vs.width + "×" + vs.height })
                                    const rg = root.rangeLabel(vs)
                                    if (rg)
                                        rows.push({ k: "动态范围", v: rg })
                                    if (vs.frameRate > 0)
                                        rows.push({ k: "帧率", v: vs.frameRate.toFixed(3) })
                                    if (vs.bitDepth > 0)
                                        rows.push({ k: "位深", v: vs.bitDepth + "bit" })
                                    const cl = root.colorLabel(vs)
                                    if (cl)
                                        rows.push({ k: "色彩", v: cl })
                                    if (vs.bitrate > 0)
                                        rows.push({ k: "码率", v: root.formatBitrate(vs.bitrate) })
                                    out.push({ cap: root.streamTypeLabel("Video"), tag: false, rows: rows })
                                }
                                let an = 0
                                let sn = 0
                                // 附件(ASS 字体等)逐条信息量低且数量多,汇总一卡不逐条铺。
                                let attCount = 0
                                let attSize = 0
                                const attFormats = {}
                                for (let i = 0; i < ss.length; ++i) {
                                    const s = ss[i]
                                    const kind = root.streamKind(s)
                                    if (kind === "Audio") {
                                        an += 1
                                        const rows = []
                                        rows.push({ k: "编码", v: root.codecLabel(s.codec) + (s.profile ? " · " + s.profile : "") })
                                        const ch = s.channelLayout || (s.channels > 0 ? s.channels + "ch" : "")
                                        if (ch)
                                            rows.push({ k: "声道", v: ch })
                                        const lang = s.displayLanguage || s.language
                                        if (lang)
                                            rows.push({ k: "语言", v: lang })
                                        const sr = root.formatSampleRate(s.sampleRate)
                                        if (sr)
                                            rows.push({ k: "采样率", v: sr })
                                        if (s.bitDepth > 0)
                                            rows.push({ k: "位深", v: s.bitDepth + "bit" })
                                        if (s.bitrate > 0)
                                            rows.push({ k: "码率", v: root.formatBitrate(s.bitrate) })
                                        out.push({ cap: root.streamTypeLabel(s.type) + " " + an, tag: !!s.isDefault, rows: rows })
                                    } else if (kind === "Subtitle") {
                                        sn += 1
                                        const rows = []
                                        rows.push({ k: "格式", v: root.codecLabel(s.codec) })
                                        const st = s.displayTitle || s.title
                                        if (st)
                                            rows.push({ k: "标题", v: st })
                                        const sl = s.displayLanguage || s.language
                                        if (sl)
                                            rows.push({ k: "语言", v: sl })
                                        rows.push({ k: "位置", v: root.subtitleLocationLabel(s) })
                                        if (s.isForced)
                                            rows.push({ k: "强制", v: "是" })
                                        out.push({ cap: root.streamTypeLabel(s.type) + " " + sn, tag: !!s.isDefault, rows: rows })
                                    } else if (kind === "Attachment") {
                                        attCount += 1
                                        attSize += s.attachmentSize || 0
                                        const f = root.codecLabel(s.codec)
                                        attFormats[f] = (attFormats[f] || 0) + 1
                                    } else if (kind !== "Video") {
                                        // 未知类型(Type/codec 均无映射):通用卡,cap 回退原始 Type。
                                        const rows = []
                                        rows.push({ k: "编码", v: root.codecLabel(s.codec) })
                                        const gl = s.displayLanguage || s.language
                                        if (gl)
                                            rows.push({ k: "语言", v: gl })
                                        if (s.bitrate > 0)
                                            rows.push({ k: "码率", v: root.formatBitrate(s.bitrate) })
                                        out.push({ cap: root.streamTypeLabel(s.type || "未知"), tag: !!s.isDefault, rows: rows })
                                    }
                                }
                                if (attCount > 0) {
                                    const rows = [{ k: "数量", v: String(attCount) }]
                                    if (attSize > 0)
                                        rows.push({ k: "总大小", v: root.formatSize(attSize) })
                                    rows.push({ k: "格式", v: Object.keys(attFormats).map(function (f) { return f + "×" + attFormats[f] }).join(" · ") })
                                    out.push({ cap: root.streamTypeLabel("Attachment"), tag: false, rows: rows })
                                }
                                // 时间卡(添加/修改,条目级):每个版本块都出。
                                const dc = (root.detail.dateCreated || "").slice(0, 10)
                                const dm = (root.detail.dateModified || "").slice(0, 10)
                                if (dc || dm) {
                                    const rows = []
                                    if (dc)
                                        rows.push({ k: "添加", v: dc })
                                    if (dm)
                                        rows.push({ k: "修改", v: dm })
                                    out.push({ cap: "时间", tag: false, rows: rows })
                                }
                                return out
                            }

                            Column {
                                id: verCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: 14
                                spacing: 12
                                // 头部:版本名 + 徽章。
                                Item {
                                    width: parent.width
                                    height: 24
                                    AppText {
                                        anchors.left: parent.left
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "版本 " + (verBlock.index + 1) + (verBlock.modelData.name ? " · " + verBlock.modelData.name : "")
                                        color: Theme.textPrimary
                                        font.pixelSize: 14
                                        font.bold: true
                                    }
                                    Row {
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 6
                                        Repeater {
                                            model: verBlock.headBadges
                                            delegate: Rectangle {
                                                required property var modelData
                                                height: 22
                                                width: badgeText.implicitWidth + 14
                                                radius: 11
                                                color: Qt.rgba(root.complementColor.r, root.complementColor.g, root.complementColor.b, 0.15)
                                                border.width: 1
                                                border.color: Qt.rgba(root.complementColor.r, root.complementColor.g, root.complementColor.b, 0.35)
                                                AppText {
                                                    id: badgeText
                                                    anchors.centerIn: parent
                                                    text: modelData
                                                    color: Theme.textPrimary
                                                    font.pixelSize: 12
                                                }
                                            }
                                        }
                                    }
                                }
                                // 流卡片横排(超出可横向拖动)。
                                ListView {
                                    width: parent.width
                                    height: 224
                                    orientation: ListView.Horizontal
                                    spacing: 12
                                    clip: true
                                    model: verBlock.cardModels
                                    delegate: Rectangle {
                                        id: miCard
                                        required property var modelData
                                        width: 190
                                        height: 224
                                        radius: 11
                                        color: Theme.surface
                                        border.width: 1
                                        border.color: Qt.rgba(1, 1, 1, 0.10)
                                        Column {
                                            anchors.fill: parent
                                            anchors.margins: 13
                                            spacing: 4
                                            // 卡头:流名(粉色小字)+ 默认标记。
                                            Item {
                                                width: parent.width
                                                height: 16
                                                AppText {
                                                    anchors.left: parent.left
                                                    text: miCard.modelData.cap
                                                    color: Constants.moePink
                                                    font.pixelSize: 11
                                                    font.bold: true
                                                    font.letterSpacing: 1.2
                                                }
                                                Rectangle {
                                                    visible: miCard.modelData.tag
                                                    anchors.right: parent.right
                                                    height: 15
                                                    width: tagText.implicitWidth + 10
                                                    radius: 4
                                                    color: "transparent"
                                                    border.width: 1
                                                    border.color: Qt.rgba(1, 1, 1, 0.25)
                                                    AppText {
                                                        id: tagText
                                                        anchors.centerIn: parent
                                                        text: "默认"
                                                        color: Theme.textMuted
                                                        font.pixelSize: 10
                                                    }
                                                }
                                            }
                                            // KV 行:键左值右,行间细分隔线(首行无)。
                                            Repeater {
                                                model: miCard.modelData.rows
                                                delegate: Item {
                                                    id: kvRow
                                                    required property var modelData
                                                    required property int index
                                                    // 销毁期间 parent 会被置 null(换集重建米卡时),空防。
                                                    width: parent ? parent.width : 0
                                                    height: 22
                                                    Rectangle {
                                                        visible: kvRow.index > 0
                                                        anchors.top: parent.top
                                                        width: kvRow.width
                                                        height: 1
                                                        color: Qt.rgba(1, 1, 1, 0.07)
                                                    }
                                                    AppText {
                                                        anchors.left: parent.left
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        text: kvRow.modelData.k
                                                        color: Theme.textMuted
                                                        font.pixelSize: 12
                                                    }
                                                    AppText {
                                                        anchors.right: parent.right
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        width: Math.min(implicitWidth, parent ? parent.width - 60 : 0)
                                                        horizontalAlignment: Text.AlignRight
                                                        text: kvRow.modelData.v
                                                        color: Theme.textPrimary
                                                        font.pixelSize: 12
                                                        elide: Text.ElideRight
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ================= 相似推荐 =================
                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: Constants.detailSectionMargin
                    width: parent.width - Constants.detailSectionMargin * 2
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
                            // 上下各留 20px 边距,hover 放大时不被 ListView 裁剪。
                            height: Constants.detailCardH + 40
                            property bool hovered: false
                            scale: hovered ? 1.05 : 1.0
                            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                            Rectangle {
                                anchors.centerIn: parent
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
                            HoverHandler {
                                onHoveredChanged: similarCard.hovered = hovered
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
                radius: 0
                color: "transparent"
                border.width: 0
                clip: true

                // "第"/"季":锚定数字牌两侧(右/左缘贴牌边 8px 间隙),
                // 往数字牌靠近且随其位置跟随,不再贴条边缘。
                AppText {
                    text: "第"
                    color: seasonStrip.stripHovered ? Constants.moePink : Theme.textPrimary
                    font.pixelSize: 14
                    anchors.right: digitCol.left
                    anchors.rightMargin: 8
                    anchors.top: parent.top
                    anchors.topMargin: 42
                    Behavior on color { ColorAnimation { duration: 160 } }
                }
                // 数字区:行高固定(上 16 + 候选牌 62 + 下 16),每行内容
                // 垂直居中 → 候选牌原位缩放,不上下移动;上下邻季行
                // 始终占位,折叠时仅透明(淡入淡出)。
                Column {
                    id: digitCol
                    anchors.top: parent.top
                    anchors.topMargin: 2
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 66
                    height: 94
                    spacing: 0
                    // 上一季(列表内实际存在的季;无则隐藏)。
                    AppText {
                        id: upText
                        width: 66
                        height: 16
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
                        width: 66
                        height: 62
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
                                    width: seasonStrip.stripHovered ? 28 : 22
                                    height: seasonStrip.stripHovered ? 62 : 48
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
                        width: 66
                        height: 16
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
                // "季" 同样锚定数字牌(左缘贴牌边 8px)。
                AppText {
                    text: "季"
                    color: seasonStrip.stripHovered ? Constants.moePink : Theme.textPrimary
                    font.pixelSize: 14
                    anchors.left: digitCol.right
                    anchors.leftMargin: 8
                    anchors.top: parent.top
                    anchors.topMargin: 42
                    Behavior on color { ColorAnimation { duration: 160 } }
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
                    // 滚轮切季(不影响下方分集列表滚动,不拦截事件)
                    onWheel: (event) => root.stepCandidate(event.angleDelta.y > 0 ? -1 : 1)
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
                layer.enabled: true
                layer.effect: ShaderEffect {
                    property real u_margin: Constants.detailEpisodeRowMargin / episodeList.height
                    fragmentShader: "qrc:/qt/qml/MoePlayer/Core/shaders/episode-fade.frag.qsb"
                }
                delegate: Item {
                    id: episodeItem
                    // 同上:required 声明识别 C++ 模型角色。
                    required property var model
                    // 详情/播放中的当前集:选中态(莫奈边框/白色标题)。
                    readonly property bool selected: model.id === root.itemId
                    width: episodeList.width
                    height: Constants.detailEpisodeRowH
                    // hover 放大(基础样式)
                    scale: episodeHover.hovered ? Constants.detailEpisodeHoverScale : 1.0
                    Behavior on scale { NumberAnimation { duration: Constants.animMaxMs } }

                    // 纵向卡片:缩略图(顶部,内嵌进度条)+ 集名(下方)。
                    // 缩略图高 = 行高 - 上下外边距 - 列间距 - 集名行高,总高恒填满行。
                    Column {
                        id: cardCol
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: Constants.detailEpisodeRowMargin
                        spacing: 6
                        // 海报缩略图(16:9 剧照)
                        Rectangle {
                            id: thumbBox
                            height: Constants.detailEpisodeRowH - Constants.detailEpisodeRowMargin*2
                                   - cardCol.spacing - episodeTitle.implicitHeight
                            width: height/9*16
                            color: Theme.bg
                            radius: 18
                            clip: true
                            CrossfadeImage {
                                id: thumb
                                anchors.fill: parent
                                cornerRadius: 18
                                // 无海报回退:父级(剧集)背景图;两者都无则为空(显示播放图标)。
                                source: episodeItem.model.posterId ? "image://emby/" + episodeItem.model.posterId
                                      : (episodeItem.model.parentBackdropId ? "image://emby/" + episodeItem.model.parentBackdropId : "")
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                duration: 500
                                cache: true
                            }
                            // 选中/悬停边框:透明覆盖层(同尺寸描边)。border 画在
                            // 矩形自身边缘内侧,会被平铺的缩略图子项盖住,故置于
                            // 图片之上;选中常显莫奈色,hover 放大 + 变浅。
                            Rectangle {
                                anchors.fill: parent
                                radius: 18
                                color: "transparent"
                                border.width: (episodeItem.selected || episodeHover.hovered) ? 2 : 0
                                border.color: episodeItem.selected && !episodeHover.hovered
                                              ? root.accentColor
                                              : Qt.lighter(root.accentColor, 1.35)
                                Behavior on border.width { NumberAnimation { duration: Constants.animMinMs } }
                                Behavior on border.color { ColorAnimation { duration: Constants.animMinMs } }
                            }
                            // 无海报且无父级背景(都拿不到图)或加载失败回退:Canvas 播放图标。
                            Canvas {
                                anchors.centerIn: parent
                                width: 28
                                height: 28
                                property color iconColor: episodeItem.selected ? "white" : Theme.textMuted
                                onIconColorChanged: requestPaint()
                                visible: (!episodeItem.model.posterId && !episodeItem.model.parentBackdropId)
                                          || thumb.status === Image.Error
                                onPaint: {
                                    const ctx = getContext("2d")
                                    ctx.clearRect(0, 0, width, height)
                                    ctx.fillStyle = iconColor
                                    ctx.beginPath()
                                    ctx.moveTo(8, 5)
                                    ctx.lineTo(22, 14)
                                    ctx.lineTo(8, 23)
                                    ctx.closePath()
                                    ctx.fill()
                                }
                            }
                            // 已看徽标:缩略图右上角实心圆(莫奈强调色),中央镂空
                            // 透明勾(Canvas destination-out 擦成洞,透出缩略图)。
                            Canvas {
                                id: watchedBadge
                                // 颜色随莫奈取色更新(Canvas 不随外部属性自动重绘)。
                                property color badgeColor: root.accentColor
                                onBadgeColorChanged: requestPaint()
                                width: 22
                                height: 22
                                anchors.top: parent.top
                                anchors.right: parent.right
                                anchors.margins: 6
                                visible: episodeItem.model.played
                                onPaint: {
                                    const ctx = getContext("2d")
                                    ctx.reset()
                                    const w = width, h = height
                                    // 实心圆(内缩 0.5 防边缘锯齿切角)。
                                    ctx.beginPath()
                                    ctx.arc(w / 2, h / 2, w / 2 - 0.5, 0, Math.PI * 2)
                                    ctx.fillStyle = badgeColor
                                    ctx.fill()
                                    // 镂空勾:勾笔画区域擦成透明。
                                    ctx.globalCompositeOperation = "destination-out"
                                    ctx.beginPath()
                                    ctx.moveTo(w * 0.28, h * 0.52)
                                    ctx.lineTo(w * 0.44, h * 0.68)
                                    ctx.lineTo(w * 0.74, h * 0.34)
                                    ctx.lineWidth = Math.max(2, w * 0.13)
                                    ctx.lineCap = "round"
                                    ctx.lineJoin = "round"
                                    ctx.stroke()
                                }
                            }
                            // 观看进度条:居中,悬于缩略图底部上方(不与底边
                            // 重合);宽 = 缩略图宽 - 圆角(18),圆角区不再
                            // 构成干扰;填充莫奈互补色,轨道半透明黑压暗。
                            Item {
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 3
                                width: parent.width - thumbBox.radius
                                height: 5
                                visible: episodeItem.model.positionTicks > 0 && !episodeItem.model.played && episodeItem.model.runtimeTicks > 0
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 2.5
                                    color: Qt.rgba(0, 0, 0, 0.45)
                                }
                                Rectangle {
                                    width: parent.width * Math.min(1, episodeItem.model.positionTicks / episodeItem.model.runtimeTicks)
                                    height: parent.height
                                    radius: 2.5
                                    color: root.complementColor
                                }
                            }
                        }
                        // 集名:缩略图下方,单行省略,居中。
                        AppText {
                            id: episodeTitle
                            width: thumbBox.width
                            text: episodeItem.model.name
                            color: episodeItem.selected ? "white" : Theme.textPrimary
                            font.pixelSize: 14
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            opacity: root.textFade
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
                            root.replaceItem(episodeItem.model.id, episodeItem.model.posterId, episodeItem.model.name, true)
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
            console.info("Detail: 详情数据到达", d.id, d.name || "")
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
            console.debug("Detail: 分季到达")
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
                root.selectSeason(seasonId, !root.replaceKeepScroll)
            else
                root.loaded = true // 无季/无分集:选集就绪,直接渲染结构
        }
        function onEpisodesReceived(serverUrl) {
            if (serverUrl !== root.serverUrl)
                return
            console.debug("Detail: 分集到达")
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
                console.info("Detail: 播放协商就绪", meta.itemId)
                const m = Object.assign({}, meta)
                m.resumePositionTicks = root.resumeTicks || 0
                root.playbackDelivered(url, headers, m)
            }
        }
        // 播放协商失败(精确信号,仅播放请求触发):复位防抖并通知
        // 主窗口关闭加载态窗口(显示失败信息)。
        function onPlaybackFailed(serverUrl, itemId, message) {
            if (serverUrl !== root.serverUrl)
                return
            console.warn("Detail: 播放协商失败", itemId, message)
            root.playbackPending = false
            root.playbackFailed(itemId, message)
        }
    }

    // 返回快捷键:Alt+←(原"← 返回"按钮移除后替代);仅本页可见时生效,
    // 被上层页覆盖/pop 后不误触发。
    Shortcut {
        sequences: ["Alt+Left"]
        enabled: root.visible
        onActivated: root.back()
    }

}

