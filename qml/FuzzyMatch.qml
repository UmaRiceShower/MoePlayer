pragma Singleton
import QtQuick

//! 模糊匹配打分:查询按字符顺序在文本中找子序列(大小写不敏感,空格只作分隔),
//! 供本地列表即时过滤使用(播放历史条目、账号/服务器选择)。
//! 判定:多个查询字符必须按序出现;加成:连续命中、词首/段首命中;扣分:命中跨度
//! 越长、文本越长越靠后。不匹配返回 -1,空查询返回 0;分数只用于排序,不保证稳定性。
QtObject {
    function score(query, text) {
        const q = (query === null || query === undefined ? "" : String(query)).trim()
        const t = (text === null || text === undefined ? "" : String(text))
        if (q === "")
            return 0
        const ql = q.toLowerCase()
        const tl = t.toLowerCase()
        let ti = 0
        let total = 0
        let prev = -2
        let first = -1
        let last = -1
        let hits = 0
        for (let qi = 0; qi < ql.length; ++qi) {
            const ch = ql[qi]
            if (ch === " ")
                continue
            let hit = -1
            while (ti < tl.length) {
                const c = tl[ti]
                ++ti
                if (c === ch) {
                    hit = ti - 1
                    break
                }
            }
            if (hit < 0)
                return -1
            let s = 10
            if (hit === prev + 1)
                s += 8        // 紧接上一个命中:连续片段
            if (hit === 0 || tl[hit - 1] === " " || tl[hit - 1] === "/"
                    || tl[hit - 1] === "-" || tl[hit - 1] === ":"
                    || tl[hit - 1] === "|")
                s += 6        // 词首/段首
            total += s
            prev = hit
            if (first < 0)
                first = hit
            last = hit
            ++hits
        }
        // 命中区间跨度与文本总长:越紧凑、越短越优先。
        total -= Math.floor((last - first + 1 - hits) * 0.5)
        total -= Math.floor(tl.length * 0.03)
        return total
    }

    function match(query, text) {
        return score(query, text) >= 0
    }

    // 命中判定:原文按子序列模糊匹配(见 score);原文不中再试拼音 —— 全拼与首字母
    // 都按**连续**子串判定。拼音若也走模糊子序列,长串会把 "sn" 这类短查询匹配到
    // 几乎所有条目(实测 33 条中 29 条命中),故这里收严:只认连续片段。
    // 查询里的空格忽略,故 "shao nv"、"shaonv"、"sngs" 都能命中"少女怪兽";
    // PinyinHelper 还会给出次选读音拼法,故 "yinyue"(音乐)这类多音字也可命中。
    function hit(query, text) {
        const t = (text === null || text === undefined ? "" : String(text))
        const q = (query === null || query === undefined ? "" : String(query)).trim()
        if (q === "")
            return true
        if (score(q, t) >= 0)
            return true
        const key = PinyinHelper.searchKey(t)
        if (key === "")
            return false
        const compact = q.replace(/ /g, "").toLowerCase()
        if (compact === "")
            return true
        // 分段:全拼、简拼(,可能再来一组次选读音的同样两段)。全部按连续子串判定。
        const parts = key.split("|")
        for (let i = 0; i < parts.length; ++i) {
            if (parts[i].replace(/ /g, "").indexOf(compact) >= 0)
                return true
        }
        return false
    }
}
