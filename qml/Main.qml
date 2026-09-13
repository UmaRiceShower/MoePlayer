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
    // 在途协商:id -> true(防重复)。
    property var _pendingUrls: ({})
    // hook 等待应答:id -> true(moe-hook on_load 已 defer)。
    property var _wantedUrls: ({})

    // 播放上下文进链:找下一集(跨季全集序列),存在则协商其播放地址。
    // 守卫用 seriesId(协商 meta 无 type 字段;Episode 才有 seriesId,电影为空)。
    function scheduleNextEpisode(meta) {
        if (!meta || meta.seriesId === "" || meta.serverUrl === "")
            return
        const model = EmbyClient.allEpisodesModelFor(meta.serverUrl)
        if (model.count === 0) {
            console.info("Main: 全集序列未就绪,拉取后进链", meta.seriesId)
            // 集详情直达(未经过剧集详情时全集序列尚未拉取):拉一次,
            // 等 allEpisodesReady 再进链;避免"找不到下一集"静默断链。
            const c0 = AccountManager.credsForServer(meta.serverUrl)
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
            root.fetchEpisodeUrl(nextId) // 预取下集(命中 hook 时零等待)。
        } else {
            console.info("Main: 剧集末尾,无下一集", meta.itemId)
        }
    }

    // 协商任意集:缓存命中直接应答;否则发起(防重)。
    function fetchEpisodeUrl(id) {
        const meta = root._curMeta
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
        const c = AccountManager.credsForServer(meta.serverUrl)
        if (c.token === "") {
            console.warn("Main: 协商凭据缺失,放行占位", id)
            delete root._pendingUrls[id]
            if (root._wantedUrls[id]) {
                delete root._wantedUrls[id]
                MpvClient.deliverEpisodeUrl(id, "", [], {})
            }
            return
        }
        console.debug("Main: 发起协商", id)
        // -1,-1:轨道不锁请求(默认协商);选择延续在响应后按 ordinal 覆盖。
        EmbyClient.fetchPlaybackInfo(meta.serverUrl, c.token, c.userId, id,
                                     "", meta.seriesId, -1, -1)
    }

    // hook 等待应答:有缓存立刻回发(含外挂字幕 URL),没有则去协商。
    function serveEpisodeUrl(id) {
        const e = root._epUrlCache[id]
        if (!e) {
            root.fetchEpisodeUrl(id)
            return
        }
        if (root._wantedUrls[id]) {
            console.debug("Main: 应答 hook", id)
            delete root._wantedUrls[id]
            MpvClient.deliverEpisodeUrl(id, e.url, e.headers, e.meta,
                                        e.meta.selectedSubtitleUrl || "")
        }
    }

    // 全集标题表进入 mpv 播放列表(m3u:第 0 条 = 当前集真 URL + 旋转占位)。
    // 当前集 URL 取共享缓存(prime/交付恒缓存)。返回是否建成。
    function syncEpisodeList(meta) {
        if (!meta || meta.seriesId === "" || meta.serverUrl === "")
            return false
        const model = EmbyClient.allEpisodesModelFor(meta.serverUrl)
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
        MpvClient.setEpisodeList(list, meta.itemId, idx,
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

    // 外部 mpv 播放结束(播完/出错/用户关窗):重拉当前页面已看/进度。
    // MpvClient 是外部 mpv 进程后端(main.cpp 注册的单例)。
    Connections {
        target: MpvClient
        function onPlaybackFinished(itemId, error) {
            console.info("Main: 播放结束", itemId, "error:", error)
            root.refreshCurrentAfterPlayback()
        }
        function onPlaybackContextChanged(meta) {
            console.info("Main: 切集", meta.itemId)
            root._curMeta = meta
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
        function onEpisodeUrlRequested(itemId) {
            console.info("Main: hook 请求集", itemId)
            root._wantedUrls[itemId] = true
            root.serveEpisodeUrl(itemId)
        }
    }
    // 连播协商响应(与 Detail 的主动播放协商并存:按在途缓存区分)。
    Connections {
        target: EmbyClient
        function onAllEpisodesReady(serverUrl) {
            // 集详情直达场景:全集序列就绪后重试进链/重排列表。
            if (root._pendingChain && root._pendingChain.serverUrl === serverUrl) {
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
            root._epUrlCache[id] = { url: url, headers: headers, meta: m }
            root.serveEpisodeUrl(id)
        }
        function onPlaybackFailed(serverUrl, itemId, message) {
            // 协商失败:hook 若在等,放行占位(加载失败,mpv 跳过该条)。
            if (root._pendingUrls[itemId]) {
                console.warn("Main: 协商失败,放行占位", itemId, message)
                delete root._pendingUrls[itemId]
                if (root._wantedUrls[itemId]) {
                    delete root._wantedUrls[itemId]
                    MpvClient.deliverEpisodeUrl(itemId, "", [], {})
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

    background: MoeBackground {}

    StackView {
        id: stackView
        anchors.fill: parent
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
    // 设置浮层(Ctrl+S / 首页设置按钮):左分类右设置项的两级面板。
    SettingsOverlay {
        id: settingsOverlay
        anchors.fill: parent
        visible: false
        backgroundSource: stackView
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
        id: libraryPage
        Library {
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
                root._epUrlCache[meta.itemId] = { url: url, headers: headers, meta: meta }
                // 剧集:全集标题入 mpv 播放列表(占位,m3u EXTINF 标题),deliver
                // 后按当前集索引开播 → on_load hook 重定向真实地址;所有条目
                // 标题一致。电影/无序列:直接 deliver。
                if (meta.seriesId && meta.seriesId !== "") {
                    const model = EmbyClient.allEpisodesModelFor(meta.serverUrl)
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
                            MpvClient.setEpisodeList(list, meta.itemId, idx,
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
                    const c = AccountManager.credsForServer(meta.serverUrl)
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

    // 快捷键:返回首页 Ctrl+F,服务器管理 Ctrl+O,设置 Ctrl+S,搜索 Ctrl+K。
    // Alt+Left:统一在此注册(各页面不再自带);分发规则见 goBack()。
    Shortcut {
        sequences: ["Alt+Left"]
        onActivated: root.goBack()
    }
    Shortcut {
        sequences: ["Ctrl+F"]
        // pop 到根即返回首页(initialItem);已在首页时无操作。
        onActivated: stackView.pop(null)
    }
    Shortcut {
        sequences: ["Ctrl+O"]
        onActivated: stackView.push(serverManagerPage)
    }
    Shortcut {
        sequences: ["Ctrl+S"]
        onActivated: settingsOverlay.visible ? settingsOverlay.close() : settingsOverlay.open()
    }
    Shortcut {
        sequences: ["Ctrl+K"]
        onActivated: root.toggleSearch()
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
