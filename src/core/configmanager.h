#pragma once

#include <QNetworkProxy>
#include <QObject>
#include <QSet>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

#include <functional>

class QFileSystemWatcher;
class QTimer;

//! 配置项单一真相表(表驱动 schema + 运行时 map 内核 + 属性外壳)。
//! 每项一行 X-macro(名字/类型/默认/TOML section/注释/UI 元数据/控件/选项/校验),
//! 由不同宏变体展开到:Q_PROPERTY 外壳、访问器、信号、元数据表、load/render/reset、
//! items 导出。**默认值/校验/注释/UI 文案的一切真相在此表**,加配置项 = 表 1 行。
//!
//! 存储:运行时 QVariantMap(唯一真相,数据化/导入导出/多 profile 的内核);
//! 暴露:生成属性(getter 读 map、typed setter 转发 setValue)——QML 绑定读
//! 保持强类型与名称检查;setValue/value 为统一读写通道。
//! 文件:AppPaths::configDir()/config.toml(toml++ 读;QSaveFile
//! 原子写回;外部修改热重载)。敏感数据(凭据/账号)仍归 accounts.json,不进 TOML。
namespace MoeConfig {

enum class Type { Bool, String, Int };
enum class Widget { Switch, Combo, Field, Slider, Hidden };

struct Item {
    const char *name;      // 属性名/QML 键(元数据表索引)
    const char *tomlKey;   // TOML 文件键(与 name 可不同:旧模板键名沿用,不破坏用户文件)
    Type type;
    QVariant def;          // 编译期默认值
    const char *section;   // TOML section
    const char *comment;   // 写回注释(单行)
    const char *uiSection; // 设置浮窗分类(Hidden 项为空)
    const char *uiLabel;
    const char *uiDesc;
    Widget widget;
    std::function<QVariantList()> options;               // Combo 选项 {label,key}
    std::function<bool(const QVariant &)> validate;      // 类型外的追加校验
};

// 选项/校验钩子(宏行引用名字;实现于 configmanager.cpp)。
QVariantList optionsLibrarySortBy();
QVariantList optionsLibrarySortOrder();
QVariantList optionsDetailPosterPos();
QVariantList optionsDetailTextPos();
QVariantList optionsDetailButtonsPos();
bool validatePosterPos(const QVariant &v);
bool validateTextPos(const QVariant &v);
bool validateButtonsPos(const QVariant &v);
bool validateProxy(const QVariant &v);
bool validateWheelStep(const QVariant &v);
bool validateSearchLimit(const QVariant &v);
QVariantList optionsHistoryView();
QVariantList optionsServerManagerView();
bool validateServerManagerView(const QVariant &v);
bool validateHistoryView(const QVariant &v);
QVariantList optionsSuperRes();
bool validateSuperRes(const QVariant &v);
QVariantList optionsPlayerBackend();
bool validatePlayerBackend(const QVariant &v);
QVariantList optionsThemePalette();
bool validateThemePalette(const QVariant &v);
QVariantList optionsBackgroundEffect();
bool validateBackgroundEffect(const QVariant &v);
QVariantList optionsBackgroundMotion();
QVariantList optionsPageTransition();
bool validatePageTransition(const QVariant &v);
bool validatePercent(const QVariant &v);
bool validateShortcut(const QVariant &v);

#define MoeConfig_Type_bool MoeConfig::Type::Bool
#define MoeConfig_Type_QString MoeConfig::Type::String
#define MoeConfig_Type_int MoeConfig::Type::Int

// 配置项一行真相表:name, tomlKey(TOML 文件键), Qt 类型, 默认值,
// TOML section, 写回注释, UI 分类, UI 标签, UI 描述, 控件, 选项钩子, 校验钩子。
// tomlKey 沿用旧模板键名(sortBy/sortOrder/sidebarLeft/posterPos/textPos/
// buttonsPos/textWidth/textHeight)——属性名/QML 键用 name,两者解耦,
// 不破坏用户磁盘 config.toml 与手改值。
#define MOECONFIG_X(M) \
    M(monetEnabled, "monetEnabled", bool, true, "theme", "海报莫奈动态取色(false 回退静态主题色)", "界面", "海报莫奈取色", "从海报提取主题色,染色详情页强调色与界面点缀;关闭后使用默认蓝色。", Switch, nullptr, nullptr) \
    M(themePalette, "themePalette", QString, "yozakura", "theme", "配色方案(ThemeStore.palettes 的 key)", "界面", "配色方案", "整套界面配色与背景底色;默认夜樱(深靛 × 浅粉)。", Combo, optionsThemePalette, validateThemePalette) \
    M(backgroundEffect, "backgroundEffect", QString, "sakura", "theme", "背景效果(ThemeStore.effects 的 key;none 为纯色)", "界面", "背景效果", "背景上的动态效果层,与配色独立;选「无」为纯色背景。", Combo, optionsBackgroundEffect, validateBackgroundEffect) \
    M(backgroundMotion, "backgroundMotion", QString, "low", "theme", "背景动效帧率(off/low/high;仅含动效的预设生效)", "界面", "背景动效", "含动效的背景按此帧率刷新:极低频几乎看不出刷新、更省,流畅更顺滑;静止预设不受影响。", Combo, optionsBackgroundMotion, nullptr) \
    M(backgroundIntensity, "backgroundIntensity", int, 100, "theme", "背景强度(百分比 0-100)", "界面", "背景强度", "背景整体强度:0 接近纯底色,100 为预设原样。", Slider, nullptr, validatePercent) \
    M(backgroundMeteorRate, "backgroundMeteorRate", int, 100, "theme", "星空流星频率(百分比,0=关)", "界面", "流星频率", "仅「星空流星」效果生效:100 = 约 3.5 秒一颗(现状),50 ≈ 7 秒一颗,0 = 不出现流星。", Slider, nullptr, validatePercent) \
    M(pageTransition, "pageTransition", QString, "axis_x", "theme", "页面转场(axis_x/slide_up/fade/ios_slide)", "界面", "页面转场", "页面切换动画:横向轻移(Material)、纵向上浮(Kirigami)、纯淡入淡出、横滑视差(iOS)。", Combo, optionsPageTransition, validatePageTransition) \
    M(themeBg, "themeBg", QString, "", "theme", "高级自定义:窗口底色 #RRGGBB(空 = 用预设)", "", "", "", Hidden, nullptr, nullptr) \
    M(themeSurface, "themeSurface", QString, "", "theme", "高级自定义:面板/卡片底色 #RRGGBB(空 = 用预设)", "", "", "", Hidden, nullptr, nullptr) \
    M(themeTextPrimary, "themeTextPrimary", QString, "", "theme", "高级自定义:主文字色 #RRGGBB(空 = 用预设)", "", "", "", Hidden, nullptr, nullptr) \
    M(themeTextMuted, "themeTextMuted", QString, "", "theme", "高级自定义:次级文字色 #RRGGBB(空 = 用预设)", "", "", "", Hidden, nullptr, nullptr) \
    M(themeAccent, "themeAccent", QString, "", "theme", "高级自定义:强调色 #RRGGBB(空 = 用预设)", "", "", "", Hidden, nullptr, nullptr) \
    M(themeAccentSoft, "themeAccentSoft", QString, "", "theme", "高级自定义:浅强调(悬停提亮/浅色文字)#RRGGBB(空 = 用预设)", "", "", "", Hidden, nullptr, nullptr) \
    M(themeAccentDeep, "themeAccentDeep", QString, "", "theme", "高级自定义:深强调(按压/深描边)#RRGGBB(空 = 用预设)", "", "", "", Hidden, nullptr, nullptr) \
    M(themeAccentGlow, "themeAccentGlow", QString, "", "theme", "高级自定义:光晕(带 alpha,写 #AARRGGBB)#RRGGBB(空 = 用预设)", "", "", "", Hidden, nullptr, nullptr) \
    M(themeAccentInk, "themeAccentInk", QString, "", "theme", "高级自定义:强调底上的文字色 #RRGGBB(空 = 用预设)", "", "", "", Hidden, nullptr, nullptr) \
    M(themeAccentWarm, "themeAccentWarm", QString, "", "theme", "高级自定义:次级暖强调(徽标/收藏点缀)#RRGGBB(空 = 用预设)", "", "", "", Hidden, nullptr, nullptr) \
    M(themeBaseTop, "themeBaseTop", QString, "", "theme", "高级自定义:背景渐变起色 #RRGGBB(空 = 用预设)", "", "", "", Hidden, nullptr, nullptr) \
    M(themeBaseBottom, "themeBaseBottom", QString, "", "theme", "高级自定义:背景渐变终色 #RRGGBB(空 = 用预设)", "", "", "", Hidden, nullptr, nullptr) \
    M(themeGlowA, "themeGlowA", QString, "", "theme", "高级自定义:背景光团 A 颜色 #RRGGBB(空 = 用预设)", "", "", "", Hidden, nullptr, nullptr) \
    M(themeGlowB, "themeGlowB", QString, "", "theme", "高级自定义:背景光团 B 颜色 #RRGGBB(空 = 用预设)", "", "", "", Hidden, nullptr, nullptr) \
    M(themeGlowC, "themeGlowC", QString, "", "theme", "高级自定义:背景光团 C 颜色 #RRGGBB(空 = 用预设)", "", "", "", Hidden, nullptr, nullptr) \
    M(librarySortBy, "sortBy", QString, "DateModified", "library", "默认排序字段(Emby SortBy 值)", "媒体库", "默认排序", "媒体库默认排序字段,仅在没有浏览状态可恢复时生效。", Combo, optionsLibrarySortBy, nullptr) \
    M(librarySortOrder, "sortOrder", QString, "Descending", "library", "默认排序方向(Emby SortOrder 值)", "媒体库", "排序方向", "媒体库默认排序方向。", Combo, optionsLibrarySortOrder, nullptr) \
    M(detailSidebarLeft, "sidebarLeft", bool, false, "detail", "详情页选集/季栏靠左(true)/靠右(false)", "详情页", "选集栏靠左", "开启后选季/选集栏靠左显示;默认靠右。", Switch, nullptr, nullptr) \
    M(detailPosterPos, "posterPos", QString, "bottom-left", "detail", "海报位置 9 宫格:top/middle/bottom × left/center/right(默认 bottom-left)", "详情页", "海报位置", "详情页海报在 hero 区的九宫格位置。", Combo, optionsDetailPosterPos, validatePosterPos) \
    M(detailTextPos, "textPos", QString, "followPoster", "detail", "标题+介绍位置:followPoster(跟随海报)/9 宫格", "详情页", "标题与介绍位置", "跟随海报,或固定于 hero 区九宫格位置(优先于海报)。", Combo, optionsDetailTextPos, validateTextPos) \
    M(detailButtonsPos, "buttonsPos", QString, "poster", "detail", "播放/收藏/已看按钮组:text(标题)/poster(海报)/backdrop(背景左下)", "详情页", "按钮组位置", "播放/收藏/已看按钮组:跟随标题、跟随海报,或背景图左下角。", Combo, optionsDetailButtonsPos, validateButtonsPos) \
    M(detailTextWidth, "textWidth", int, 280, "detail", "标题+介绍区固定宽度(像素,不随内容自适应;默认 280)", "详情页", "文字区宽度", "标题+介绍区固定宽度(px),默认 280。", Field, nullptr, validateWheelStep) \
    M(detailTextHeight, "textHeight", int, 140, "detail", "标题+介绍区固定高度(像素,不随内容自适应;默认 140)", "详情页", "文字区高度", "标题+介绍区固定高度(px),默认 140。", Field, nullptr, validateWheelStep) \
    M(proxy, "proxy", QString, "", "network", "全局代理(空=直连):http://host:port 或 https://host:port(HTTP 代理,https 目标走 CONNECT 隧道;可带 user:pass@ 认证;仅支持 HTTP,播放经 mpv --http-proxy)", "代理", "代理地址", "仅支持 HTTP 代理(http:// 或 https://,https 目标走 CONNECT 隧道),可带 user:pass@ 认证;SOCKS 不支持。留空 = 直连;非法值忽略并回退直连。", Field, nullptr, validateProxy) \
    M(searchLimitPerAccount, "searchLimitPerAccount", int, 10, "search", "搜索每账号结果条数(一次上限,1-100;默认 10)", "界面", "搜索每账号条数", "搜索浮窗每台服务器最多返回的结果数(不翻页,1-100);修改后立即生效。", Field, nullptr, validateSearchLimit) \
    M(superRes, "superRes", QString, "off", "video", "Anime4K 超分预设(shader 链档位;mpv 内 CTRL+0..8 可即时切换)", "播放", "超分(Anime4K)", "Anime4K shader 链档位:模式 A/B/C 为一次放大(分别优化 1080p/720p/降采样源),A+/B+/C+A 为二次放大(仅放大比 ≥2 倍时用),去噪/去模糊两档无尺寸门槛。CNN 放大 pass 要求输出大于片源 1.2 倍,窗口不够大时该段不生效(mpv 内按 CTRL+0 关闭)。", Combo, optionsSuperRes, validateSuperRes) \
    M(playerBackend, "playerBackend", QString, "embedded", "video", "播放后端:embedded(内嵌 libmpv,QML 界面)/external(外部 mpv 进程,内建 OSC 界面)", "播放", "播放后端", "内嵌:视频在应用窗口内渲染,界面为应用主题的控制层(官方安装包/AppImage 已自带 libmpv;其余场景缺库自动回退外部);外部:弹独立 mpv 窗口(需自备 mpv,mpv 原生 OSC)。", Combo, optionsPlayerBackend, validatePlayerBackend) \
    M(historyView, "historyView", QString, "timeline", "history", "播放历史视图:timeline(时间轴)/grid(网格)", "", "", "", Hidden, optionsHistoryView, validateHistoryView) \
    M(serverManagerView, "serverManagerView", QString, "grid", "servermanager", "服务器管理视图:grid(网格)/tree(树状)", "", "", "", Hidden, optionsServerManagerView, validateServerManagerView) \
    M(historyAggregate, "historyAggregate", bool, false, "history", "播放历史聚合同一剧的多集记录(仅分集条目)", "", "", "", Hidden, nullptr, nullptr) \
    M(shortcutBack, "shortcutBack", QString, "Alt+Left", "shortcut", "返回键(QKeySequence 文本;| 分隔多键位)", "快捷键", "返回", "返回上一页;浮层打开时优先关浮层。", Field, nullptr, validateShortcut) \
    M(shortcutHome, "shortcutHome", QString, "Alt+Home", "shortcut", "回首页清栈键(| 分隔多键位)", "快捷键", "回首页", "回到首页并清空页面栈。", Field, nullptr, validateShortcut) \
    M(shortcutSearch, "shortcutSearch", QString, "Ctrl+K|Ctrl+F|/", "shortcut", "搜索键(| 分隔多键位)", "快捷键", "搜索", "打开/关闭搜索浮层。", Field, nullptr, validateShortcut) \
    M(shortcutSettings, "shortcutSettings", QString, "Ctrl+,", "shortcut", "设置键(| 分隔多键位)", "快捷键", "设置", "打开/关闭设置浮层。", Field, nullptr, validateShortcut) \
    M(shortcutServerManager, "shortcutServerManager", QString, "Ctrl+O", "shortcut", "服务器管理键(| 分隔多键位)", "快捷键", "服务器管理", "打开服务器管理页。", Field, nullptr, validateShortcut) \
    M(shortcutRevealHidden, "shortcutRevealHidden", QString, "Alt+S", "shortcut", "临时露出隐藏项键(| 分隔多键位)", "快捷键", "露出隐藏项", "临时显示已隐藏的服务器与文件夹(仅本次运行,不持久化)。", Field, nullptr, validateShortcut) \
    M(mouseGesture, "mouseGesture", bool, true, "shortcut", "鼠标手势:中键左滑返回/上滑回首页(false 关闭;后退侧键不受此开关影响)", "快捷键", "中键手势", "鼠标中键按住向左滑动 = 返回上一页,向上滑动 = 回首页清栈;中键按在文本框上时让位给粘贴。", Switch, nullptr, nullptr)

// 表构建行(元数据;宏行即真相)。
#define MOECONFIG_ITEM_ROW(n, tk, t, d, s, c, us, l, ds, w, o, v) \
    { #n, tk, MoeConfig_Type_##t, QVariant(d), s, c, us, l, ds, MoeConfig::Widget::w, o, v },

// 类内展开:属性外壳 / 访问器 / 信号 / emit 链。
#define MOECONFIG_PROP(n, tk, t, ...) Q_PROPERTY(t n READ n WRITE set##n NOTIFY n##Changed)
#define MOECONFIG_ACCESSOR(n, tk, t, d, ...) \
    t n() const { return m_values.value(QStringLiteral(#n), QVariant(d)).value<t>(); } \
    void set##n(t v) { setValue(QStringLiteral(#n), QVariant(v)); }
#define MOECONFIG_SIGNAL(n, ...) void n##Changed();
#define MOECONFIG_EMIT(n, ...) if (key == QLatin1String(#n)) { emit n##Changed(); return; }
#define MOECONFIG_EMIT_ALL(n, ...) emit n##Changed();

// 元数据表(静态;编译期默认值真相)。
inline const QVector<Item> &items()
{
    static const QVector<Item> t = {
        MOECONFIG_X(MOECONFIG_ITEM_ROW)
    };
    return t;
}

// 按键取表项,未知键返回 nullptr。
inline const Item *itemFor(const QString &key)
{
    for (const Item &it : items())
        if (QString::fromUtf8(it.name) == key)
            return &it;
    return nullptr;
}
} // namespace MoeConfig

//! TOML 用户配置(QML 单例 "MoePlayer.Core ConfigManager")。
//!
//! 文件:AppPaths::configDir()/config.toml(默认 ~/.config/MoePlayer/,
//! 便携模式 = exe 旁 data/config/)。用户可直接编辑:启动时读取,
//! 外部修改经 QFileSystemWatcher 热重载(值变化才发 NOTIFY,QML 绑定
//! 自动更新,无需重启)。
//!
//! 后端 toml++ v3.4.0(third_party/tomlplusplus,MIT 单头);写回用
//! QSaveFile 原子替换(临时文件 + rename,崩溃不损坏旧配置)。
//!
//! 范围约定:敏感数据(账号密码/凭据)与服务器地址仍由 accounts.json
//! 由 AccountManager 的 accounts.json(0600)管理,不落入明文 TOML;本类只管
//! 用户可自定义的展示/浏览设置。
class ConfigManager : public QObject
{
    Q_OBJECT
    // 配置属性由 MoeConfig 表单一真相经宏生成(getter/setter/信号)。
    MOECONFIG_X(MOECONFIG_PROP)
    // 配置文件绝对路径(只读,供 UI 展示/排障)。
    Q_PROPERTY(QString configPath READ configPath CONSTANT)
    // 设置浮窗枚举(可见配置项;条目含 UI 元数据/控件类型/选项)。
    Q_PROPERTY(QVariantList items READ items CONSTANT)
public:
    explicit ConfigManager(QObject *parent = nullptr);

    // 生成属性访问器:getter 读 map(缺键回默认);setter 转发 setValue。
    MOECONFIG_X(MOECONFIG_ACCESSOR)

    // 当前代理(按 proxy 串解析;空/非法 = NoProxy)。网络层每请求现取,
    // 热重载后新请求自动用新代理。
    QNetworkProxy proxyObject() const;
    QString configPath() const { return m_path; }

    // 统一读写通道(数据化/脚本/调试);绑定读仍走属性(setValue 在绑定
    // 中不追踪,value 仅限非绑定调用)。
    Q_INVOKABLE bool setValue(const QString &key, const QVariant &v);
    Q_INVOKABLE QVariant value(const QString &key) const;
    // 从磁盘重读配置(丢弃内存未落盘改动;热重载内部也走这里)。
    Q_INVOKABLE void reload();
    // 恢复默认值并立即写回。
    Q_INVOKABLE void resetToDefaults();
    // 设置浮窗枚举(见 Q_PROPERTY items)。
    QVariantList items() const;

signals:
    MOECONFIG_X(MOECONFIG_SIGNAL)
    // 任意配置变化(含热重载/恢复默认;key 空串 = 全量)。UI 同步/脚本用,
    // 属性级信号(NOTIFY)仍单独发,保持 QML 绑定粒度。
    void configChanged(const QString &key);

private:
    // 解析文件并应用(缺失/类型不合法回退默认值;解析失败仅告警不崩溃)。
    void loadFromFile();
    // 以当前内存值重写文件(表生成注释模板;原子写)。
    void commit();
    // 外部修改入队:防抖后重载(自写回经 m_suppressReload 跳过)。
    void scheduleReload();
    // 按 key 发对应属性信号(宏展开 if-链)。
    void emitChangedFor(const QString &key);

    QVariantMap m_values;      // 运行时值(map,唯一真相;缺键时访问器回默认)
    // 用户显式配置的键(值≠默认);写回只写这些键,其余用默认。
    QSet<QString> m_overrides;
    QString m_path;
    QFileSystemWatcher *m_watcher = nullptr;
    QTimer *m_reloadTimer = nullptr;
    // 自己 commit 触发 fileChanged 时置位,避免自触发重载。
    bool m_suppressReload = false;
};