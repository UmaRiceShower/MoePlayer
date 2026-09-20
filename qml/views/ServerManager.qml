pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import MoePlayer.Core

Item {
    id: root

    readonly property int cardW: Constants.serverCardW
    readonly property int cardH: Constants.serverCardH
    readonly property int iconSize: Constants.serverIconSize
    readonly property int gridSpacing: Constants.serverGridSpacing
    readonly property real hoverScale: Constants.serverHoverScale
    readonly property real expandHalf: root.cardW * (root.hoverScale - 1) / 2
    readonly property int moveDuration: Constants.serverMoveMs
    readonly property int dragDuration: Constants.serverDragMs
    readonly property int fadeDuration: Constants.serverFadeMs
    readonly property color hoverBorder: Qt.rgba(Theme.accent.r, Theme.accent.g,
                                                 Theme.accent.b, 0.5)
    property var acctCache: ({})
    property var folderCache: ({})
    readonly property var emptyAccount: ({ name: "", userName: "", serverUrl: "", authStatus: "", icon: "" })
    readonly property var emptyFolder: ({ name: "", color: "", accountIds: [] })
    property string hoveredKey: ""
    property string dropTargetKey: ""
    property string dragKey: ""
    property string pressKey: ""
    property bool dragActive: false
    readonly property int cellW: root.cardW + root.gridSpacing
    readonly property int cellH: root.cardH + root.gridSpacing
    readonly property int columns: Math.max(1, Math.floor(gridArea.width / root.cellW))
    property bool addOpen: false
    property bool adding: false
    property string errorMsg: ""
    property bool editOpen: false
    property int editActiveLine: 0
    property string editAccountId: ""
    property string editError: ""
    property var expandedFolders: []
    property bool folderOpen: false
    property string folderEditId: ""
    property string folderSelectedColor: ""
    readonly property int hoveredIndex: root.indexOfKey(root.hoveredKey)
    readonly property int hoveredCell: root.hoveredKey === "" ? -1 : root.hoveredIndex
    readonly property int hoveredRow: root.hoveredCell < 0
                                      ? -1 : Math.floor(root.hoveredCell / root.columns)

    function rowKeyOf(kind, id) { return kind + ":" + id }
    function kindOfKey(key) { return key.substring(0, key.indexOf(":")) }
    function idOfKey(key) { return key.substring(key.indexOf(":") + 1) }
    function desiredKeys() {
        const out = []
        const order = AccountManager.layoutOrder
        for (let i = 0; i < order.length; ++i) {
            const e = order[i]
            if (e.type === "folder") {
                if (!root.isFolderVisible(e.id))
                    continue // 文件夹隐藏:卡与成员都不显示(成员继承)
                out.push(root.rowKeyOf("folder", e.id))
                if (root.isFolderExpanded(e.id)) {
                    const ids = root.folderInfo(e.id).accountIds || []
                    for (let j = 0; j < ids.length; ++j)
                        if (root.isAccountVisible(ids[j]))
                            out.push(root.rowKeyOf("account", ids[j]))
                }
            } else if (root.isAccountVisible(e.id)) {
                out.push(root.rowKeyOf("account", e.id))
            }
        }
        return out
    }
    function rowObject(key) {
        if (key === "plus")
            return { key: "plus", kind: "plus", id: "" }
        return { key: key, kind: root.kindOfKey(key), id: root.idOfKey(key) }
    }
    function syncModel() {
        root.refreshDataCache()
        const want = ["plus"].concat(root.desiredKeys())
        for (let i = vmodel.count - 1; i >= 0; --i) {
            if (want.indexOf(vmodel.get(i).key) < 0)
                vmodel.remove(i)
        }
        for (let i = 0; i < want.length; ++i) {
            if (i >= vmodel.count) {
                vmodel.append(root.rowObject(want[i]))
                continue
            }
            if (vmodel.get(i).key === want[i])
                continue
            let from = -1
            for (let k = i + 1; k < vmodel.count; ++k) {
                if (vmodel.get(k).key === want[i]) {
                    from = k
                    break
                }
            }
            if (from < 0)
                vmodel.insert(i, root.rowObject(want[i]))
            else
                vmodel.move(from, i, 1)
        }
    }
    function refreshDataCache() {
        const accs = AccountManager.accounts
        const a = {}
        const prevA = root.acctCache
        for (const k in prevA)
            a[k] = prevA[k]
        for (let i = 0; i < accs.length; ++i)
            a[accs[i].id] = accs[i]
        root.acctCache = a
        const fs = AccountManager.folders
        const f = {}
        const prevF = root.folderCache
        for (const k in prevF)
            f[k] = prevF[k]
        for (let i = 0; i < fs.length; ++i)
            f[fs[i].id] = fs[i]
        root.folderCache = f
    }
    // 取数失败(行刚被移除、退场动画仍在跑)回字段齐全的空模板,
    // 卡体绑定不会求值到 undefined。
    function accountInfo(id) { return root.acctCache[id] || root.emptyAccount }
    function folderInfo(id) { return root.folderCache[id] || root.emptyFolder }

    // ---- 隐藏(见 AccountManager::hiddenChanged)----
    // 隐藏项默认不出现在本页/首页/搜索/历史;Alt+S(AccountManager.showHidden)
    // 打开时全部照常显示,此时卡片带"已隐藏"标识并压暗,便于找到再取消隐藏。
    // 生效判定唯一来源 = AccountManager(账号自身标志/文件夹继承/showHidden
    // 三者的组合都在 C++ 一处);本页只额外要"是否已隐藏"用于标识。
    function isAccountHidden(id) {
        const a = root.accountInfo(id)
        return a.hidden === true || a.hiddenByFolder === true
    }
    function isAccountVisible(id) { return AccountManager.accountVisible(id) }
    function isFolderHidden(id) { return root.folderInfo(id).hidden === true }
    // 文件夹卡"N 台服务器"与浮窗提示同口径:隐藏成员不计入(露出时全算)。
    function visibleMemberCount(folderId) {
        const ids = root.folderInfo(folderId).accountIds || []
        if (AccountManager.showHidden)
            return ids.length
        let n = 0
        for (let i = 0; i < ids.length; ++i)
            if (root.isAccountVisible(ids[i]))
                ++n
        return n
    }
    function isFolderVisible(id) { return AccountManager.showHidden || !root.isFolderHidden(id) }
    // 顶部计数按可见账号(露出模式下 = 全部)。
    readonly property int visibleAccountCount: {
        const accs = AccountManager.accounts
        let n = 0
        for (let i = 0; i < accs.length; ++i)
            if (root.isAccountVisible(accs[i].id))
                ++n
        return n
    }

    // key → 模型行号(-1 = 不存在)。
    function indexOfKey(key) {
        for (let i = 0; i < vmodel.count; ++i)
            if (vmodel.get(i).key === key)
                return i
        return -1
    }
    // hover 放大每侧的溢出量(与 cardW/cardH 同量级):横向 expandHalf、纵向
    // cardH*(hoverScale-1)/2;各加 4px 余量作为网格内容四周的留白,让放大和邻居
    // 让位都落在视图内部,不被视图裁剪。
    readonly property int hoverPadX: Math.ceil(root.expandHalf) + 4
    readonly property int hoverPadY: Math.ceil(root.cardH * (root.hoverScale - 1) / 2) + 4

    // hover 让位量:同排且非自身才偏移(卡体容器 x 绑定此值)。
    function shiftOfCell(cell) {
        if (root.hoveredCell < 0 || cell === root.hoveredCell)
            return 0
        if (Math.floor(cell / root.columns) !== root.hoveredRow)
            return 0
        return cell < root.hoveredCell ? -root.expandHalf : root.expandHalf
    }

    // 拖动归位
    function settleCardBodies() {
        for (let i = 0; i < vmodel.count; ++i) {
            const it = vgrid.itemAtIndex(i)
            if (!it || it.children.length === 0)
                continue
            const holder = it.children[0]
            for (let k = 0; k < holder.children.length; ++k) {
                const ch = holder.children[k]
                if (ch.accountId !== it.id && ch.folderId !== it.id)
                    continue
                if (typeof ch.settleBack !== "function")
                    continue
                ch.settleBack()
            }
        }
    }

    // 落点行:页面坐标 → 内容坐标 → 按格宽高取格(floor;格间隙归就近格),
    // 格位超出模型范围(末行之下、最右列之外)= null(空白)。
    // 不用 vgrid.indexAt():它要 contentItem 坐标,而由页面坐标映射出的视图
    // 坐标与内容坐标差 contentX/contentY(视图滚动后落点整体错位);且它只
    // 命中 delegate 矩形,格间隙与尾部返回 -1(拖到那就没有落点)。
    // 网格上方/左侧(标题栏那条、左留白)= 占位卡格位,即"移到最前"。
    function dropTargetAt(x, y) {
        if (vmodel.count === 0)
            return null
        const p = vgrid.contentItem.mapFromItem(root, x, y)
        // 卡体在格内偏移了 hoverPadX/hoverPadY(给 hover 放大留白),取格时补回来。
        const col = Math.floor((p.x - root.hoverPadX) / vgrid.cellWidth)
        const row = Math.floor((p.y - root.hoverPadY) / vgrid.cellHeight)
        // 网格上方/左侧(标题栏那条、留白外沿)= 占位卡格位,即"移到最前"。
        if (col < 0 || row < 0)
            return { kind: "plus", id: "", key: "plus" }
        if (col >= root.columns || row >= Math.ceil(vmodel.count / root.columns))
            return null
        const r = vmodel.get(Math.min(row * root.columns + col, vmodel.count - 1))
        return { kind: r.kind, id: r.id, key: r.key }
    }

    function clearDropTarget() { root.dropTargetKey = "" }

    // 落点判定(拖动过程中):与最终 drop 语义一致,只有"有意义的落点"才
    // 高亮(无操作不高亮)。
    function updateDropTarget(drop) {
        if (ConfigManager.serverManagerView === "tree") {
            root.updateTreeDropTarget(drop.x, drop.y)
            return
        }
        const fromKind = root.kindOfKey(root.pressKey)
        const fromId = root.idOfKey(root.pressKey)
        let next = ""
        if (fromKind !== "" && fromId !== "") {
            const t = root.dropTargetAt(drop.x, drop.y)
            // 占位卡行(格 0)= 移到最前,与拖到空白区分不了高亮,不预高亮。
            if (t && t.kind !== "plus" && t.key !== root.pressKey) {
                if (fromKind === "folder") {
                    // 文件夹:落点另一文件夹卡 = 排序;落点账号卡 = 跨类排序
                    // (本夹成员是无操作,不高亮)。
                    if (t.kind === "folder")
                        next = t.key
                    else if (AccountManager.folderIdOfAccount(t.id) !== fromId)
                        next = t.key
                } else {
                    const fromFolder = AccountManager.folderIdOfAccount(fromId)
                    if (t.kind === "folder") {
                        if (fromFolder !== t.id)
                            next = t.key
                    } else if (fromId !== t.id) {
                        next = t.key
                    }
                }
            }
        }
        // 只在目标真变时赋值:每次鼠标移动都 ""→key 抖动会让所有卡重算绑定。
        if (next !== root.dropTargetKey)
            root.dropTargetKey = next
    }

    // 落下:执行重排 / 加入文件夹 / 拖出。语义与原实现一致——账号:同上下文
    // 排序、落到文件夹卡或成员卡 = 加入/转移、落到空白 = 拖出;文件夹:落点
    // 文件夹或账号卡 = 排序,空白 = 不动。
    function applyDrop(x, y) {
        if (ConfigManager.serverManagerView === "tree") {
            root.applyTreeDrop(x, y)
            return
        }
        const fromKind = root.kindOfKey(root.pressKey)
        const fromId = root.idOfKey(root.pressKey)
        if (fromKind === "" || fromId === "")
            return
        const t = root.dropTargetAt(x, y)
        if (fromKind === "folder") {
            if (AccountManager.folders.findIndex(f => f.id === fromId) < 0)
                return
            if (!t)
                return
            if (t.kind === "plus") {
                // 占位卡位(首格):文件夹移到最前。
                root.moveLayoutElement("folder", fromId, "", "")
                return
            }
            if (t.kind === "folder") {
                if (t.id !== fromId)
                    root.moveLayoutElement("folder", fromId, "folder", t.id)
                return
            }
            if (AccountManager.folderIdOfAccount(t.id) !== fromId)
                root.moveLayoutElement("folder", fromId, "account", t.id)
            return
        }
        if (AccountManager.accounts.findIndex(a => a.id === fromId) < 0)
            return
        const fromFolder = AccountManager.folderIdOfAccount(fromId)
        if (!t || t.kind === "plus") {
            // 空白 / 占位卡格位:文件夹成员 = 拖出(回到未分组区末尾);
            // 未分组账号 = 占位卡格位算"移到最前",纯空白算"移到末尾"。
            if (fromFolder !== "")
                AccountManager.removeAccountFromFolder(fromId)
            else if (t)
                root.moveLayoutElement("account", fromId, "", "")
            else
                root.moveLayoutElement("account", fromId, "@end", "")
            return
        }
        if (t.kind === "folder") {
            if (fromFolder !== t.id)
                AccountManager.addAccountToFolder(t.id, fromId)
            return
        }
        const toFolder = AccountManager.folderIdOfAccount(t.id)
        if (fromFolder === toFolder) {
            if (fromId === t.id)
                return
            if (fromFolder === "")
                root.moveLayoutElement("account", fromId, "account", t.id)
            else
                AccountManager.moveAccountInFolder(fromFolder, fromId, t.id)
            return
        }
        if (toFolder !== "") {
            AccountManager.addAccountToFolder(toFolder, fromId)
        } else {
            AccountManager.removeAccountFromFolder(fromId)
            root.moveLayoutElement("account", fromId, "account", t.id)
        }
    }

    // 跨类排序统一入口:把视觉元素(type/id)移到 beforeType/beforeId 之前
    // (移除后插入),提交 AccountManager.setLayoutOrder 统一规范化 + 重排
    // accounts/folders + 持久化。beforeType 空 = 移到最前(占位卡格位);
    // 目标不在序列中 = 移到末尾(调用方以 "@end" 哨兵表达"移到末尾")。
    function moveLayoutElement(type, id, beforeType, beforeId) {
        const order = JSON.parse(JSON.stringify(AccountManager.layoutOrder))
        const from = order.findIndex(e => e.type === type && e.id === id)
        if (from < 0)
            return
        const toOrig = beforeType === "" ? -1
                     : order.findIndex(e => e.type === beforeType && e.id === beforeId)
        order.splice(from, 1)
        let to = 0
        if (beforeType !== "") {
            to = order.findIndex(e => e.type === beforeType && e.id === beforeId)
            if (to < 0)
                to = order.length
            else if (toOrig > from)
                to += 1
        }
        order.splice(to, 0, { type: type, id: id })
        AccountManager.setLayoutOrder(order)
    }

    // 新建文件夹的插入目标(layoutOrder 的 before 语义;"@end"= 末尾)。
    function folderInsertTarget(x, y) {
        const t = root.dropTargetAt(x, y)
        if (!t)
            return { beforeType: "@end", beforeId: "" }
        if (t.kind === "plus")
            return { beforeType: "", beforeId: "" } // 最前
        // 展开文件夹的「末尾」= layoutOrder 中该夹的后继元素之前。
        if (t.kind === "folder")
            return root.isFolderExpanded(t.id) ? root.folderInsertTargetAfterFolder(t.id)
                                               : { beforeType: "folder", beforeId: t.id }
        const f = AccountManager.folderIdOfAccount(t.id)
        if (f !== "" && root.isFolderExpanded(f))
            return root.folderInsertTargetAfterFolder(f)
        return { beforeType: "account", beforeId: t.id }
    }
    // 树状模式的新建落点:行上 = 该元素之前(展开文件夹行/成员行 = 夹
    // 末尾);行间边界 = 边界吸附后的位置。
    function folderInsertTargetTree(x, y) {
        const t = root.treeDropAt(x, y)
        if (!t)
            return { beforeType: "@end", beforeId: "" }
        if (t.zone === "boundary")
            return root.boundaryToLayout(t.boundary)
        if (t.kind === "plus")
            return { beforeType: "", beforeId: "" }
        if (t.kind === "folder")
            return root.isFolderExpanded(t.id) ? root.folderInsertTargetAfterFolder(t.id)
                                               : { beforeType: "folder", beforeId: t.id }
        const f = AccountManager.folderIdOfAccount(t.id)
        if (f !== "" && root.isFolderExpanded(f))
            return root.folderInsertTargetAfterFolder(f)
        return { beforeType: "account", beforeId: t.id }
    }
    function createFolderAt(x, y) {
        const tgt = ConfigManager.serverManagerView === "tree"
                    ? root.folderInsertTargetTree(x, y) : root.folderInsertTarget(x, y)
        const newId = AccountManager.addFolder("", "") // 空名自动命名 + 随机预设色
        if (newId === "")
            return
        root.moveLayoutElement("folder", newId, tgt.beforeType, tgt.beforeId)
        root.openFolderDialog(newId) // 直接命名
    }

    // ---- 树状(长条)视图的拖拽落点 ----
    // 线性序列:行高 root.treeRowH + 间距 root.treeRowGap。落点 =
    // 「行间边界 b ∈ [0..N]」(半行判定)+ 「文件夹行区」(账号落到文件夹行
    // = 入夹)。指示线经 dropInsertY(内容坐标)画出。
    readonly property int treeRowH: 44
    readonly property int treeRowGap: 6
    readonly property int treeRowPitch: treeRowH + treeRowGap

    function treeDropAt(x, y) {
        if (vmodel.count === 0)
            return null
        const p = treeList.contentItem.mapFromItem(root, x, y)
        const f = (p.y + root.treeRowGap / 2) / root.treeRowPitch
        let b = Math.floor(f) // 行号
        const frac = f - b
        if (b < 0)
            b = 0
        if (b >= vmodel.count)
            return { zone: "boundary", boundary: vmodel.count }
        const r = vmodel.get(b)
        if (frac < 0.35)
            return { zone: "boundary", boundary: b }
        if (frac > 0.65)
            return { zone: "boundary", boundary: b + 1 }
        return { zone: "row", key: r.key, kind: r.kind, id: r.id, index: b }
    }

    // 边界 b → layoutOrder 的 before 语义(文件夹拖拽/未分组账号用)。
    // 成员行边界吸附到其夹的边界:首成员之前 = 夹之后(不允许进夹)。
    function boundaryToLayout(b) {
        if (b <= 0)
            return { beforeType: "", beforeId: "" } // 最前
        if (b >= vmodel.count)
            return { beforeType: "@end", beforeId: "" }
        const r = vmodel.get(b)
        if (r.kind === "plus")
            return { beforeType: "", beforeId: "" }
        if (r.kind === "folder")
            return { beforeType: "folder", beforeId: r.id }
        const f = AccountManager.folderIdOfAccount(r.id)
        if (f === "")
            return { beforeType: "account", beforeId: r.id }
        // 成员行:吸附到其夹之后(= 夹的 layoutOrder 后继之前)
        return root.folderInsertTargetAfterFolder(f)
    }
    function folderInsertTargetAfterFolder(fid) {
        const order = AccountManager.layoutOrder
        for (let i = 0; i < order.length; ++i) {
            if (order[i].type === "folder" && order[i].id === fid) {
                if (i + 1 < order.length)
                    return { beforeType: order[i + 1].type, beforeId: order[i + 1].id }
                break
            }
        }
        return { beforeType: "@end", beforeId: "" }
    }

    // 高亮语义与网格一致:落在哪行 = 占据其位,该行高亮;末尾/空白
    // 不高亮(与网格"占位卡不预高亮"同口径)。
    function updateTreeDropTarget(x, y) {
        const fromKind = root.kindOfKey(root.pressKey)
        const fromId = root.idOfKey(root.pressKey)
        let next = ""
        const t = root.treeDropAt(x, y)
        if (fromKind !== "" && fromId !== "" && t) {
            if (t.zone === "row") {
                if (t.key !== root.pressKey
                    && ((fromKind === "account" && (t.kind === "folder" || t.kind === "account"))
                        || (fromKind === "folder" && t.kind === "folder")))
                    next = t.key
            } else if (t.boundary < vmodel.count) {
                const r = vmodel.get(t.boundary)
                if (r.key !== root.pressKey && r.kind !== "plus")
                    next = r.key
            }
        }
        if (next !== root.dropTargetKey)
            root.dropTargetKey = next
    }

    function applyTreeDrop(x, y) {
        const fromKind = root.kindOfKey(root.pressKey)
        const fromId = root.idOfKey(root.pressKey)
        if (fromKind === "" || fromId === "")
            return
        const t = root.treeDropAt(x, y)
        if (fromKind === "folder") {
            if (AccountManager.folders.findIndex(f => f.id === fromId) < 0)
                return
            if (!t)
                return
            if (t.zone === "row") {
                if (t.kind === "folder" && t.id !== fromId)
                    root.moveLayoutElement("folder", fromId, "folder", t.id)
                return // 落在账号行/plus:不动
            }
            const tgt = root.boundaryToLayout(t.boundary)
            root.moveLayoutElement("folder", fromId, tgt.beforeType, tgt.beforeId)
            return
        }
        if (AccountManager.accounts.findIndex(a => a.id === fromId) < 0)
            return
        const fromFolder = AccountManager.folderIdOfAccount(fromId)
        if (!t || (t.zone === "boundary" && t.boundary >= vmodel.count)) {
            // 末尾空白:成员 = 拖出到未分组末尾;未分组 = 移到末尾
            if (fromFolder !== "")
                AccountManager.removeAccountFromFolder(fromId)
            else
                root.moveLayoutElement("account", fromId, "@end", "")
            return
        }
        if (t.zone === "row") {
            if (t.kind === "folder") {
                if (fromFolder !== t.id)
                    AccountManager.addAccountToFolder(t.id, fromId)
                return
            }
            if (t.kind === "account" && t.id !== fromId) {
                const toFolder = AccountManager.folderIdOfAccount(t.id)
                if (fromFolder === toFolder) {
                    if (fromFolder !== "")
                        AccountManager.moveAccountInFolder(fromFolder, fromId, t.id)
                    else
                        root.moveLayoutElement("account", fromId, "account", t.id)
                } else if (toFolder !== "") {
                    AccountManager.addAccountToFolder(toFolder, fromId, t.id)
                } else {
                    if (fromFolder !== "")
                        AccountManager.removeAccountFromFolder(fromId)
                    root.moveLayoutElement("account", fromId, "account", t.id)
                }
            }
            return
        }
        // 行间边界
        const b = t.boundary
        if (b > 0 && b < vmodel.count) {
            const r = vmodel.get(b)
            if (r.kind === "account") {
                const bf = AccountManager.folderIdOfAccount(r.id)
                if (bf !== "") {
                    // 成员行边界 = 夹内定位
                    if (fromFolder === bf)
                        AccountManager.moveAccountInFolder(bf, fromId, r.id)
                    else
                        AccountManager.addAccountToFolder(bf, fromId, r.id)
                    return
                }
            }
        }
        // 首成员行上沿(边界落在文件夹行与首成员之间)= 入夹开头
        if (b > 0 && b <= vmodel.count) {
            const above = b > 0 ? vmodel.get(b - 1) : null
            if (above && above.kind === "folder" && root.isFolderExpanded(above.id)) {
                const members = root.folderInfo(above.id).accountIds || []
                const first = members.length > 0 ? members[0] : ""
                if (first !== "") {
                    if (fromFolder === above.id)
                        AccountManager.moveAccountInFolder(above.id, fromId, first)
                    else
                        AccountManager.addAccountToFolder(above.id, fromId, first)
                    return
                }
                if (fromFolder !== above.id)
                    AccountManager.addAccountToFolder(above.id, fromId)
                return
            }
        }
        // 顶层位置
        const tgt = root.boundaryToLayout(b)
        if (fromFolder !== "")
            AccountManager.removeAccountFromFolder(fromId)
        root.moveLayoutElement("account", fromId, tgt.beforeType, tgt.beforeId)
    }

    // ---- 文件夹(分类) ----
    function isFolderExpanded(id) {
        return root.expandedFolders.indexOf(id) >= 0
    }
    // 点击文件夹卡:切换展开/收起。展开 = 成员卡进入视觉序列(从停靠位
    // 动画到新位 + 淡入);收起 = 成员卡移出序列隐藏(收进文件夹)。
    function toggleFolder(id) {
        if (root.isFolderExpanded(id))
            root.expandedFolders = root.expandedFolders.filter(f => f !== id)
        else
            root.expandedFolders = root.expandedFolders.concat([id])
        // 成员行随 expandedFolders 增删(见 onExpandedFoldersChanged → syncModel),
        // 展开/收起动画由视图的 add/remove/displaced 过渡播。
    }
    function folderNameById(id) {
        const folders = AccountManager.folders
        for (let i = 0; i < folders.length; ++i)
            if (folders[i].id === id)
                return folders[i].name
        return ""
    }
    function folderColorById(id) {
        const folders = AccountManager.folders
        for (let i = 0; i < folders.length; ++i)
            if (folders[i].id === id)
                return folders[i].color
        return ""
    }
    // 账号所属文件夹的颜色(空 = 未分组)。
    function folderColorOfAccount(accountId) {
        return root.folderColorById(AccountManager.folderIdOfAccount(accountId))
    }
    // "#RRGGBB" → 带透明度的 QML 颜色;非法/空返回空串(调用方 fallback)。
    function hexToRgba(hex, alpha) {
        if (!hex || hex.length < 7)
            return ""
        const h = hex.indexOf("#") === 0 ? hex.substring(1) : hex
        if (h.length < 6)
            return ""
        const r = parseInt(h.substring(0, 2), 16)
        const g = parseInt(h.substring(2, 4), 16)
        const b = parseInt(h.substring(4, 6), 16)
        if (isNaN(r) || isNaN(g) || isNaN(b))
            return ""
        return Qt.rgba(r / 255, g / 255, b / 255, alpha)
    }
    function openFolderDialog(id) {
        root.folderEditId = id
        folderNameField.text = id === "" ? "" : root.folderNameById(id)
        // 颜色:新建随机挑预设色,重命名预填当前色(可改)。
        if (id === "") {
            const colors = AccountManager.presetFolderColors()
            root.folderSelectedColor = colors[Math.floor(Math.random() * colors.length)]
        } else {
            root.folderSelectedColor = root.folderColorById(id)
        }
        folderHiddenSwitch.checked = id !== "" && root.folderInfo(id).hidden === true
        root.folderOpen = true
        folderNameField.forceActiveFocus()
    }
    function closeFolderDialog() {
        root.folderOpen = false
    }
    function saveFolder() {
        const name = folderNameField.text.trim()
        if (root.folderEditId === "") {
            AccountManager.addFolder(name, root.folderSelectedColor)
        } else {
            if (name !== "" && name !== root.folderNameById(root.folderEditId))
                AccountManager.renameFolder(root.folderEditId, name)
            if (root.folderSelectedColor !== "" && root.folderSelectedColor !== root.folderColorById(root.folderEditId))
                AccountManager.setFolderColor(root.folderEditId, root.folderSelectedColor)
            AccountManager.setFolderHidden(root.folderEditId, folderHiddenSwitch.checked)
        }
        root.closeFolderDialog()
    }

    // ---- 服务器修改浮窗 ----
    function openEditDialog(id) {
        root.editAccountId = id
        // 预填当前值(名称/地址/用户名);图标字段留空 = 保持当前图标,
        // 且必须清掉上一次的输入(否则会把它写到另一个账号上)。
        const acc = AccountManager.accounts.find(a => a.id === id)
        if (acc) {
            editNameField.text = acc.name
            editUrlField.text = acc.serverUrl
            editUserField.text = acc.userName
        }
        editIconField.text = ""
        linesDraft.clear()
        const ls = (acc && acc.lines) || []
        for (let i = 0; i < ls.length; ++i)
            linesDraft.append({ name: ls[i].name, url: ls[i].url })
        root.editActiveLine = Math.min(Math.max(-1, (acc && acc.activeLine) ?? -1),
                                       linesDraft.count - 1)
        if (linesDraft.count === 0)
            root.editActiveLine = -1
        root.editError = ""
        editHiddenSwitch.checked = root.accountInfo(id).hidden === true
        root.editOpen = true
        editNameField.forceActiveFocus()
    }
    function closeEditDialog() {
        root.editOpen = false
    }
    function submitEdit() {
        const url = editUrlField.text.trim()
        const user = editUserField.text.trim()
        if (url === "") {
            root.editError = "请输入服务器地址"
            return
        }
        if (user === "") {
            root.editError = "请输入用户名"
            return
        }
        const full = url.indexOf("://") < 0 ? "http://" + url : url
        // 仅改存储(token/密码保留),保存即落盘并通知 UI。
        AccountManager.updateAccount(root.editAccountId, editNameField.text.trim(), full, user)
        // 图标:字段非空才应用(留空 = 保持当前图标);清除由"清除图标"按钮即时执行。
        const icon = editIconField.text.trim()
        if (icon !== "")
            AccountManager.setAccountIcon(root.editAccountId, icon)
        AccountManager.setAccountHidden(root.editAccountId, editHiddenSwitch.checked)
        editNameField.forceActiveFocus()
        const activeUrl = (editActiveLine >= 0 && editActiveLine < linesDraft.count)
                          ? linesDraft.get(editActiveLine).url : ""
        const list = []
        for (let i = 0; i < linesDraft.count; ++i)
            list.push({ name: linesDraft.get(i).name, url: linesDraft.get(i).url })
        AccountManager.setAccountLines(root.editAccountId, list)
        if (editActiveLine < 0 || list.length === 0) {
            AccountManager.setActiveLine(root.editAccountId, -1) // 主地址
        } else {
            const ls2 = root.accountInfo(root.editAccountId).lines || []
            for (let i = 0; i < ls2.length; ++i) {
                if (ls2[i].url === activeUrl) {
                    AccountManager.setActiveLine(root.editAccountId, i)
                    break
                }
            }
        }
        root.closeEditDialog()
    }
    // 删除:先向服务器发登出(结果忽略),再删本地数据(见
    // AccountManager.removeAccount),账号卡自动补位。
    function deleteEditAccount() {
        AccountManager.removeAccount(root.editAccountId)
        root.closeEditDialog()
    }
    function openAddDialog() {
        root.addOpen = true
        nameField.text = ""
        urlField.text = ""
        userField.text = ""
        passField.text = ""
        root.errorMsg = ""
        urlField.forceActiveFocus()
    }
    function closeAddDialog() {
        root.addOpen = false
        root.adding = false
        passField.text = "" // 不留密码于控件,避免二次读取
    }

    function submitAdd() {
        if (root.adding)
            return
        const url = urlField.text.trim()
        const user = userField.text.trim()
        if (url === "") {
            root.errorMsg = "请输入服务器地址"
            return
        }
        if (user === "") {
            root.errorMsg = "请输入用户名"
            return
        }
        const full = url.indexOf("://") < 0 ? "http://" + url : url
        root.errorMsg = ""
        root.adding = true
        console.info("ServerManager: 登录发起", user, "@", full)
        AccountManager.addAccount(nameField.text, full, user, passField.text)
    }

    // 隐藏开关(胶囊指示器,视觉与设置页 SettingSwitch 一致)。
    component HiddenSwitch: Switch {
        id: hsw
        padding: 0
        spacing: 0
        implicitWidth: 42
        implicitHeight: 24
        indicator: Rectangle {
            implicitWidth: 42
            implicitHeight: 24
            radius: 12
            color: hsw.checked ? Theme.accent : Theme.borderSoft
            border.width: 1
            border.color: hsw.checked ? Theme.accent : Theme.borderSoft
            Rectangle {
                width: 18
                height: 18
                radius: 9
                y: 3
                x: hsw.checked ? parent.width - width - 3 : 3
                color: Theme.accentInk
                Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            }
        }
        contentItem: Item { implicitWidth: 0; implicitHeight: 0 }
    }

    onExpandedFoldersChanged: root.syncModel()

    Component.onCompleted: root.syncModel()

    ListModel { id: vmodel }

    Connections {
        target: AccountManager
        function onAccountsChanged() {
            root.syncModel()
        }
        function onFoldersChanged() {
            root.syncModel()
        }
        function onLayoutOrderChanged() {
            root.syncModel()
        }
        function onHiddenChanged() {
            root.syncModel()
        }
    }

    // 右键菜单:与设置页下拉同套令牌(scrim 底 + accent 描边 + 淡入),
    // 不用原生 Menu/MenuItem 默认样式。
    // 自绘悬停气泡挂在目标项上方。
    component HoverBubble: Rectangle {
        property string tip: ""
        property bool show: false
        visible: show && tip !== ""
        // 向下弹:单选点行贴近浮窗顶/列表裁剪线,上弹会被裁。
        anchors.top: parent.bottom
        anchors.topMargin: 8
        anchors.horizontalCenter: parent.horizontalCenter
        width: bubbleText.implicitWidth + 14
        height: bubbleText.implicitHeight + 8
        radius: 6
        color: Qt.rgba(Theme.scrim.r, Theme.scrim.g, Theme.scrim.b, 0.92)
        z: 100
        AppText {
            id: bubbleText
            anchors.centerIn: parent
            text: parent.tip
            color: Theme.textPrimary
            font.pixelSize: 12
        }
    }

    Menu {
        id: blankMenu
        padding: 6
        enter: Transition {
            NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 120 }
        }
        exit: Transition {
            NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 120 }
        }
        background: Rectangle {
            implicitWidth: 170
            color: Qt.rgba(Theme.scrim.r, Theme.scrim.g, Theme.scrim.b, 0.92)
            radius: 8
            border.width: 1
            border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
        }
        delegate: MenuItem {
            id: menuItem
            implicitHeight: 32
            padding: 0
            background: Rectangle {
                radius: 6
                color: menuItem.highlighted ? Theme.tint : "transparent"
            }
            contentItem: AppText {
                text: menuItem.text
                font.pixelSize: 13
                color: menuItem.highlighted ? Theme.accent : Theme.textPrimary
                verticalAlignment: Text.AlignVCenter
                leftPadding: 10
            }
        }
        // 注意:Menu.delegate 只对 Action 子项生效(官方文档原文
        // "used to create items to present actions");直接声明的
        // MenuItem 子项会绕开 delegate 落回原生样式。
        Action {
            text: "新建文件夹…"
            onTriggered: root.createFolderAt(root.pendingMenuX, root.pendingMenuY)
        }
    }

    // 卡片右键菜单(账号卡/文件夹卡共用):设置 / 新建文件夹 / 删除。
    // 新建文件夹按菜单打开时的坐标定位(见 createFolderAt)。
    property string menuKind: ""
    property string menuId: ""
    property int pendingMenuX: 0
    property int pendingMenuY: 0
    function openCardMenu(kind, id, item, x, y) {
        root.menuKind = kind
        root.menuId = id
        root.pendingMenuX = x
        root.pendingMenuY = y
        cardMenu.popup(item, x, y)
    }
    Menu {
        id: cardMenu
        padding: 6
        enter: Transition {
            NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 120 }
        }
        exit: Transition {
            NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 120 }
        }
        background: Rectangle {
            implicitWidth: 170
            color: Qt.rgba(Theme.scrim.r, Theme.scrim.g, Theme.scrim.b, 0.92)
            radius: 8
            border.width: 1
            border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
        }
        delegate: MenuItem {
            id: cardMenuItem
            implicitHeight: 32
            padding: 0
            background: Rectangle {
                radius: 6
                color: cardMenuItem.highlighted ? Theme.tint : "transparent"
            }
            contentItem: AppText {
                text: cardMenuItem.text
                font.pixelSize: 13
                color: cardMenuItem.highlighted ? Theme.accent : Theme.textPrimary
                verticalAlignment: Text.AlignVCenter
                leftPadding: 10
            }
        }
        Action {
            text: "设置"
            onTriggered: root.menuKind === "folder" ? root.openFolderDialog(root.menuId)
                                                    : root.openEditDialog(root.menuId)
        }
        Action {
            text: "新建文件夹…"
            onTriggered: root.createFolderAt(root.pendingMenuX, root.pendingMenuY)
        }
        Action {
            text: "删除"
            onTriggered: root.menuKind === "folder" ? AccountManager.removeFolder(root.menuId)
                                                    : AccountManager.removeAccount(root.menuId)
        }
        MenuSeparator {
            visible: root.menuKind === "account"
                     && ((root.accountInfo(root.menuId).lines || []).length > 0)
            height: visible ? 9 : 0
            padding: 4
            contentItem: Rectangle {
                implicitHeight: 1
                color: Theme.borderSoft
            }
        }
        Instantiator {
            model: {
                if (root.menuKind !== "account")
                    return []
                const acc = root.accountInfo(root.menuId)
                const ls = acc.lines || []
                if (ls.length === 0)
                    return []
                const out = [{ name: "主地址", url: acc.serverUrl, idx: -1 }]
                for (let i = 0; i < ls.length; ++i)
                    out.push({ name: ls[i].name !== "" ? ls[i].name : "线路 " + (i + 1),
                               url: ls[i].url, idx: i })
                return out
            }
            delegate: MenuItem {
                id: lineChoice
                required property var modelData
                implicitHeight: 32
                padding: 0
                background: Rectangle {
                    radius: 6
                    color: lineChoice.highlighted ? Theme.tint : "transparent"
                }
                contentItem: AppText {
                    text: (root.accountInfo(root.menuId).activeLine === lineChoice.modelData.idx
                           ? "● " : "　") + lineChoice.modelData.name + " · " + lineChoice.modelData.url
                    font.pixelSize: 12
                    color: lineChoice.highlighted ? Theme.accent : Theme.textPrimary
                    verticalAlignment: Text.AlignVCenter
                    leftPadding: 8
                    elide: Text.ElideRight
                }
                onTriggered: AccountManager.setActiveLine(root.menuId, lineChoice.modelData.idx)
            }
            onObjectAdded: (index, object) => cardMenu.addItem(object)
            onObjectRemoved: (index, object) => cardMenu.removeItem(object)
        }
    }

    // 点服务器卡:回首页并把该服显示名注入首页过滤框(Main 接)。
    signal browseHome(string serverUrl, string accountId, string name)

    DropArea {
        anchors.fill: parent
        onPositionChanged: (drag) => root.updateDropTarget(drag)
        onExited: root.clearDropTarget()
        onDropped: (drop) => {
            drop.acceptProposedAction()
            root.clearDropTarget()
            root.applyDrop(drop.x, drop.y)
        }
    }

    Row {
        id: headerRow
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 24
        spacing: 12
        BackCircleButton {
            anchors.verticalCenter: parent.verticalCenter
        }
        AppText {
            anchors.verticalCenter: parent.verticalCenter
            text: "服务器管理"
            color: Theme.textPrimary
            font.pixelSize: 24
            font.bold: true
        }
        AppText {
            anchors.verticalCenter: parent.verticalCenter
            text: "· " + root.visibleAccountCount
            color: Theme.textMuted
            font.pixelSize: 16
        }
    }

    // 视图:网格 / 树状(持久化 config.toml,与播放历史页同款)
    SegmentedControl {
        anchors.top: headerRow.top
        anchors.right: parent.right
        anchors.rightMargin: 24
        anchors.topMargin: 6
        options: [{ value: "grid", label: "网格" }, { value: "tree", label: "树状" }]
        currentValue: ConfigManager.serverManagerView
        onActivated: (value) => ConfigManager.serverManagerView = value
    }


    Item {
        id: gridArea
        anchors.top: headerRow.bottom
        anchors.topMargin: 20
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 24
        anchors.rightMargin: 24
        anchors.bottomMargin: 24

        MouseArea {
            id: blankArea
            anchors.fill: parent
            acceptedButtons: Qt.RightButton
            onClicked: (mouse) => {
                root.pendingMenuX = mouse.x
                root.pendingMenuY = mouse.y
                blankMenu.popup(blankArea, mouse.x, mouse.y)
            }
        }

        Column {
            anchors.centerIn: parent
            visible: AccountManager.accountCount === 0
            spacing: 12
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200 } }

            AppText {
                text: "还没有服务器哦~"
                color: Theme.textPrimary
                font.pixelSize: 18
                font.bold: true
                anchors.horizontalCenter: parent.horizontalCenter
            }
            AppText {
                text: "点击左上角的“+”卡片添加服务器吧"
                color: Theme.textMuted
                font.pixelSize: 14
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }

        GridView {
            id: vgrid
            visible: ConfigManager.serverManagerView !== "tree"
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: -root.hoverPadY
            anchors.bottomMargin: -root.hoverPadY
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.columns * root.cellW + 2 * root.hoverPadX
            clip: true
            header: Item { width: 1; height: root.hoverPadY }
            footer: Item { width: 1; height: root.hoverPadY }
            cellWidth: root.cellW
            cellHeight: root.cellH
            model: vmodel
            interactive: !root.dragActive
            add: Transition {
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: root.fadeDuration; easing.type: Easing.OutCubic }
            }
            remove: Transition {
                NumberAnimation { property: "opacity"; to: 0; duration: root.fadeDuration; easing.type: Easing.OutCubic }
            }
            displaced: Transition {
                NumberAnimation { properties: "x,y"; duration: root.moveDuration; easing.type: Easing.OutCubic }
            }
            move: Transition {
                NumberAnimation { properties: "x,y"; duration: root.moveDuration; easing.type: Easing.OutCubic }
            }

            delegate: Item {
                id: cell
                required property int index
                required property string key
                required property string kind
                required property string id
                readonly property var modelData: cell.kind === "folder"
                                                 ? root.folderInfo(cell.id) : root.accountInfo(cell.id)
                readonly property bool isFolder: cell.kind === "folder"
                readonly property bool isPlus: cell.kind === "plus"
                readonly property bool isHovered: root.hoveredKey === cell.key
                readonly property bool dropTarget: root.dropTargetKey === cell.key
                width: vgrid.cellWidth
                height: vgrid.cellHeight
                z: (root.dragKey === cell.key || cell.isHovered) ? 2 : 1

                Item {
                    id: holder
                    width: root.cardW
                    height: root.cardH
                    x: root.hoverPadX + root.shiftOfCell(cell.index)
                    Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

                    // ===== 添加服务器占位卡(第 0 行)=====
                    Item {
                        id: plusSlot
                        visible: cell.isPlus
                        width: root.cardW
                        height: root.cardH
                        Rectangle {
                            id: plusCard
                            width: root.cardW
                            height: root.cardH
                            radius: 12
                            color: "transparent"
                            border.width: 2
                            border.color: plusHover.containsMouse ? Theme.accent : Theme.textMuted

                            Canvas {
                                id: plusIcon
                                property color lineColor: plusHover.containsMouse ? Theme.accent : Theme.textMuted
                                anchors.centerIn: parent
                                anchors.verticalCenterOffset: -10
                                width: 44
                                height: 44
                                onLineColorChanged: requestPaint()
                                onPaint: {
                                    const ctx = getContext("2d")
                                    ctx.clearRect(0, 0, width, height)
                                    ctx.strokeStyle = lineColor
                                    ctx.lineWidth = 3
                                    ctx.lineCap = "round"
                                    ctx.beginPath()
                                    ctx.moveTo(8, height / 2)
                                    ctx.lineTo(width - 8, height / 2)
                                    ctx.stroke()
                                    ctx.beginPath()
                                    ctx.moveTo(width / 2, 8)
                                    ctx.lineTo(width / 2, height - 8)
                                    ctx.stroke()
                                }
                            }
                            AppText {
                                anchors.top: plusIcon.bottom
                                anchors.topMargin: 8
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "添加服务器"
                                color: plusHover.containsMouse ? Theme.accent : Theme.textMuted
                                font.pixelSize: 14
                                Behavior on color { ColorAnimation { duration: 120 } }
                            }

                            // 点击打开添加浮窗。
                            MouseArea {
                                id: plusHover
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.openAddDialog()
                            }
                        }
                    }

                    // ===== 账号卡 =====
                    Rectangle {
                        id: card
                        readonly property var modelData: cell.kind === "account" ? cell.modelData : root.emptyAccount
                        property string accountId: cell.id
                        property bool hovered: false
                        property bool expanded: false

                        function settleBack() {
                            if (Math.abs(card.x) > 0.5) {
                                cardSettleX.from = card.x
                                cardSettleX.to = 0
                                cardSettleX.start()
                            }
                            if (Math.abs(card.y) > 0.5) {
                                cardSettleY.from = card.y
                                cardSettleY.to = 0
                                cardSettleY.start()
                            }
                        }

                        visible: cell.kind === "account"
                        width: root.cardW
                        height: root.cardH
                        radius: 12
                        color: {
                            const c = root.folderColorOfAccount(card.modelData.id)
                            if (c === "")
                                return Theme.surface
                            const col = root.hexToRgba(c, 0.30)
                            return col !== "" ? col : Theme.surface
                        }
                        opacity: Drag.active ? 0.6
                                               : (root.isAccountHidden(cell.id) && AccountManager.showHidden ? 0.55 : 1.0)
                        scale: card.expanded ? root.hoverScale : 1.0
                        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                        Drag.active: dragArea.drag.active
                        Drag.source: card
                        Drag.hotSpot.x: width / 2
                        Drag.hotSpot.y: height / 2
                        border.width: card.modelData.authStatus === "invalid" ? 2 : (cell.dropTarget ? 2 : 1)
                        border.color: card.modelData.authStatus === "invalid" ? Theme.danger
                                      : (cell.dropTarget ? Theme.accent
                                      : (card.hovered ? Theme.accent : Theme.bg))

                        NumberAnimation {
                            id: cardSettleX
                            target: card
                            property: "x"
                            duration: root.dragDuration
                            easing.type: Easing.OutCubic
                        }
                        NumberAnimation {
                            id: cardSettleY
                            target: card
                            property: "y"
                            duration: root.dragDuration
                            easing.type: Easing.OutCubic
                        }

                        Timer {
                            id: hoverTimer
                            interval: 200
                            repeat: false
                            onTriggered: {
                                if (root.dragActive)
                                    return
                                card.expanded = true
                                root.hoveredKey = cell.key
                            }
                        }

                        Rectangle {
                            width: root.iconSize
                            height: root.iconSize
                            radius: 10
                            anchors.top: parent.top
                            anchors.topMargin: 14
                            anchors.left: parent.left
                            anchors.leftMargin: 14
                            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                            ServerIcon {
                                anchors.fill: parent
                                radius: 10 
                                icon: card.modelData.icon
                                fallbackText: (card.modelData.name !== "" ? card.modelData.name : card.modelData.userName).charAt(0)
                            }
                        }

                        Column {
                            anchors.top: parent.top
                            anchors.topMargin: 18
                            anchors.left: parent.left
                            anchors.leftMargin: 14 + root.iconSize + 12
                            anchors.right: parent.right
                            anchors.rightMargin: 14
                            spacing: 4
                            Row {
                                width: parent.width
                                spacing: 6
                                readonly property bool hiddenTag: root.isAccountHidden(cell.id)
                                                                 && AccountManager.showHidden
                                AppText {
                                    text: card.modelData.name !== "" ? card.modelData.name : card.modelData.userName
                                    color: Theme.textPrimary
                                    font.pixelSize: 15
                                    font.bold: true
                                    elide: Text.ElideRight
                                    width: parent.width
                                           - (card.modelData.authStatus === "invalid" ? 78 : 0)
                                           - (parent.hiddenTag ? 62 : 0)
                                }
                                AppText {
                                    visible: card.modelData.authStatus === "invalid"
                                    text: "[凭据失效]"
                                    color: Theme.danger
                                    font.pixelSize: 12
                                }
                                AppText {
                                    visible: parent.hiddenTag
                                    text: "[已隐藏]"
                                    color: Theme.textMuted
                                    font.pixelSize: 12
                                }
                            }
                            AppText {
                                width: parent.width
                                text: card.modelData.userName + " · " + card.modelData.serverUrl
                                color: Theme.textMuted
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                        }

                        MouseArea {
                            id: dragArea
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            preventStealing: true
                            drag {
                                target: card
                                threshold: 8
                            }
                            onEntered: {
                                card.hovered = true
                                if (!root.dragActive)
                                    hoverTimer.start()
                            }
                            onExited: {
                                card.hovered = false
                                hoverTimer.stop()
                                card.expanded = false
                                if (root.hoveredKey === cell.key)
                                    root.hoveredKey = ""
                            }
                            onPressed: (mouse) => {
                                if (mouse.button === Qt.RightButton) {
                                    root.openCardMenu("account", cell.id, card, mouse.x, mouse.y)
                                    return
                                }
                                hoverTimer.stop()
                                card.expanded = false
                                if (root.hoveredKey === cell.key)
                                    root.hoveredKey = ""
                                root.pressKey = cell.key
                                root.dragKey = cell.key
                                root.dragActive = true
                            }
                            onClicked: (mouse) => {
                                if (mouse.button === Qt.RightButton)
                                    return
                                if (mouse.modifiers & Qt.ControlModifier)
                                    root.openEditDialog(cell.id)
                                else
                                    root.browseHome(cell.modelData.serverUrl, cell.id,
                                                    card.modelData.name !== "" ? card.modelData.name
                                                                               : card.modelData.userName)
                            }
                            onReleased: {
                                const r = root
                                r.dragActive = false
                                card.Drag.drop()
                                r.dragKey = ""
                                r.settleCardBodies()
                            }
                        }
                    }

                    // ===== 文件夹卡 =====
                    Rectangle {
                        id: fcard
                        readonly property var modelData: cell.kind === "folder" ? cell.modelData : root.emptyFolder
                        property string folderId: cell.id
                        property bool isOpen: root.isFolderExpanded(fcard.folderId)
                        property bool hovered: false
                        property bool expanded: false

                        function settleBack() {
                            if (Math.abs(fcard.x) > 0.5) {
                                folderSettleX.from = fcard.x
                                folderSettleX.to = 0
                                folderSettleX.start()
                            }
                            if (Math.abs(fcard.y) > 0.5) {
                                folderSettleY.from = fcard.y
                                folderSettleY.to = 0
                                folderSettleY.start()
                            }
                        }

                        visible: cell.isFolder
                        width: root.cardW
                        height: root.cardH
                        radius: 12
                        color: {
                            const col = root.hexToRgba(fcard.modelData.color, 0.30)
                            return col !== "" ? col : Theme.surface
                        }
                        opacity: Drag.active ? 0.6
                                               : (root.isFolderHidden(fcard.folderId) && AccountManager.showHidden ? 0.55 : 1.0)
                        scale: fcard.expanded ? root.hoverScale : 1.0
                        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                        Drag.active: farea.drag.active
                        Drag.source: fcard
                        Drag.hotSpot.x: width / 2
                        Drag.hotSpot.y: height / 2
                        border.width: cell.dropTarget ? 2 : 1
                        border.color: cell.dropTarget ? Theme.accent
                                      : (fcard.isOpen ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
                                      : (fcard.hovered ? Theme.accent : Theme.bg))

                        NumberAnimation {
                            id: folderSettleX
                            target: fcard
                            property: "x"
                            duration: root.dragDuration
                            easing.type: Easing.OutCubic
                        }
                        NumberAnimation {
                            id: folderSettleY
                            target: fcard
                            property: "y"
                            duration: root.dragDuration
                            easing.type: Easing.OutCubic
                        }

                        Timer {
                            id: fcardHoverTimer
                            interval: 200
                            repeat: false
                            onTriggered: {
                                if (root.dragActive)
                                    return
                                fcard.expanded = true
                                root.hoveredKey = cell.key
                            }
                        }

                        Rectangle {
                            width: root.iconSize
                            height: root.iconSize
                            radius: 10
                            anchors.top: parent.top
                            anchors.topMargin: 14
                            anchors.left: parent.left
                            anchors.leftMargin: 14
                            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                            Canvas {
                                property color lineColor: farea.containsMouse ? Theme.accent : Theme.textMuted
                                anchors.centerIn: parent
                                width: 28
                                height: 28
                                onLineColorChanged: requestPaint()
                                onPaint: {
                                    const ctx = getContext("2d")
                                    ctx.clearRect(0, 0, width, height)
                                    ctx.lineCap = "round"
                                    ctx.lineJoin = "round"
                                    ctx.lineWidth = 2.5
                                    ctx.strokeStyle = lineColor
                                    ctx.beginPath()
                                    ctx.moveTo(5, 11)
                                    ctx.lineTo(10, 11)
                                    ctx.lineTo(13, 7)
                                    ctx.lineTo(23, 7)
                                    ctx.lineTo(23, 11)
                                    ctx.moveTo(5, 11)
                                    ctx.lineTo(5, 23)
                                    ctx.lineTo(23, 23)
                                    ctx.lineTo(23, 11)
                                    ctx.stroke()
                                }
                            }
                        }

                        Column {
                            anchors.top: parent.top
                            anchors.topMargin: 18
                            anchors.left: parent.left
                            anchors.leftMargin: 14 + root.iconSize + 12
                            anchors.right: parent.right
                            anchors.rightMargin: 14
                            spacing: 4
                            Row {
                                width: parent.width
                                spacing: 6
                                readonly property bool hiddenTag: root.isFolderHidden(fcard.folderId)
                                                                 && AccountManager.showHidden
                                AppText {
                                    text: fcard.modelData.name
                                    color: Theme.textPrimary
                                    font.pixelSize: 15
                                    font.bold: true
                                    elide: Text.ElideRight
                                    width: parent.width - (parent.hiddenTag ? 62 : 0)
                                }
                                AppText {
                                    visible: parent.hiddenTag
                                    text: "[已隐藏]"
                                    color: Theme.textMuted
                                    font.pixelSize: 12
                                }
                            }
                            AppText {
                                width: parent.width
                                text: root.visibleMemberCount(fcard.folderId) + " 台服务器"
                                color: Theme.textMuted
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                        }

                        AppText {
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 8
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            text: fcard.isOpen ? "▾" : "▸"
                            color: farea.containsMouse ? Theme.accent : Theme.textMuted
                            font.pixelSize: 13
                        }

                        MouseArea {
                            id: farea
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            preventStealing: true
                            drag {
                                target: fcard
                                threshold: 8
                            }
                            onEntered: {
                                fcard.hovered = true
                                if (!root.dragActive)
                                    fcardHoverTimer.start()
                            }
                            onExited: {
                                fcard.hovered = false
                                fcardHoverTimer.stop()
                                fcard.expanded = false
                                if (root.hoveredKey === cell.key)
                                    root.hoveredKey = ""
                            }
                            onPressed: (mouse) => {
                                if (mouse.button === Qt.RightButton) {
                                    root.openCardMenu("folder", cell.id, fcard, mouse.x, mouse.y)
                                    return
                                }
                                fcardHoverTimer.stop()
                                fcard.expanded = false
                                if (root.hoveredKey === cell.key)
                                    root.hoveredKey = ""
                                root.pressKey = cell.key
                                root.dragKey = cell.key
                                root.dragActive = true
                            }
                            onClicked: (mouse) => {
                                if (mouse.button === Qt.RightButton)
                                    return
                                // Ctrl+点击打开修改浮窗(重命名/删除);普通点击
                                // 展开/收起成员。拖动超过 threshold 后不触发 click。
                                if (mouse.modifiers & Qt.ControlModifier)
                                    root.openFolderDialog(cell.id)
                                else
                                    root.toggleFolder(cell.id)
                            }
                            onReleased: {
                                const r = root
                                r.dragActive = false
                                fcard.Drag.drop()
                                r.dragKey = ""
                                r.settleCardBodies()
                            }
                        }
                    }
                }
            }
        }
    }

    Connections {
        target: AccountManager
        function onAccountLoginFinished(ok, message) {
            root.adding = false
            if (ok) {
                console.info("ServerManager: 登录成功")
                root.closeAddDialog()
            } else {
                console.warn("ServerManager: 登录失败", message)
                root.errorMsg = message
            }
        }
    }

    Rectangle {
        visible: root.addOpen
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        z: 100
        MouseArea {
            anchors.fill: parent
            onClicked: root.closeAddDialog()
        }

        Rectangle {
            anchors.centerIn: parent
            width: 420
            height: addCol.implicitHeight + 48
            radius: 12
            color: Theme.surface
            border.width: 1
            border.color: Qt.rgba(Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 0.35)

            MouseArea {
                anchors.fill: parent
            }

            Column {
                id: addCol
                anchors.top: parent.top
                anchors.topMargin: 24
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width - 48
                spacing: 14

                Row {
                    spacing: 8
                    AppText {
                        text: "添加服务器"
                        color: Theme.textPrimary
                        font.pixelSize: 20
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Column {
                    width: parent.width
                    spacing: 6
                    AppText {
                        text: "服务器名称（可选，留空自动获取）"
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                    TextField {
                        id: nameField
                        width: parent.width
                        height: 36
                        leftPadding: 14
                        rightPadding: 14
                        placeholderText: "留空则使用服务器端名称"
                        placeholderTextColor: Theme.textMuted
                        color: Theme.textPrimary
                        font.pixelSize: 14
                        background: Rectangle {
                            radius: 18
                            color: Theme.bg
                            border.width: 1
                            border.color: nameField.activeFocus ? Theme.accent : Theme.textMuted
                        }
                        onAccepted: urlField.forceActiveFocus()
                    }
                }
                Column {
                    width: parent.width
                    spacing: 6
                    AppText {
                        text: "服务器地址"
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                    TextField {
                        id: urlField
                        width: parent.width
                        height: 36
                        leftPadding: 14
                        rightPadding: 14
                        placeholderText: "http://192.168.1.100:8096"
                        placeholderTextColor: Theme.textMuted
                        color: Theme.textPrimary
                        font.pixelSize: 14
                        background: Rectangle {
                            radius: 18
                            color: Theme.bg
                            border.width: 1
                            border.color: urlField.activeFocus ? Theme.accent : Theme.textMuted
                        }
                        onAccepted: userField.forceActiveFocus()
                    }
                }
                Column {
                    width: parent.width
                    spacing: 6
                    AppText {
                        text: "用户名"
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                    TextField {
                        id: userField
                        width: parent.width
                        height: 36
                        leftPadding: 14
                        rightPadding: 14
                        placeholderText: "请输入用户名"
                        placeholderTextColor: Theme.textMuted
                        color: Theme.textPrimary
                        font.pixelSize: 14
                        background: Rectangle {
                            radius: 18
                            color: Theme.bg
                            border.width: 1
                            border.color: userField.activeFocus ? Theme.accent : Theme.textMuted
                        }
                        onAccepted: passField.forceActiveFocus()
                    }
                }
                Column {
                    width: parent.width
                    spacing: 6
                    AppText {
                        text: "密码（可为空）"
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                    TextField {
                        id: passField
                        width: parent.width
                        height: 36
                        leftPadding: 14
                        rightPadding: 14
                        placeholderText: "留空则不保存密码"
                        placeholderTextColor: Theme.textMuted
                        color: Theme.textPrimary
                        echoMode: TextInput.Password
                        font.pixelSize: 14
                        background: Rectangle {
                            radius: 18
                            color: Theme.bg
                            border.width: 1
                            border.color: passField.activeFocus ? Theme.accent : Theme.textMuted
                        }
                        onAccepted: root.submitAdd()
                    }
                }

                Button {
                    id: addBtn
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 160
                    height: 36
                    text: root.adding ? "登录中…" : "添加"
                    enabled: !root.adding
                    onClicked: root.submitAdd()
                    background: Rectangle {
                        radius: 18
                        color: addBtn.hovered ? Theme.accentHover : Theme.accent
                        border.width: 0
                    }
                    contentItem: AppText {
                        text: addBtn.text
                        color: Theme.accentInk
                        font.pixelSize: 14
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Column {
                    visible: root.errorMsg !== ""
                    width: parent.width
                    spacing: 4
                    AppText {
                        text: "失败"
                        color: Theme.danger
                        font.pixelSize: 15
                        font.bold: true
                    }
                    AppText {
                        width: parent.width
                        text: root.errorMsg
                        color: Theme.textMuted
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }

    Rectangle {
        id: folderOverlay
        visible: root.folderOpen
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        z: 100
        MouseArea {
            anchors.fill: parent
            onClicked: root.closeFolderDialog()
        }

        Rectangle {
            anchors.centerIn: parent
            width: 380
            height: folderCol.implicitHeight + 48
            radius: 12
            color: Theme.surface
            border.width: 1
            border.color: Qt.rgba(Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 0.35)

            MouseArea {
                anchors.fill: parent
            }

            Column {
                id: folderCol
                anchors.top: parent.top
                anchors.topMargin: 24
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width - 48
                spacing: 14

                Row {
                    spacing: 8
                    AppText {
                        text: root.folderEditId === "" ? "新建文件夹" : "重命名文件夹"
                        color: Theme.textPrimary
                        font.pixelSize: 20
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                AppText {
                    text: root.folderEditId === ""
                          ? "新建后拖动服务器卡片到文件夹上即可归类"
                          : "重命名后立即生效"
                    color: Theme.textMuted
                    font.pixelSize: 12
                }

                TextField {
                    id: folderNameField
                    width: parent.width
                    height: 36
                    leftPadding: 14
                    rightPadding: 14
                    placeholderText: "文件夹名称(留空自动命名)"
                    placeholderTextColor: Theme.textMuted
                    color: Theme.textPrimary
                    font.pixelSize: 14
                    background: Rectangle {
                        radius: 18
                        color: Theme.bg
                        border.width: 1
                        border.color: folderNameField.activeFocus ? Theme.accent : Theme.textMuted
                    }
                    onAccepted: root.saveFolder()
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8
                    Repeater {
                        model: AccountManager.presetFolderColors()
                        Rectangle {
                            required property string modelData
                            width: 24
                            height: 24
                            radius: 12
                            color: modelData
                            border.width: root.folderSelectedColor === modelData ? 3 : 0
                            border.color: Theme.accent
                            scale: root.folderSelectedColor === modelData ? 1.15 : 1.0
                            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: root.folderSelectedColor = modelData
                            }
                        }
                    }
                }

                // 隐藏文件夹:成员服务器继承(整组从各处消失),Alt+S 可临时露出。
                Row {
                    visible: root.folderEditId !== ""
                    width: parent.width
                    spacing: 10
                    Column {
                        width: parent.width - 52
                        spacing: 2
                        AppText {
                            text: "隐藏文件夹"
                            color: Theme.textPrimary
                            font.pixelSize: 14
                        }
                        AppText {
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: "文件夹与其内 " + root.visibleMemberCount(root.folderEditId)
                                  + " 台服务器一并隐藏"
                            color: Theme.textMuted
                            font.pixelSize: 12
                        }
                    }
                    HiddenSwitch {
                        id: folderHiddenSwitch
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 12
                    Button {
                        id: folderOkBtn
                        width: 120
                        height: 36
                        text: "确定"
                        onClicked: root.saveFolder()
                        background: Rectangle {
                            radius: 18
                            color: folderOkBtn.hovered ? Theme.accentHover : Theme.accent
                            border.width: 0
                        }
                        contentItem: AppText {
                            text: folderOkBtn.text
                            color: Theme.accentInk
                            font.pixelSize: 14
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                    Button {
                        id: folderCancelBtn
                        width: 120
                        height: 36
                        text: "取消"
                        onClicked: root.closeFolderDialog()
                        background: Rectangle {
                            radius: 18
                            color: folderCancelBtn.hovered ? Qt.rgba(Theme.textPrimary.r, Theme.textPrimary.g, Theme.textPrimary.b, 0.1) : "transparent"
                            border.width: 1
                            border.color: folderCancelBtn.hovered ? Theme.accent : Theme.textMuted
                        }
                        contentItem: AppText {
                            text: folderCancelBtn.text
                            color: folderCancelBtn.hovered ? Theme.accent : Theme.textPrimary
                            font.pixelSize: 14
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                Button {
                    id: folderDeleteBtn
                    visible: root.folderEditId !== ""
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 160
                    height: 36
                    text: "删除文件夹"
                    onClicked: {
                        AccountManager.removeFolder(root.folderEditId)
                        root.closeFolderDialog()
                    }
                    background: Rectangle {
                        radius: 18
                        color: folderDeleteBtn.hovered ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.15) : "transparent"
                        border.width: 1
                        border.color: folderDeleteBtn.hovered ? Theme.danger : Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.5)
                    }
                    contentItem: AppText {
                        text: folderDeleteBtn.text
                        color: Theme.danger
                        font.pixelSize: 14
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }

    Rectangle {
        id: editOverlay
        visible: root.editOpen
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        z: 100
        MouseArea {
            anchors.fill: parent
            onClicked: root.closeEditDialog()
        }

        Rectangle {
            anchors.centerIn: parent
            width: 420
            height: editCol.implicitHeight + 48
            radius: 12
            color: Theme.surface
            border.width: 1
            border.color: Qt.rgba(Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 0.35)

            MouseArea {
                anchors.fill: parent
            }

            Column {
                id: editCol
                anchors.top: parent.top
                anchors.topMargin: 24
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width - 48
                spacing: 14

                Row {
                    spacing: 8
                    AppText {
                        text: "修改服务器"
                        color: Theme.textPrimary
                        font.pixelSize: 20
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Column {
                    width: parent.width
                    spacing: 6
                    AppText {
                        text: "服务器名称（可选，留空自动获取）"
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                    TextField {
                        id: editNameField
                        width: parent.width
                        height: 36
                        leftPadding: 14
                        rightPadding: 14
                        placeholderText: "留空则使用服务器端名称"
                        placeholderTextColor: Theme.textMuted
                        color: Theme.textPrimary
                        font.pixelSize: 14
                        background: Rectangle {
                            radius: 18
                            color: Theme.bg
                            border.width: 1
                            border.color: editNameField.activeFocus ? Theme.accent : Theme.textMuted
                        }
                        onAccepted: editUrlField.forceActiveFocus()
                    }
                }
                Column {
                    width: parent.width
                    spacing: 6
                    AppText {
                        text: "服务器地址"
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                    Row {
                        width: parent.width
                        spacing: 8
                        Rectangle {
                            width: 14
                            height: 14
                            radius: 7
                            anchors.verticalCenter: parent.verticalCenter
                            color: "transparent"
                            border.width: 1
                            border.color: editActiveLine === -1 ? Theme.accent : Theme.textMuted
                            Rectangle {
                                anchors.centerIn: parent
                                width: 6
                                height: 6
                                radius: 3
                                visible: editActiveLine === -1
                                color: Theme.accent
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.editActiveLine = -1
                            }
                            HoverHandler { id: hovMainRadio }
                            HoverBubble {
                                tip: "使用主地址"
                                show: hovMainRadio.hovered
                            }
                        }
                        TextField {
                            id: editUrlField
                            width: parent.width - 22
                            height: 36
                            leftPadding: 14
                            rightPadding: 14
                            placeholderText: "http://192.168.1.100:8096"
                            placeholderTextColor: Theme.textMuted
                            color: Theme.textPrimary
                            font.pixelSize: 14
                            background: Rectangle {
                                radius: 18
                                color: Theme.bg
                                border.width: 1
                                border.color: editUrlField.activeFocus ? Theme.accent : Theme.textMuted
                            }
                            onAccepted: editUserField.forceActiveFocus()
                        }
                    }
                }
                // 线路(同一服务器的不同入口,行内可编辑;行数不定有界滚动)。
                // 单选组 = 主地址行(-1)+ 线路行;请求与取流走当前选中项。
                Column {
                    width: parent.width
                    spacing: 6
                    ListView {
                        visible: linesDraft.count > 0
                        width: parent.width
                        height: Math.min(contentHeight, 5 * 38)
                        clip: true
                        interactive: contentHeight > height
                        model: ListModel { id: linesDraft }
                        spacing: 4
                        ScrollBar.vertical: MoeScrollBar {}
                        delegate: Rectangle {
                            id: lineRow
                            required property int index
                            required property string name
                            required property string url
                            width: ListView.view.width
                            height: 34
                            radius: 8
                            color: editActiveLine === index ? Theme.tint : "transparent"
                            Row {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 8
                                Rectangle {
                                    width: 14
                                    height: 14
                                    radius: 7
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: "transparent"
                                    border.width: 1
                                    border.color: editActiveLine === lineRow.index ? Theme.accent : Theme.textMuted
                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: 6
                                        height: 6
                                        radius: 3
                                        visible: editActiveLine === lineRow.index
                                        color: Theme.accent
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.editActiveLine = lineRow.index
                                    }
                                    HoverHandler { id: hovLineRadio }
                                    HoverBubble {
                                        tip: "设为当前线路"
                                        show: hovLineRadio.hovered
                                    }
                                }
                                TextField {
                                    width: 100
                                    height: 30
                                    anchors.verticalCenter: parent.verticalCenter
                                    leftPadding: 8
                                    rightPadding: 8
                                    placeholderText: "备注名"
                                    placeholderTextColor: Theme.textMuted
                                    color: Theme.textPrimary
                                    font.pixelSize: 13
                                    text: lineRow.name
                                    onEditingFinished: linesDraft.setProperty(lineRow.index, "name", text.trim())
                                    background: Rectangle {
                                        radius: 6
                                        color: Theme.bg
                                        border.width: 1
                                        border.color: parent.activeFocus ? Theme.accent : "transparent"
                                    }
                                }
                                TextField {
                                    id: lineUrlEdit
                                    width: parent.width - 100 - 14 - 20 - 8 * 4
                                    height: 30
                                    anchors.verticalCenter: parent.verticalCenter
                                    leftPadding: 8
                                    rightPadding: 8
                                    placeholderText: "https://…"
                                    placeholderTextColor: Theme.textMuted
                                    color: Theme.textPrimary
                                    font.pixelSize: 13
                                    text: lineRow.url
                                    onEditingFinished: {
                                        let u = text.trim()
                                        if (u !== "" && u.indexOf("://") < 0)
                                            u = "http://" + u
                                        linesDraft.setProperty(lineRow.index, "url", u)
                                    }
                                    background: Rectangle {
                                        radius: 6
                                        color: Theme.bg
                                        border.width: 1
                                        border.color: lineUrlEdit.activeFocus ? Theme.accent : "transparent"
                                    }
                                }
                                AppText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "✕"
                                    color: hovLineDel.hovered ? Theme.danger : Theme.textMuted
                                    font.pixelSize: 13
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            linesDraft.remove(lineRow.index)
                                            if (root.editActiveLine >= linesDraft.count)
                                                root.editActiveLine = linesDraft.count - 1
                                        }
                                    }
                                    HoverHandler { id: hovLineDel }
                                }
                            }
                        }
                    }
                    Rectangle {
                        width: parent.width
                        height: 34
                        radius: 8
                        color: hovAddLine.hovered ? Theme.tint : "transparent"
                        border.width: 1
                        border.color: Qt.rgba(Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 0.35)
                        AppText {
                            anchors.centerIn: parent
                            text: "＋ 添加线路"
                            color: hovAddLine.hovered ? Theme.accent : Theme.textMuted
                            font.pixelSize: 13
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: linesDraft.append({ name: "", url: "" })
                        }
                        HoverHandler { id: hovAddLine }
                    }
                    AppText {
                        visible: linesDraft.count > 0
                        width: parent.width
                        wrapMode: Text.Wrap
                        text: "● 为当前线路;切换后请求与播放都走该地址(保存生效)"
                        color: Theme.textMuted
                        font.pixelSize: 11
                    }
                }
                Column {
                    width: parent.width
                    spacing: 6
                    AppText {
                        text: "用户名"
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                    TextField {
                        id: editUserField
                        width: parent.width
                        height: 36
                        leftPadding: 14
                        rightPadding: 14
                        placeholderText: "请输入用户名"
                        placeholderTextColor: Theme.textMuted
                        color: Theme.textPrimary
                        font.pixelSize: 14
                        background: Rectangle {
                            radius: 18
                            color: Theme.bg
                            border.width: 1
                            border.color: editUserField.activeFocus ? Theme.accent : Theme.textMuted
                        }
                        onAccepted: root.submitEdit()
                    }
                }

                Column {
                    width: parent.width
                    spacing: 6
                    AppText {
                        text: "服务器图标（可选，留空保持不变）"
                        color: Theme.textMuted
                        font.pixelSize: 13
                    }
                    Row {
                        width: parent.width
                        spacing: 12
                        Rectangle {
                            width: 52
                            height: 52
                            radius: 10
                            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                            ServerIcon {
                                anchors.fill: parent
                                radius: 10
                                icon: editIconField.text.trim() || root.accountInfo(root.editAccountId).icon
                                fallbackText: "图"
                            }
                        }
                        TextField {
                            id: editIconField
                            width: parent.width - 172
                            height: 36
                            anchors.verticalCenter: parent.verticalCenter
                            leftPadding: 14
                            rightPadding: 14
                            placeholderText: "图片 URL 或本地路径,如 /path/icon.png"
                            placeholderTextColor: Theme.textMuted
                            color: Theme.textPrimary
                            font.pixelSize: 14
                            background: Rectangle {
                                radius: 18
                                color: Theme.bg
                                border.width: 1
                                border.color: editIconField.activeFocus ? Theme.accent : Theme.textMuted
                            }
                            onAccepted: root.submitEdit()
                        }
                        Button {
                            id: editIconClearBtn
                            width: 96
                            height: 30
                            anchors.verticalCenter: parent.verticalCenter
                            text: "清除图标"
                            enabled: editIconField.text.trim() !== ""
                                     || (root.accountInfo(root.editAccountId).icon || "") !== ""
                            onClicked: {
                                AccountManager.setAccountIcon(root.editAccountId, "")
                                editIconField.text = ""
                            }
                            background: Rectangle {
                                radius: 15
                                color: editIconClearBtn.enabled && editIconClearBtn.hovered ? Qt.rgba(Theme.textPrimary.r, Theme.textPrimary.g, Theme.textPrimary.b, 0.1) : "transparent"
                                border.width: 1
                                border.color: editIconClearBtn.enabled ? (editIconClearBtn.hovered ? Theme.accent : Theme.textMuted) : Theme.textMuted
                            }
                            contentItem: AppText {
                                text: editIconClearBtn.text
                                color: editIconClearBtn.enabled ? (editIconClearBtn.hovered ? Theme.accent : Theme.textPrimary) : Theme.textMuted
                                font.pixelSize: 13
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }
                }

                // 隐藏服务器:开启后本服务器不出现于首页/搜索/播放历史/本页,
                // 也不参与网络聚合与 token 校验;Alt+S 可临时露出全部隐藏项。
                Row {
                    width: parent.width
                    spacing: 10
                    Column {
                        width: parent.width - 52
                        spacing: 2
                        AppText {
                            text: "隐藏服务器"
                            color: Theme.textPrimary
                            font.pixelSize: 14
                        }
                        AppText {
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: root.accountInfo(root.editAccountId).hiddenByFolder === true
                                  ? "所属文件夹已隐藏:取消文件夹隐藏后才会重新出现"
                                  : "隐藏后不出现于首页/搜索/历史，也不拉取数据（Alt+S 临时露出）；保存后生效"
                            color: Theme.textMuted
                            font.pixelSize: 12
                        }
                    }
                    HiddenSwitch {
                        id: editHiddenSwitch
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 12
                    Button {
                        id: editSaveBtn
                        width: 120
                        height: 36
                        text: "保存"
                        onClicked: root.submitEdit()
                        background: Rectangle {
                            radius: 18
                            color: editSaveBtn.hovered ? Theme.accentHover : Theme.accent
                            border.width: 0
                        }
                        contentItem: AppText {
                            text: editSaveBtn.text
                            color: Theme.accentInk
                            font.pixelSize: 14
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                    Button {
                        id: editCancelBtn
                        width: 120
                        height: 36
                        text: "取消"
                        onClicked: root.closeEditDialog()
                        background: Rectangle {
                            radius: 18
                            color: "transparent"
                            border.width: 1
                            border.color: editCancelBtn.hovered ? Theme.accent : Theme.textMuted
                        }
                        contentItem: AppText {
                            text: editCancelBtn.text
                            color: editCancelBtn.hovered ? Theme.accent : Theme.textPrimary
                            font.pixelSize: 14
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                Column {
                    visible: root.editError !== ""
                    width: parent.width
                    spacing: 4
                    AppText {
                        text: "失败"
                        color: Theme.danger
                        font.pixelSize: 15
                        font.bold: true
                    }
                    AppText {
                        width: parent.width
                        text: root.editError
                        color: Theme.textMuted
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                    }
                }

                Button {
                    id: editDeleteBtn
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 160
                    height: 36
                    text: "删除服务器"
                    onClicked: root.deleteEditAccount()
                    background: Rectangle {
                        radius: 18
                        color: editDeleteBtn.hovered ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.15) : "transparent"
                        border.width: 1
                        border.color: editDeleteBtn.hovered ? Theme.danger : Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.5)
                    }
                    contentItem: AppText {
                        text: editDeleteBtn.text
                        color: Theme.danger
                        font.pixelSize: 14
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }

    // ---- 树状(长条)视图 ----
    ListView {
        id: treeList
        visible: ConfigManager.serverManagerView === "tree"
        anchors.top: gridArea.top
        anchors.bottom: gridArea.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 24
        anchors.rightMargin: 40 // 让出页面滚动条
        clip: true
        model: vmodel
        interactive: !root.dragActive
        spacing: root.treeRowGap
        ScrollBar.vertical: MoeScrollBar {}
        // 空白区右键 = 新建文件夹(ListView 会拦截落不到 blankArea);
        // 只收右键,左键滚动/行交互不受影响。
        TapHandler {
            acceptedButtons: Qt.RightButton
            onTapped: (eventPoint) => {
                const gp = mapToItem(root, eventPoint.position.x, eventPoint.position.y)
                root.pendingMenuX = gp.x
                root.pendingMenuY = gp.y
                blankMenu.popup(treeList, eventPoint.position.x, eventPoint.position.y)
            }
        }
        add: Transition {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: root.fadeDuration; easing.type: Easing.OutCubic }
        }
        remove: Transition {
            NumberAnimation { property: "opacity"; to: 0; duration: root.fadeDuration; easing.type: Easing.OutCubic }
        }
        displaced: Transition {
            NumberAnimation { properties: "y"; duration: root.moveDuration; easing.type: Easing.OutCubic }
        }

        delegate: Item {
            id: trow
            required property int index
            required property string key
            required property string kind
            required property string id
            readonly property var modelData: trow.kind === "folder"
                                             ? root.folderInfo(trow.id) : root.accountInfo(trow.id)
            readonly property bool isFolder: trow.kind === "folder"
            readonly property bool isPlus: trow.kind === "plus"
            // 成员行:其父夹展开时紧随夹行;分支线画在最末成员前断开
            readonly property string parentFolder: trow.kind === "account"
                                                   ? AccountManager.folderIdOfAccount(trow.id) : ""
            readonly property bool isMember: parentFolder !== ""
            readonly property bool dropTarget: root.dropTargetKey === trow.key
            width: treeList.width
            height: root.treeRowH
            // 拖动中抬到兄弟行之上(否则被后续行盖住,读作"到了下方")
            z: root.dragKey === trow.key ? 10 : 1

            Rectangle {
                id: bar
                width: trow.width
                height: root.treeRowH
                radius: 8
                color: trow.dropTarget ? Theme.tintStrong
                     : tarea.containsMouse ? Theme.tint : Theme.surface
                border.width: trow.dropTarget ? 1 : 0
                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
                opacity: (root.dragKey === trow.key) ? 0.85 : 1.0
                Behavior on color { ColorAnimation { duration: 120 } }

                Drag.active: tarea.drag.active
                Drag.source: bar
                Drag.hotSpot.x: width / 2
                Drag.hotSpot.y: height / 2

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 12 + (trow.isMember ? 26 : 0)
                    anchors.rightMargin: 12
                    spacing: 10

                    // 夹色块(文件夹行)
                    Rectangle {
                        visible: trow.isFolder
                        width: 10
                        height: 10
                        radius: 3
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.hexToRgba(trow.isFolder ? trow.modelData.color : "", 1) || Theme.accent
                    }
                    // 账号小图标
                    ServerIcon {
                        visible: trow.kind === "account"
                        width: 24
                        height: 24
                        anchors.verticalCenter: parent.verticalCenter
                        icon: trow.kind === "account" ? trow.modelData.icon : ""
                        fallbackText: trow.kind === "account"
                                      ? (trow.modelData.name !== "" ? trow.modelData.name : trow.modelData.userName).charAt(0) : ""
                    }
                    AppText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: trow.isPlus ? "添加服务器"
                            : trow.isFolder ? trow.modelData.name
                            : (trow.modelData.name !== "" ? trow.modelData.name : trow.modelData.userName)
                        color: Theme.textPrimary
                        font.pixelSize: 14
                        font.bold: trow.isFolder
                        elide: Text.ElideRight
                    }
                    AppText {
                        visible: trow.isFolder
                        anchors.verticalCenter: parent.verticalCenter
                        text: "· " + root.visibleMemberCount(trow.id) + " 台"
                        color: Theme.textMuted
                        font.pixelSize: 12
                    }
                    AppText {
                        visible: trow.kind === "account"
                        anchors.verticalCenter: parent.verticalCenter
                        text: trow.modelData.userName + " · " + trow.modelData.serverUrl
                        color: Theme.textMuted
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }
                    AppText {
                        visible: trow.kind === "account" && trow.modelData.authStatus === "invalid"
                        anchors.verticalCenter: parent.verticalCenter
                        text: "[凭据失效]"
                        color: Theme.danger
                        font.pixelSize: 12
                    }
                    AppText {
                        visible: !trow.isPlus && ((trow.kind === "account" && root.isAccountHidden(trow.id))
                                                  || (trow.isFolder && root.isFolderHidden(trow.id)))
                                 && AccountManager.showHidden
                        anchors.verticalCenter: parent.verticalCenter
                        text: "[已隐藏]"
                        color: Theme.textMuted
                        font.pixelSize: 12
                    }
                }
                // 文件夹展开箭头(右缘)
                NavGlyph {
                    visible: trow.isFolder
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    dir: 2
                    rotation: root.isFolderExpanded(trow.id) ? 0 : 180
                    width: 12
                    height: 12
                }

                MouseArea {
                    id: tarea
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    preventStealing: true
                    drag {
                        target: trow.isPlus ? null : bar
                        axis: Drag.YAxis
                        threshold: 8
                    }
                    onPressed: (mouse) => {
                        if (mouse.button === Qt.RightButton) {
                            if (!trow.isPlus)
                                root.openCardMenu(trow.kind, trow.id, bar, mouse.x, mouse.y)
                            return
                        }
                        if (trow.isPlus)
                            return
                        root.pressKey = trow.key
                        root.dragKey = trow.key
                        root.dragActive = true
                    }
                    onClicked: (mouse) => {
                        if (mouse.button === Qt.RightButton)
                            return
                        if (trow.isPlus) {
                            root.openAddDialog()
                            return
                        }
                        if (trow.isFolder) {
                            if (mouse.modifiers & Qt.ControlModifier)
                                root.openFolderDialog(trow.id)
                            else
                                root.toggleFolder(trow.id)
                            return
                        }
                        if (mouse.modifiers & Qt.ControlModifier)
                            root.openEditDialog(trow.id)
                        else
                            root.browseHome(trow.modelData.serverUrl, trow.id,
                                            trow.modelData.name !== "" ? trow.modelData.name
                                                                       : trow.modelData.userName)
                    }
                    onReleased: {
                        root.dragActive = false
                        bar.Drag.drop()
                        root.dragKey = ""
                        treeSettle.start() // 行归位
                    }
                }
                // 归位动画(拖完回弹到模型位)
                PropertyAnimation {
                    id: treeSettle
                    target: bar
                    property: "y"
                    to: 0
                    duration: 200
                    easing.type: Easing.OutCubic
                }
            }
        }
    }

    // 贴边滚动条:网格有内缩边距,attached 会随之内缩;条作页面级
    // 兄弟锚到窗口右缘,手动绑定驱动。
    MoeScrollBar {
        view: vgrid
        anchors.right: parent.right
        // 纵向锚同级兄弟 gridArea(header 以下到页底):vgrid 在 gridArea
        // 内,是侄级,锚定违规(锚只能对父/兄弟);其负 hoverPad 边距也
        // 不该带给滚动条。
        anchors.top: gridArea.top
        anchors.bottom: gridArea.bottom
    }
}
