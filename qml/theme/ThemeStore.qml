pragma Singleton
import QtQuick
import MoePlayer.Core

QtObject {
    id: store

    // ---- 配色方案表 ----
    // 一套配色 = 界面色板 + 背景底色(baseTop/baseBottom)+ 暗角。
    // 新增配色:此处加一项,并在 ConfigManager::optionsThemePalette() 里加同 key 的选项。
    // 颜色写 "#RRGGBB",带透明度写 "#AARRGGBB"(alpha 在前,如 "#59FF9EBD")。
    readonly property var palettes: [
        {
            key: "yozakura",
            
            bg: "#0D0F1A", surface: "#171A29",
            textPrimary: "#ECEFF7", textMuted: "#8A90A6",
            accent: "#FFABCA", accentSoft: "#FFD7E6", accentDeep: "#D67FA6", accentInk: "#694653", accentWarm: "#FFC76B",
            baseTop: "#0A0E1C", baseBottom: "#20153A",
            vignette: 0.25
        },
        {
            key: "sumi",
            
            bg: "#0B0B0E", surface: "#15151A",
            textPrimary: "#E8E8EC", textMuted: "#8A8A92",
            accent: "#B9B9C6", accentSoft: "#DEDEE6", accentDeep: "#7A7A88", accentInk: "#4A4A4F", accentWarm: "#C9A96B",
            baseTop: "#0A0A0D", baseBottom: "#141419",
            vignette: 0.22
        },
        {
            key: "hoshiyo",
            
            bg: "#090B14", surface: "#131627",
            textPrimary: "#EBEEF8", textMuted: "#8A90A8",
            accent: "#A8C4FF", accentSoft: "#D6E2FF", accentDeep: "#6E8FD6", accentInk: "#455069", accentWarm: "#FFD9A0",
            baseTop: "#05070F", baseBottom: "#0D1330",
            vignette: 0.30
        },
        {
            key: "kasumi",
            
            bg: "#101117", surface: "#1A1B22",
            textPrimary: "#ECEBF0", textMuted: "#8F8E99",
            accent: "#B3A6C9", accentSoft: "#E2DCF0", accentDeep: "#7E7194", accentInk: "#423D4A", accentWarm: "#D8C79A",
            baseTop: "#0B0C12", baseBottom: "#191720",
            vignette: 0.22
        },
        {
            key: "ame",
            
            bg: "#0C0F16", surface: "#161B26",
            textPrimary: "#E9EDF5", textMuted: "#89909F",
            accent: "#92B4DE", accentSoft: "#CCDEF4", accentDeep: "#5E7FA8", accentInk: "#374454", accentWarm: "#FFD9A0",
            baseTop: "#080B12", baseBottom: "#151E30",
            vignette: 0.26
        },
        {
            key: "natsuyo",
            
            bg: "#0A0F0B", surface: "#141B14",
            textPrimary: "#EDF2EA", textMuted: "#8D998C",
            accent: "#D8E88A", accentSoft: "#EFF6C8", accentDeep: "#9AAF56", accentInk: "#5F663D", accentWarm: "#FFD08A",
            baseTop: "#060C0A", baseBottom: "#0F1E15",
            vignette: 0.28
        },
        {
            key: "kohaku",
            
            bg: "#120E0A", surface: "#1E1712",
            textPrimary: "#F3EDE6", textMuted: "#9A9188",
            accent: "#F5B971", accentSoft: "#FFE0B8", accentDeep: "#C08A45", accentInk: "#644C2E", accentWarm: "#FF9E6B",
            baseTop: "#100B08", baseBottom: "#241812",
            vignette: 0.26
        },
        // ---- 亮色系(light:1;纪律:底为有色相倾向的灰白 L≈0.94 不用纯白、
        //      文字深色带色相 L≤0.25、强调色为可读的中饱和色 L 0.45~0.6)----
        {
            key: "milk",
            
            light: 1,
            bg: "#FAF6EE", surface: "#FFFFFF",
            textPrimary: "#3B3428", textMuted: "#665E53",
            accent: "#C95F80", accentSoft: "#DD8AA3", accentDeep: "#A03A5C", accentInk: "#FFFFFF", accentWarm: "#D8955A",
            baseTop: "#FBF7EF", baseBottom: "#F3EADB",
            vignette: 0.10
        },
        {
            key: "hazakura",
            
            light: 1,
            bg: "#FBF3F5", surface: "#FFFFFF",
            textPrimary: "#3D2E36", textMuted: "#66555D",
            accent: "#C9537B", accentSoft: "#DE7E9C", accentDeep: "#9E3659", accentInk: "#FFFFFF", accentWarm: "#E8A25E",
            baseTop: "#FCF5F7", baseBottom: "#F5E6EB",
            vignette: 0.10
        },
        {
            key: "mint",
            
            light: 1,
            bg: "#F1F7F3", surface: "#FFFFFF",
            textPrimary: "#2C352F", textMuted: "#59665E",
            accent: "#3E8562", accentSoft: "#5FA77F", accentDeep: "#2C6147", accentInk: "#FFFFFF", accentWarm: "#D8A05A",
            baseTop: "#F3F8F4", baseBottom: "#E4EFE7",
            vignette: 0.10
        },
        {
            key: "sora",
            
            light: 1,
            bg: "#EFF5FA", surface: "#FFFFFF",
            textPrimary: "#2A3140", textMuted: "#485266",
            accent: "#4673B8", accentSoft: "#6B92CC", accentDeep: "#31548A", accentInk: "#FFFFFF", accentWarm: "#E8A86B",
            baseTop: "#F2F7FC", baseBottom: "#E2ECF6",
            vignette: 0.10
        }
    ]

    // ---- 背景效果表 ----
    // 一个效果 = 着色器 style + 前景元素色(glow0/1/2 暗色底用,glow0L/1L/2L 亮色底用)
    // + 是否含动效。暗底版是"暗底上的浅色"(加法发光);亮底版是"白纸上的墨色"
    // (着色器里切到 alpha 覆盖混合,元素色要**比底色深且饱和**才读得出)。
    // 新增效果:此处加一项 + ConfigManager::optionsBackgroundEffect() 同 key
    // + shaders/background.frag 加对应 style 分支。
    readonly property var effects: [
        {
            key: "none", label: "无(纯色)",
            style: -1, motion: 0,
            glow0: "#FFFFFF",
            glow1: "#FFFFFF",
            glow2: "#FFFFFF"
        },
        {
            key: "sakura", label: "落樱",
            style: 0, motion: 1,
            // 近/中/远层花色:近白只留给最高光,中/远层保持可辨的粉(否则读作雪/星)
            glow0: "#FFF3F7",
            glow1: "#FFC9DC",
            glow2: "#FF9EC0",
            // 亮底:白纸粉樱(和风),加深加饱和
            glow0L: "#E87BA0",
            glow1L: "#D6648C",
            glow2L: "#C0527C"
        },
        {
            key: "firefly", label: "萤火",
            style: 1, motion: 1,
            glow0: "#F2FFB0",
            glow1: "#D9F27E",
            glow2: "#9CCF66",
            // 亮底:读作漂浮的花粉/金尘
            glow0L: "#C8A24B",
            glow1L: "#B08A38",
            glow2L: "#96722C"
        },
        {
            key: "starry", label: "星空流星",
            style: 2, motion: 1,
            // 流星头 / 流星尾 / 星色
            glow0: "#FFFFFF",
            glow1: "#9FB8FF",
            glow2: "#EAF0FF",
            // 亮底:青灰星点 + 流星
            glow0L: "#5E72A8",
            glow1L: "#9AA8CC",
            glow2L: "#8A98C8"
        },
        {
            key: "rain", label: "夜雨",
            style: 3, motion: 1,
            glow0: "#B9CBE6",
            glow1: "#8FA8CC",
            glow2: "#6E86A8",
            // 亮底:白昼雨
            glow0L: "#7A90B8",
            glow1L: "#6E80A8",
            glow2L: "#5E7088"
        }
    ]

    // 当前配色/效果:key 找不到时回退(配色取首项夜樱,效果取落樱)。
    readonly property var palette: {
        const want = ConfigManager.themePalette
        for (let i = 0; i < store.palettes.length; ++i)
            if (store.palettes[i].key === want)
                return store.palettes[i]
        return store.palettes[0]
    }
    readonly property var effect: {
        const want = ConfigManager.backgroundEffect
        for (let i = 0; i < store.effects.length; ++i)
            if (store.effects[i].key === want)
                return store.effects[i]
        return store.effects[1]   // 落樱
    }
    // 亮色系配色(带 light 标志):UI 派生令牌(scrim 掺黑不掺白)与
    // 背景效果(元素取 glow*L 墨色版 + alpha 覆盖混合)都要据此切换。
    readonly property bool isLight: !!store.palette.light

    // config.toml 高级覆盖:空串保留预设值。
    function pick(override, fallback) {
        return (override !== undefined && override !== null && override !== "")
                ? override : fallback
    }

    // ---- 界面色板令牌 ----
    readonly property color bg: store.pick(ConfigManager.themeBg, store.palette.bg)
    readonly property color surface: store.pick(ConfigManager.themeSurface, store.palette.surface)
    readonly property color textPrimary: store.pick(ConfigManager.themeTextPrimary, store.palette.textPrimary)
    readonly property color textMuted: store.pick(ConfigManager.themeTextMuted, store.palette.textMuted)
    readonly property color accent: store.pick(ConfigManager.themeAccent, store.palette.accent)
    readonly property color accentSoft: store.pick(ConfigManager.themeAccentSoft, store.palette.accentSoft)
    readonly property color accentDeep: store.pick(ConfigManager.themeAccentDeep, store.palette.accentDeep)
    readonly property color accentInk: store.pick(ConfigManager.themeAccentInk, store.palette.accentInk)
    readonly property color accentWarm: store.pick(ConfigManager.themeAccentWarm, store.palette.accentWarm)

    // ---- 背景参数 = 底色(配色)× 效果层(效果) ----
    readonly property var background: {
        const pal = store.palette
        const fx = store.effect
        const light = !!pal.light
        const tint = function (key, override) {
            const g = (light && fx[key + "L"]) ? fx[key + "L"] : fx[key]
            return store.pick(override, g)
        }
        return {
            baseTop: store.pick(ConfigManager.themeBaseTop, pal.baseTop),
            baseBottom: store.pick(ConfigManager.themeBaseBottom, pal.baseBottom),
            glow0: tint("glow0", ConfigManager.themeGlowA),
            glow1: tint("glow1", ConfigManager.themeGlowB),
            glow2: tint("glow2", ConfigManager.themeGlowC),
            style: fx.style,
            light: light ? 1 : 0,
            vignette: pal.vignette, motion: fx.motion
        }
    }
    // 背景效果层强度(0..1,设置界面滑块百分比)。
    readonly property real intensity: ConfigManager.backgroundIntensity / 100.0
    // 流星周期(星空流星效果):频率百分比定标 T = 7·100/v(v=100 复刻现状 3.5 秒一颗,
    // v=50 → 7 秒一颗,v=10 → 35 秒一颗);v=0 → 0,着色器直接跳过流星(真关)。
    readonly property real meteorPeriod: ConfigManager.backgroundMeteorRate <= 0
                                         ? 0.0 : 700.0 / ConfigManager.backgroundMeteorRate
    // 效果本身含动效且设置未关时才有动效;帧率由设置决定。
    readonly property bool animated: Number(store.background.motion) > 0
                                      && ConfigManager.backgroundMotion !== "off"
    readonly property int frameIntervalMs: ConfigManager.backgroundMotion === "high" ? 33 : 83
}
