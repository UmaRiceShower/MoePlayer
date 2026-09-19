pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import MoePlayer.Core

ApplicationWindow {
    id: root
    width: 1280
    height: 720
    visible: true
    title: Qt.application.name

    property var libraryState: null
    // 最近浏览的服务器(全局搜索按它路由;打开任意库/详情页时更新)。
    property string currentServerUrl: ""
    // 最近浏览的账号 id(凭据精确定位;随导航更新)。
    property string currentAccountId: ""
    // 首页过滤注入(服务器管理页点卡片写入,Home 消费即清):
    // 值为账号显示名,落到首页过滤框(按服名命中行/卡条/hero)。
    property string homeFilterText: ""
    // ---- 播放列表全集合 + on_load hook 协商链 ----
    // MpvClient 播放列表由全集(m3u 标题占位)构成:上/下集与播放列表菜单
    // 走 mpv 官方;占位条目经 on_load hook(moe-hook.lua)请求真实地址,
    // 本区域负责协商/缓存/应答。当前集选择意图延续:音轨/内封字幕按
    // 同类序号(ordinal)下推;外挂字幕(URL)逐集不同,用协商默认。
    property int _curAudioOrdinal: -1
    property int _curSubtitleOrdinal: -1
    property string _curSubtitleUrl: ""
    // 全集序列未就绪时缓存的播放上下文(allEpisodesReady 后重试)。
    property var _pendingChain: null
    // 当前播放集上下文(playbackContextChanged 更新)。
    property var _curMeta: null
    property var _sessionMeta: ({}) // 会话键(集 itemId)→ meta;换集协商按会话取
    // 本次播放的账号(Detail 随 playWindowRequested 下推):playbackReady 的
    // meta 不含 accountId,交付时并入,供按集续链/全季拉取按账号定位。
    property string _playAccountId: ""
    // 全集列表已灌入 mpv(true 后不再重复 replace;contextChanged 仅在
    // 首次/直达边缘时补建一次——重复 replace 会无限重启循环)。
    property bool _listPrimed: false
    // 集详情直达(全集模型未就绪):deliver 挂起,allEpisodesReady 后再建
    // 列表并 deliver——否则回落单条 loadfile,连播/标题全退化。
    // meta 存本属性(该场景未 file-loaded,_curMeta 不可用/可能是残留)。
    property bool _deliverPending: false
    property var _deliverMeta: null
    // 协商结果缓存:id -> {url, headers, meta}(预取/hook 共用)。
    property var _epUrlCache: ({})
    // 协商结果缓存写入唯一口:上限 40 条,超出清最旧(键序即插入序)。
    function cacheEpisodeUrl(id, url, headers, meta) {
        const ck = Object.keys(root._epUrlCache)
        if (ck.length >= 40)
            delete root._epUrlCache[ck[0]]
        root._epUrlCache[id] = { url: url, headers: headers, meta: meta }
    }
    // 在途协商:id -> true(防重复)。
    property var _pendingUrls: ({})
    // hook 等待应答:id -> true(moe-hook on_load 已 defer)。
    property var _wantedUrls: ({}) // itemId → { session: 会话键 }

    // 播放上下文进链:找下一集(跨季全集序列),存在则协商其播放地址。
    // 守卫用 seriesId(协商 meta 无 type 字段;Episode 才有 seriesId,电影为空)。
    function scheduleNextEpisode(meta) {
        if (!meta || meta.seriesId === "" || meta.serverUrl === "")
            return
        const model = EmbyClient.allEpisodesModelFor(meta.serverUrl,
                                              meta.accountId || root.currentAccountId,
                                              meta.seriesId)
        if (model.count === 0) {
            console.info("Main: 全集序列未就绪,拉取后进链", meta.seriesId)
            // 集详情直达(未经过剧集详情时全集序列尚未拉取):拉一次,
            // 等 allEpisodesReady 再进链;避免"找不到下一集"静默断链。
            const c0 = meta.accountId ? AccountManager.credsForAccount(meta.accountId)
                                                  : AccountManager.credsForServer(meta.serverUrl)
            if (c0.token !== "") {
                root._pendingChain = meta
                EmbyClient.fetchAllEpisodes(meta.serverUrl,
                                            meta.accountId || root.currentAccountId,
                                            c0.token, c0.userId, meta.seriesId)
            }
            return
        }
        let nextId = ""
        for (let i = 0; i < model.count; ++i) {
            const it = model.itemAt(i)
            if (it.id === meta.itemId && i + 1 < model.count) {
                nextId = it.id
                break
            }
        }
        if (nextId) {
            console.debug("Main: 预取下集", nextId)
            root.fetchEpisodeUrl(nextId, meta.itemId) // 预取下集(命中 hook 时零等待)。
        } else {
            console.info("Main: 剧集末尾,无下一集", meta.itemId)
        }
    }

    // 协商任意集:缓存命中直接应答;否则发起(防重)。
    function fetchEpisodeUrl(id, sessionKey) {
        const meta = (sessionKey && root._sessionMeta[sessionKey]) || root._curMeta
        if (!meta || meta.serverUrl === "")
            return
        if (root._epUrlCache[id]) {
            console.debug("Main: 协商缓存命中", id)
            root.serveEpisodeUrl(id)
            return
        }
        if (root._pendingUrls[id]) {
            console.debug("Main: 协商在途,防重跳过", id)
            return
        }
        root._pendingUrls[id] = true
        // 凭据按会话账号(accountId 优先;缺省才回退服务器首个有效账号)。
        const c = meta.accountId ? AccountManager.credsForAccount(meta.accountId)
                                 : AccountManager.credsForServer(meta.serverUrl)
        if (c.token === "") {
            console.warn("Main: 协商凭据缺失,放行占位", id)
            delete root._pendingUrls[id]
            if (root._wantedUrls[id]) {
                const w = root._wantedUrls[id]
                delete root._wantedUrls[id]
                MpvClient.deliverEpisodeUrl(w.session, id, "", [], {})
            }
            return
        }
        console.debug("Main: 发起协商", id)
        // -1,-1:轨道不锁请求(默认协商);选择延续在响应后按 ordinal 覆盖。
        EmbyClient.fetchPlaybackInfo(meta.serverUrl, c.token, c.userId, id,
                                     "", meta.seriesId, -1, -1)
    }

    // hook 等待应答:有缓存立刻回发(含外挂字幕 URL),没有则去协商。
    function serveEpisodeUrl(id, sessionKey) {
        const e = root._epUrlCache[id]
        if (!e) {
            root.fetchEpisodeUrl(id, sessionKey)
            return
        }
        if (root._wantedUrls[id]) {
            console.debug("Main: 应答 hook", id)
            const w = root._wantedUrls[id]
            delete root._wantedUrls[id]
            MpvClient.deliverEpisodeUrl(w.session, id, e.url, e.headers, e.meta,
                                        e.meta.selectedSubtitleUrl || "")
        }
    }

    // 全集标题表进入 mpv 播放列表(m3u:第 0 条 = 当前集真 URL + 旋转占位)。
    // 当前集 URL 取共享缓存(prime/交付恒缓存)。返回是否建成。
    function syncEpisodeList(meta) {
        if (!meta || meta.seriesId === "" || meta.serverUrl === "")
            return false
        const model = EmbyClient.allEpisodesModelFor(meta.serverUrl,
                                              meta.accountId || root.currentAccountId,
                                              meta.seriesId)
        if (model.count === 0) {
            console.info("Main: 全集模型未就绪,播放列表待建")
            return false // 模型未就绪(_pendingChain 兜底重拉)
        }
        const list = []
        let idx = -1
        for (let i = 0; i < model.count; ++i) {
            const it = model.itemAt(i)
            list.push({ id: it.id, title: it.name })
            if (it.id === meta.itemId)
                idx = i
        }
        if (idx < 0) {
            console.warn("Main: 当前集不在全集序列", meta.itemId)
            return false
        }
        const e = root._epUrlCache[meta.itemId]
        console.info("Main: 灌入播放列表", list.length, "条,当前集", meta.itemId)
        MpvClient.setEpisodeList(list, (meta.accountId ? meta.accountId + "|" : "") + meta.itemId, idx,
                                 e ? e.url : "", e ? e.headers : [],
                                 e ? e.meta : {})
        return true
    }

    // 主窗口关闭:外部 mpv 子进程随 MpvClient 析构一并终止,应用直接退出。
    onClosing: function (close) {
        close.accepted = true
        Qt.quit()
    }

    // 通知当前页面重拉(Detail/Library 各自实现 refreshAfterPlayback)。
    // qmllint disable missing-property
    // stackView.currentItem 静态类型为 Item,压入页面的自定义成员
    // (refreshAfterPlayback/isDetailPage)无法静态推导;typeof 守卫与
    // 短路判空下运行时安全,屏蔽该误报。
    function refreshCurrentAfterPlayback() {
        const cur = stackView.currentItem
        if (cur && typeof cur.refreshAfterPlayback === "function")
            cur.refreshAfterPlayback()
    }
    // qmllint enable missing-property

    // 播放结束(播完/出错/用户关窗;外部 mpv 进程与内嵌 libmpv 两后端
    // 都经此信号):重拉当前页面已看/进度。MpvClient = 统一后端单例。
    Connections {
        target: MpvClient
        // 内嵌播放(libmpv):每次播放开一个独立顶层窗口(多窗并发;
        // 窗口自管生命周期,关窗即停播,onClosed 自毁)。
        function onEmbeddedPlaybackRequested(meta) {
            console.info("Main: 内嵌播放窗口", meta.itemId)
            playerWinComp.createObject(root, { "meta": meta })
        }
        function onPlaybackFinished(sessionKey, itemId, error) {
            console.info("Main: 播放结束", itemId, "error:", error)
            root._listPrimed = false // 会话终结:下次起播(新剧)重建列表
            // 定点刷新刚播的那条历史(延后拉取与合并都在 AccountManager 内):
            // 历史页下次打开即是新时间,不必等整表刷新。账号/服务器取会话
            // 缓存里的 meta(无缓存时退回当前播放上下文)。
            const e = root._epUrlCache[itemId]
            delete root._epUrlCache[itemId] // 取完即清:播过的协商结果不再复用
            const m = e && e.meta ? e.meta : root._curMeta
            if (m && m.serverUrl && m.accountId)
                AccountManager.refreshHistoryItem(m.serverUrl, m.accountId, itemId)
            root.refreshCurrentAfterPlayback()
        }
        function onPlaybackContextChanged(meta) {
            console.info("Main: 切集", meta.itemId)
            root._curMeta = meta
            if (meta.itemId)
                root._sessionMeta[meta.itemId] = meta
            root._curAudioOrdinal = meta.selectedAudioOrdinal
            root._curSubtitleOrdinal = meta.selectedSubtitleOrdinal
            root._curSubtitleUrl = meta.selectedSubtitleUrl || ""
            // 全集入播放列表:仅首次/直达边缘补建一次(重复 replace 会
            // 引发重启循环)。
            if (!root._listPrimed)
                root._listPrimed = root.syncEpisodeList(meta)
            root.scheduleNextEpisode(meta) // 预取下一集
        }
        // 播放列表面板点集/上/下集 → mpv on_load hook 请求真实地址。
        function onEpisodeUrlRequested(sessionKey, itemId) {
            console.info("Main: hook 请求集", itemId)
            root._wantedUrls[itemId] = { session: sessionKey }
            root.serveEpisodeUrl(itemId, sessionKey)
        }
    }
    // 连播协商响应(与 Detail 的主动播放协商并存:按在途缓存区分)。
    Connections {
        target: EmbyClient
        function onAllEpisodesReady(serverUrl, accountId, seriesId) {
            // 集详情直达场景:全集序列就绪后重试进链/重排列表。
            if (root._pendingChain && root._pendingChain.serverUrl === serverUrl
                && root._pendingChain.seriesId === seriesId) {
                console.info("Main: 全集就绪,重建连播链")
                const m = root._pendingChain
                root._pendingChain = null
                // 仅未建成时建(任一分支建成后 _listPrimed=true,防重复 replace)。
                if (!root._listPrimed)
                    root._listPrimed = root.syncEpisodeList(m)
                root.scheduleNextEpisode(m)
            }
            // 挂起的起播交付(直达集详情,模型就绪后建列表再播)。
            if (root._deliverPending) {
                console.info("Main: 全集就绪,交付起播")
                root._deliverPending = false
                const meta = root._deliverMeta
                root._deliverMeta = null
                if (meta && meta.serverUrl === serverUrl && meta.seriesId !== "") {
                    const e = root._epUrlCache[meta.itemId]
                    if (e) {
                        // setEpisodeList 成功 = listSet,deliver 内部跳过
                        // loadfile(播放列表已播第 0 条);失败 = 兜底单条。
                        if (!root._listPrimed)
                            root._listPrimed = root.syncEpisodeList(meta)
                        MpvClient.deliver(e.url, e.headers, e.meta)
                    }
                }
            }
        }
        function onPlaybackReady(serverUrl, url, headers, meta) {
            const id = meta.itemId
            if (!root._pendingUrls[id])
                return
            delete root._pendingUrls[id]
            const m = Object.assign({}, meta)
            // 延续当前选择:音轨/内封字幕按同类序号下推(-2 显式关保留);
            // 当前集用外挂字幕时字幕不覆盖,用协商默认(URL 逐集不同)。
            if (m.selectedAudioOrdinal !== undefined)
                m.selectedAudioOrdinal = root._curAudioOrdinal
            if (m.selectedSubtitleOrdinal !== undefined && root._curSubtitleUrl === "")
                m.selectedSubtitleOrdinal = root._curSubtitleOrdinal
            m.type = "Episode"
            // 账号随协商结果下推(playbackReady 的 meta 不含 accountId):占位集
            // 的连播/续链/全季拉取都要按账号定位,不能只在首集带。
            if (!m.accountId)
                m.accountId = root._playAccountId || root.currentAccountId
            console.info("Main: 协商就绪入缓存", id)
            root.cacheEpisodeUrl(id, url, headers, m)
            root.serveEpisodeUrl(id, "")
        }
        function onPlaybackFailed(serverUrl, itemId, message) {
            // 协商失败:hook 若在等,放行占位(加载失败,mpv 跳过该条)。
            if (root._pendingUrls[itemId]) {
                console.warn("Main: 协商失败,放行占位", itemId, message)
                delete root._pendingUrls[itemId]
                if (root._wantedUrls[itemId]) {
                    const w = root._wantedUrls[itemId]
                    delete root._wantedUrls[itemId]
                    MpvClient.deliverEpisodeUrl(w.session, itemId, "", [], {})
                }
            }
        }
    }

    // 打开详情页:记录浏览服务器与账号(全局搜索路由),防抖在调用方。
    function pushDetail(itemId, posterId, title, serverUrl, accountId) {
        if (serverUrl)
            root.currentServerUrl = serverUrl
        if (accountId)
            root.currentAccountId = accountId
        stackView.push(detailPage, {
            itemId: itemId,
            posterId: posterId,
            title: title,
            serverUrl: serverUrl || root.currentServerUrl,
            accountId: accountId || root.currentAccountId
        })
    }
    // 打开播放历史页(数据层是全账号聚合,无需服务器/账号参数)。
    function pushHistory() {
        stackView.push(historyPage)
    }
    // 打开媒体库页:记录浏览服务器与账号。
    function toggleSearch() {
        if (searchOverlay.visible) {
            searchOverlay.close()
            return
        }
        // 搜索目标由浮窗内「目标」下拉决定(默认全部),与页面上下文无关。
        searchOverlay.open()
    }
    function pushLibrary(viewId, serverUrl, viewName, accountId) {
        if (serverUrl)
            root.currentServerUrl = serverUrl
        if (accountId)
            root.currentAccountId = accountId
        stackView.push(libraryPage, {
            initialViewId: viewId || "",
            initialViewName: viewName || "",
            serverUrl: serverUrl || root.currentServerUrl,
            accountId: accountId || root.currentAccountId,
            restore: root.libraryState || null
        })
    }

    background: ThemedBackground {}

    // ---- 页面转场:四档可选(ConfigManager.pageTransition),背景层不参与 ----
    // 曲线/位移取自各自的成体系做法(Material Shared Axis X / Kirigami / 纯淡 / iOS push);
    // iOS 档用 Easing.BezierSpline 精确复刻 iOS 16.3 帧拟合曲线(Qt 与 Flutter 的分段语义
    // 一致:按控制点 x 分段,故控制点可原样照搬),pop 方向为其镜像。
    QtObject {
        id: navTrans
        readonly property string kind: ConfigManager.pageTransition

        // 页面皆透明(露动画背景)⇒ 两页同时可见即"双重曝光"。故统一时序:
        // 旧页先淡出(前 ~40% 时长),新页在旧页退净后淡入;进入页第一帧用
        // PropertyAction 压到 opacity 0(否则暂停段会以原生 1 闪一帧)。
        // A. 横向轻移:新页 30px 滑入 + 后 70% 淡入;旧页前 30% 滑出淡出
        property Transition axIn: Transition {
            ParallelAnimation {
                NumberAnimation { property: "x"; from: 30; to: 0; duration: 230; easing.type: Easing.Bezier; easing.bezierCurve: [0.2, 0, 0, 1] }
                SequentialAnimation {
                    PropertyAction { property: "opacity"; value: 0 }
                    PauseAnimation { duration: 70 }
                    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 160 }
                }
            }
        }
        property Transition axOut: Transition {
            ParallelAnimation {
                NumberAnimation { property: "x"; from: 0; to: -30; duration: 70; easing.type: Easing.Bezier; easing.bezierCurve: [0.4, 0, 1, 1] }
                NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 70; easing.type: Easing.Bezier; easing.bezierCurve: [0.4, 0, 1, 1] }
            }
        }
        property Transition axPopIn: Transition {
            ParallelAnimation {
                NumberAnimation { property: "x"; from: -30; to: 0; duration: 230; easing.type: Easing.Bezier; easing.bezierCurve: [0.2, 0, 0, 1] }
                SequentialAnimation {
                    PropertyAction { property: "opacity"; value: 0 }
                    PauseAnimation { duration: 70 }
                    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 160 }
                }
            }
        }
        property Transition axPopOut: Transition {
            ParallelAnimation {
                NumberAnimation { property: "x"; from: 0; to: 30; duration: 70; easing.type: Easing.Bezier; easing.bezierCurve: [0.4, 0, 1, 1] }
                NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 70; easing.type: Easing.Bezier; easing.bezierCurve: [0.4, 0, 1, 1] }
            }
        }

        // B. 纵向上浮:旧页前 45% 淡出,新页随后自下方 40px 上滑淡入
        property Transition upIn: Transition {
            SequentialAnimation {
                PropertyAction { property: "opacity"; value: 0 }
                PauseAnimation { duration: 80 }
                ParallelAnimation {
                    NumberAnimation { property: "y"; from: 40; to: 0; duration: 120; easing.type: Easing.OutCubic }
                    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 120 }
                }
            }
        }
        property Transition upOut: Transition {
            NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 80; easing.type: Easing.InCubic }
        }
        property Transition upPopIn: Transition {
            SequentialAnimation {
                PropertyAction { property: "opacity"; value: 0 }
                PauseAnimation { duration: 80 }
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 120 }
            }
        }
        property Transition upPopOut: Transition {
            ParallelAnimation {
                NumberAnimation { property: "y"; from: 0; to: 40; duration: 80; easing.type: Easing.InCubic }
                NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 80; easing.type: Easing.InCubic }
            }
        }

        // C. 纯淡入淡出:先后淡化(非交叉),中段只余背景。时序对齐 Android
        property Transition fadeIn: Transition {
            SequentialAnimation {
                PropertyAction { property: "opacity"; value: 0 }
                PauseAnimation { duration: 105 }
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 195 }
            }
        }
        property Transition fadeOut: Transition {
            NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 105; easing.type: Easing.Bezier; easing.bezierCurve: [0.4, 0, 1, 1] }
        }
        property Transition fadePopIn: Transition {
            SequentialAnimation {
                PropertyAction { property: "opacity"; value: 0 }
                PauseAnimation { duration: 105 }
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 195 }
            }
        }
        property Transition fadePopOut: Transition {
            NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 105; easing.type: Easing.Bezier; easing.bezierCurve: [0.4, 0, 1, 1] }
        }

        // D. 横滑视差:旧页前 100ms 淡出(+左移 1/3 宽作视差),新页随后全宽滑入淡入
        property Transition iosIn: Transition {
            ParallelAnimation {
                NumberAnimation { property: "x"; from: stackView.width; to: 0; duration: 350; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.056, 0.024, 0.108, 0.3085, 0.198, 0.541, 0.3655, 1.0, 0.5465, 0.989, 1, 1] }
                SequentialAnimation {
                    PropertyAction { property: "opacity"; value: 0 }
                    PauseAnimation { duration: 100 }
                    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 250 }
                }
            }
        }
        property Transition iosOut: Transition {
            ParallelAnimation {
                NumberAnimation { property: "x"; from: 0; to: -stackView.width / 3; duration: 350; easing.type: Easing.Bezier; easing.bezierCurve: [0.35, 0.91, 0.33, 0.97] }
                NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 100; easing.type: Easing.InCubic }
            }
        }
        property Transition iosPopIn: Transition {
            ParallelAnimation {
                NumberAnimation { property: "x"; from: -stackView.width / 3; to: 0; duration: 350; easing.type: Easing.Bezier; easing.bezierCurve: [0.67, 0.03, 0.65, 0.09] }
                SequentialAnimation {
                    PropertyAction { property: "opacity"; value: 0 }
                    PauseAnimation { duration: 100 }
                    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 250 }
                }
            }
        }
        property Transition iosPopOut: Transition {
            ParallelAnimation {
                NumberAnimation { property: "x"; from: 0; to: stackView.width; duration: 350; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.4535, 0.011, 0.6345, 0.0, 0.802, 0.459, 0.892, 0.6915, 0.944, 0.976, 1, 1] }
                NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 100; easing.type: Easing.InCubic }
            }
        }
    }

    StackView {
        id: stackView
        anchors.fill: parent
        // 转场四档由配置选择,绑定在下方(背景层全程静止)。
        pushEnter: navTrans.kind === "axis_x" ? navTrans.axIn
                 : navTrans.kind === "slide_up" ? navTrans.upIn
                 : navTrans.kind === "ios_slide" ? navTrans.iosIn : navTrans.fadeIn
        pushExit: navTrans.kind === "axis_x" ? navTrans.axOut
                : navTrans.kind === "slide_up" ? navTrans.upOut
                : navTrans.kind === "ios_slide" ? navTrans.iosOut : navTrans.fadeOut
        popEnter: navTrans.kind === "axis_x" ? navTrans.axPopIn
                : navTrans.kind === "slide_up" ? navTrans.upPopIn
                : navTrans.kind === "ios_slide" ? navTrans.iosPopIn : navTrans.fadePopIn
        popExit: navTrans.kind === "axis_x" ? navTrans.axPopOut
               : navTrans.kind === "slide_up" ? navTrans.upPopOut
               : navTrans.kind === "ios_slide" ? navTrans.iosPopOut : navTrans.fadePopOut
        // 浮层可见时禁用页面:PosterCard 的点击用默认策略 TapHandler(按下不抢占
        // 手势,只有 MouseArea/ReleaseWithinBounds 才抢),浮层卡片的点击会同时
        // 命中页面同位置卡片,一次点击开出两个详情页(最小复现实测)。禁用后页面
        // 及其子项不参与输入;重新启用时 Qt 恢复原 activeFocus(实测),不丢焦点。
        enabled: !searchOverlay.visible && !settingsOverlay.visible
        initialItem: homePage
    }

    // 全局搜索浮层(Ctrl+K):按最近浏览的服务器搜索,结果点击进详情。
    SearchOverlay {
        id: searchOverlay
        anchors.fill: parent
        visible: false
        backgroundSource: stackView
        onShowDetail: function (itemId, posterId, title, serverUrl, accountId) {
            searchOverlay.close()
            // 聚合搜索:结果来自多账号,必须带结果所属账号(单服时为空,
            // 回退当前账号)。
            root.pushDetail(itemId, posterId, title, serverUrl, accountId || root.currentAccountId)
        }
    }
    // 设置浮层(Ctrl+, / 首页设置按钮):左分类右设置项的两级面板。
    SettingsOverlay {
        id: settingsOverlay
        anchors.fill: parent
        visible: false
        backgroundSource: stackView
    }

    // 鼠标返回层:后退侧键与中键左滑手势 = 返回(分发规则同 Alt+Left,
    // 见 goBack())。置顶只接中键/后退键,左键与滚轮原样穿透;文本框聚焦
    // 时中键放行(保留中键粘贴)。中键手势开关 = ConfigManager.mouseGesture,
    // 后退侧键不受开关影响。
    MouseArea {
        id: mouseNav
        anchors.fill: parent
        acceptedButtons: Qt.MiddleButton | Qt.BackButton
        property point pressPos: Qt.point(0, 0)
        property bool arming: false
        onPressed: (mouse) => {
            if (mouse.button === Qt.BackButton) {
                root.goBack()
                return
            }
            if (!ConfigManager.mouseGesture) {
                mouse.accepted = false
                return
            }
            // 中键粘贴让位:按压点落在文本框上时不接手本次按压。判定看
            // 光标下的框而非聚焦框——搜索浮层打开即聚焦其输入框,按聚焦
            // 判会让浮层上的手势全灭。
            if (root.textInputAt(mouse.x, mouse.y)) {
                mouse.accepted = false
                return
            }
            pressPos = Qt.point(mouse.x, mouse.y)
            arming = true
        }
        onPositionChanged: (mouse) => {
            if (!arming)
                return
            var px = (pressPos.x - mouse.x) / 80
            var py = (pressPos.y - mouse.y) / 80
            if (px >= py) {
                gestureHint.arrow = "‹"
                gestureHint.progress = Math.min(1, px)
            } else {
                gestureHint.arrow = "↑"
                gestureHint.progress = Math.min(1, py)
            }
        }
        onReleased: (mouse) => {
            if (mouse.button !== Qt.MiddleButton || !arming)
                return
            arming = false
            gestureHint.progress = 0
            var dx = mouse.x - pressPos.x
            var dy = mouse.y - pressPos.y
            if (dx <= -80 && Math.abs(dx) > 2 * Math.abs(dy))
                root.goBack()
            else if (dy <= -80 && Math.abs(dy) > 2 * Math.abs(dx))
                stackView.pop(null)
        }
        onCanceled: {
            arming = false
            gestureHint.progress = 0
        }
    }

    // 按压点最深子项是否为文本输入框(沿 childAt 逐层下探,跳过
    // mouseNav/gestureHint/focusGuard 观察层)。手势粘贴让位与点外
    // 失焦共用。
    function textInputAt(x, y) {
        let item = null
        const kids = root.contentItem.children
        for (let i = kids.length - 1; i >= 0; --i) {
            const k = kids[i]
            if (k === mouseNav || k === gestureHint || k === focusGuard || !k.visible)
                continue
            if (x >= k.x && x < k.x + k.width && y >= k.y && y < k.y + k.height) {
                item = k
                break
            }
        }
        while (item) {
            if (item instanceof TextInput || item instanceof TextEdit
                || item instanceof TextField || item instanceof TextArea)
                return true
            const p = item.mapFromItem(root.contentItem, x, y)
            const child = item.childAt(p.x, p.y)
            if (!child)
                break
            item = child
        }
        return false
    }

    // 文本框点外失焦(Qt Quick 无内建"点外失焦";官方焦点文档的惯用法 =
    // 按压落在文本框外时让惰性容器 contentItem 接管焦点)。本层置顶观察
    // 所有按压但一律拒收(mouse.accepted=false),事件原样穿透到下层。
    // Popup 在 Overlay 层(本层之上)——点下拉项不收焦点,选中逻辑正常。
    MouseArea {
        id: focusGuard
        anchors.fill: parent
        onPressed: (mouse) => {
            const f = root.activeFocusItem
            if (f && (f instanceof TextInput || f instanceof TextEdit
                      || f instanceof TextField || f instanceof TextArea)
                    && !root.textInputAt(mouse.x, mouse.y))
                root.contentItem.forceActiveFocus()
            mouse.accepted = false
        }
    }

    // 中键手势提示:左缘箭头随滑动进度淡入,满格即达触发阈值。
    // 箭头方向 = 当前主导手势(‹ 返回 / ↑ 回首页)。
    Rectangle {
        id: gestureHint
        property real progress: 0
        property string arrow: "‹"
        visible: progress > 0
        opacity: progress
        anchors.left: parent.left
        anchors.leftMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        width: 40
        height: 64
        radius: 20
        color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.85)
        NavGlyph {
            anchors.centerIn: parent
            dir: gestureHint.arrow === "‹" ? 0 : 2
            onAccent: true
            width: 22
            height: 22
        }
    }

    // 首页:每行一库聚合(库海报进媒体库,条目进详情)。
    Component {
        id: homePage
        Home {
            onShowDetail: function (itemId, posterId, title, serverUrl, accountId) {
                root.pushDetail(itemId, posterId, title, serverUrl, accountId)
            }
            onOpenLibrary: function (viewId, serverUrl, viewName, accountId) {
                root.pushLibrary(viewId, serverUrl, viewName, accountId)
            }
            onOpenServerManager: stackView.push(serverManagerPage)
            onOpenSettings: settingsOverlay.visible ? settingsOverlay.close() : settingsOverlay.open()
            onOpenSearch: root.toggleSearch()
            onOpenHistory: root.pushHistory()
        }
    }

    // 播放历史页:条目点击进详情(带结果所属服务器与账号)。
    Component {
        id: historyPage
        PlaybackHistoryPage {
            onShowDetail: function (itemId, posterId, title, serverUrl, accountId) {
                root.pushDetail(itemId, posterId, title, serverUrl, accountId)
            }
        }
    }

    Component {
        id: playerWinComp
        PlayerWindow {}
    }

    Component {
        id: libraryPage
        Library {
            onBrowseHome: function (name) {
                Qt.callLater(function () {
                    root.homeFilterText = name
                    stackView.pop(null)
                })
            }
            onPlayRequested: function (url, headers, meta) {
                MpvClient.start(url, headers, meta)
            }
            // 离开媒体库页(返回首页等)时保存浏览状态供下次恢复。
            onLibraryStateSaved: function (state) {
                root.libraryState = state
            }
            onShowDetail: function (itemId, posterId, title, serverUrl, accountId) {
                // 双击卡片会连发两次 showDetail,已打开详情页时忽略,避免叠出双实例。
                // 同 refreshCurrentAfterPlayback:currentItem 动态类型,短路判空下安全。
                // qmllint disable missing-property
                if (stackView.currentItem && stackView.currentItem.isDetailPage)
                    return
                // qmllint enable missing-property
                root.pushDetail(itemId, posterId, title, serverUrl, accountId)
            }
        }
    }
    Component {
        id: detailPage
        Detail {
            onPlayWindowRequested: function (meta) {
                root._playAccountId = meta.accountId || ""
                MpvClient.startPending(meta)
            }
            onPlaybackDelivered: function (url, headers, meta) {
                // 交付 meta 补账号(见 _playAccountId):后续连播/续链据此定位。
                if (root._playAccountId !== "" && !meta.accountId)
                    meta.accountId = root._playAccountId
                // 当前集 URL/头/元数据无条件入共享缓存(hook 应答/补建路径用)。
                root.cacheEpisodeUrl(meta.itemId, url, headers, meta)
                // 剧集:全集标题入 mpv 播放列表(占位,m3u EXTINF 标题),deliver
                // 后按当前集索引开播 → on_load hook 重定向真实地址;所有条目
                // 标题一致。电影/无序列:直接 deliver。
                if (meta.seriesId && meta.seriesId !== "") {
                    const model = EmbyClient.allEpisodesModelFor(meta.serverUrl,
                                              meta.accountId || root.currentAccountId,
                                              meta.seriesId)
                    if (model.count > 0) {
                        const list = []
                        let idx = -1
                        for (let i = 0; i < model.count; ++i) {
                            const it = model.itemAt(i)
                            list.push({ id: it.id, title: it.name })
                            if (it.id === meta.itemId)
                                idx = i
                        }
                        if (idx >= 0) {
                            // 当前集 URL 一并传 setEpisodeList(第 0 条真 URL)。
                            MpvClient.setEpisodeList(list, (meta.accountId ? meta.accountId + "|" : "") + meta.itemId, idx,
                                                     url, headers, meta)
                            root._listPrimed = true
                            MpvClient.deliver(url, headers, meta)
                            return
                        }
                    }
                    // 模型未就绪(集详情直达):建列表前挂起交付,等
                    // allEpisodesReady 后建列表再播(避免单条回落)。
                    root._deliverPending = true
                    root._deliverMeta = meta
        // 凭据按会话账号(accountId 优先;缺省才回退服务器首个有效账号)。
        const c = meta.accountId ? AccountManager.credsForAccount(meta.accountId)
                                 : AccountManager.credsForServer(meta.serverUrl)
                    if (c.token !== "")
                        EmbyClient.fetchAllEpisodes(meta.serverUrl,
                                                    meta.accountId || root.currentAccountId,
                                                    c.token, c.userId, meta.seriesId)
                    return
                }
                MpvClient.deliver(url, headers, meta)
            }
            onPlaybackFailed: function (itemId, message) {
                MpvClient.fail(itemId, message)
            }
        }
    }

    // 服务器管理页(Ctrl+O):展示已保存的 Emby 服务器,拖动排序。
    Component {
        id: serverManagerPage
        ServerManager {
            // 点服务器卡 = 回首页并把该服显示名注入首页过滤框。
            onBrowseHome: function (serverUrl, accountId, name) {
                root.homeFilterText = name
                stackView.pop(null)
            }
        }
    }

    // Alt+Left 的返回分发:浮层先关(优先级与 Esc 相同,但不穿透到下面的页面),
    // 其次给当前页的页内层级(如详情页的 集→父剧 / 浏览历史链)消费,最后才退页面栈。
    // 页内契约:页面可选实现 goBack() -> bool(返回是否已消费)。
    // 注意 Esc 不走这里:Esc 只关浮层(页面内 Esc 另有"清输入/关下拉"语义)。
    function goBack() {
        if (settingsOverlay.visible) {
            settingsOverlay.close()
            return;
        }
        if (searchOverlay.visible) {
            searchOverlay.close()
            return;
        }
        const cur = stackView.currentItem
        if (cur && typeof cur.goBack === "function" && cur.goBack())
            return;
        if (stackView.depth > 1)
            stackView.pop();
    }

    // 快捷键:键位可在设置「快捷键」分类改(config.toml [shortcut] 段),
    // | 分隔多键位,修改即时生效。返回键分发规则见 goBack()。
    function shortcutSeq(value) {
        return String(value).split("|").filter(function (s) { return s !== "" })
    }
    Shortcut {
        sequences: shortcutSeq(ConfigManager.shortcutBack)
        onActivated: root.goBack()
    }
    // 回首页清栈:pop 到根(initialItem);已在首页时无操作。
    Shortcut {
        sequences: shortcutSeq(ConfigManager.shortcutHome)
        onActivated: stackView.pop(null)
    }
    Shortcut {
        sequences: shortcutSeq(ConfigManager.shortcutServerManager)
        onActivated: stackView.push(serverManagerPage)
    }
    Shortcut {
        sequences: shortcutSeq(ConfigManager.shortcutSettings)
        onActivated: settingsOverlay.visible ? settingsOverlay.close() : settingsOverlay.open()
    }
    Shortcut {
        sequences: shortcutSeq(ConfigManager.shortcutSearch)
        onActivated: root.toggleSearch()
    }
    // 临时露出隐藏项(仅本次运行,见 AccountManager.showHidden)。
    Shortcut {
        sequences: shortcutSeq(ConfigManager.shortcutRevealHidden)
        onActivated: AccountManager.showHidden = !AccountManager.showHidden
    }
    // Esc 收敛到主窗口单一处理器:两个浮层各自注册同键 Esc 会在
    // QShortcutMap 里按注册顺序冲突(先注册的 SearchOverlay 覆盖 SettingsOverlay)。
    Shortcut {
        sequences: ["Esc"]
        onActivated: {
            if (settingsOverlay.visible)
                settingsOverlay.close()
            else if (searchOverlay.visible)
                searchOverlay.close()
        }
    }
}
