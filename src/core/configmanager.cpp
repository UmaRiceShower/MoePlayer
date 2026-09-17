#include "core/configmanager.h"

#include "core/apppaths.h"
#include "playback/mpvclient.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QSaveFile>
#include <QTimer>

#include <cmath>

// toml++ 单头(third_party/tomlplusplus,已加入 include 路径)。
#include <toml.hpp>

namespace {

const QString kConfigFileName = QStringLiteral("config.toml");

// 9 宫格位置枚举(海报/文字 grid 态共用)。
const QStringList kGrid9 = {
    QStringLiteral("top-left"), QStringLiteral("top-center"), QStringLiteral("top-right"),
    QStringLiteral("middle-left"), QStringLiteral("middle-center"), QStringLiteral("middle-right"),
    QStringLiteral("bottom-left"), QStringLiteral("bottom-center"), QStringLiteral("bottom-right"),
};
// 文字区位置枚举:followPoster + 9 宫格。
const QStringList kTextPos = {
    QStringLiteral("followPoster"),
    QStringLiteral("top-left"), QStringLiteral("top-center"), QStringLiteral("top-right"),
    QStringLiteral("middle-left"), QStringLiteral("middle-center"), QStringLiteral("middle-right"),
    QStringLiteral("bottom-left"), QStringLiteral("bottom-center"), QStringLiteral("bottom-right"),
};

// 解析代理串为 QNetworkProxy;空串/非法 → NoProxy(直连),并告警。
// 仅支持 HTTP 代理:http:// / https://(Qt 对 https 目标走 CONNECT 隧道),
// 可带 user:pass@ 认证。SOCKS 不支持(mpv 播放流无 SOCKS)。
QNetworkProxy parseProxy(const QString &spec)
{
    const QString trimmed = spec.trimmed();
    if (trimmed.isEmpty())
        return QNetworkProxy::NoProxy;
    const QUrl url(trimmed);
    if ((url.scheme() != QLatin1String("http") && url.scheme() != QLatin1String("https"))
        || !url.isValid() || url.host().isEmpty() || url.port() <= 0 || url.port() > 65535) {
        qWarning().noquote() << "ConfigManager: invalid proxy spec (http/https only), using direct connection:"
                             << trimmed;
        return QNetworkProxy::NoProxy;
    }
    QNetworkProxy p(QNetworkProxy::HttpProxy, url.host(), url.port());
    if (!url.userName().isEmpty()) {
        p.setUser(url.userName());
        p.setPassword(url.password());
    }
    return p;
}

// {label, key} 对列表 → QVariantList(Combo 选项)。
QVariantList optionsFrom(const QList<QPair<QString, QString>> &pairs)
{
    QVariantList out;
    for (const auto &p : pairs) {
        QVariantMap m;
        m.insert(QStringLiteral("label"), p.first);
        m.insert(QStringLiteral("key"), p.second);
        out.append(m);
    }
    return out;
}

// 值 → TOML 字面量(Bool/String/Int;字符串转义引号/反斜杠/换行)。
QString tomlValue(MoeConfig::Type type, const QVariant &v)
{
    switch (type) {
    case MoeConfig::Type::Bool:
        return v.toBool() ? QStringLiteral("true") : QStringLiteral("false");
    case MoeConfig::Type::Int:
        return QString::number(v.toInt());
    case MoeConfig::Type::String: {
        QString s = v.toString();
        s.replace(QStringLiteral("\\"), QStringLiteral("\\\\"))
         .replace(QStringLiteral("\n"), QStringLiteral("\\n"))
         .replace(QStringLiteral("\""), QStringLiteral("\\\""));
        return QLatin1Char('"') + s + QLatin1Char('"');
    }
    }
    return {};
}

// section 引言(写回模板注释,按分组提示)。
QString sectionIntro(const QString &section)
{
    if (section == QLatin1String("theme"))
        return QStringLiteral("# 主题\n");
    if (section == QLatin1String("library"))
        return QStringLiteral("# 媒体库\n");
    if (section == QLatin1String("detail"))
        return QStringLiteral("# 详情页\n");
    if (section == QLatin1String("network"))
        return QStringLiteral("# 网络(代理仅 HTTP;播放经 mpv --http-proxy)\n");
    if (section == QLatin1String("search"))
        return QStringLiteral("# 搜索\n");
    return {};
}

// 值类型匹配(Int 接受 QML parseInt 产生的整数 double)。
bool typeOk(const MoeConfig::Item *it, const QVariant &v)
{
    switch (it->type) {
    case MoeConfig::Type::Bool:
        return v.metaType().id() == QMetaType::Bool;
    case MoeConfig::Type::String:
        return v.metaType().id() == QMetaType::QString;
    case MoeConfig::Type::Int:
        if (v.metaType().id() == QMetaType::Int)
            return true;
        if (v.metaType().id() == QMetaType::Double) {
            const double d = v.toDouble();
            return std::floor(d) == d; // 整数 double(QML parseInt)才接受
        }
        return false;
    }
    return false;
}

} // namespace

// ---------- MoeConfig 钩子(选项/校验;宏表引用) ----------

namespace MoeConfig {

QVariantList optionsLibrarySortBy()
{
    return optionsFrom({
        { QStringLiteral("最近添加"), QStringLiteral("DateLastContentAdded") },
        { QStringLiteral("加入时间"), QStringLiteral("DateCreated") },
        { QStringLiteral("上映日期"), QStringLiteral("PremiereDate") },
        { QStringLiteral("名称"), QStringLiteral("SortName") },
        { QStringLiteral("出品年份"), QStringLiteral("ProductionYear") },
        { QStringLiteral("社区评分"), QStringLiteral("CommunityRating") },
        { QStringLiteral("影评评分"), QStringLiteral("CriticRating") },
        { QStringLiteral("随机"), QStringLiteral("Random") },
        { QStringLiteral("修改时间"), QStringLiteral("DateModified") },
    });
}

QVariantList optionsLibrarySortOrder()
{
    return optionsFrom({
        { QStringLiteral("降序"), QStringLiteral("Descending") },
        { QStringLiteral("升序"), QStringLiteral("Ascending") },
    });
}

QVariantList optionsDetailPosterPos()
{
    return optionsFrom({{ QStringLiteral("左上"), QStringLiteral("top-left") },
                        { QStringLiteral("上中"), QStringLiteral("top-center") },
                        { QStringLiteral("右上"), QStringLiteral("top-right") },
                        { QStringLiteral("左中"), QStringLiteral("middle-left") },
                        { QStringLiteral("正中"), QStringLiteral("middle-center") },
                        { QStringLiteral("右中"), QStringLiteral("middle-right") },
                        { QStringLiteral("左下"), QStringLiteral("bottom-left") },
                        { QStringLiteral("下中"), QStringLiteral("bottom-center") },
                        { QStringLiteral("右下"), QStringLiteral("bottom-right") }});
}

QVariantList optionsDetailTextPos()
{
    return optionsFrom({
        { QStringLiteral("跟随海报"), QStringLiteral("followPoster") },
        { QStringLiteral("左上"), QStringLiteral("top-left") },
        { QStringLiteral("上中"), QStringLiteral("top-center") },
        { QStringLiteral("右上"), QStringLiteral("top-right") },
        { QStringLiteral("左中"), QStringLiteral("middle-left") },
        { QStringLiteral("正中"), QStringLiteral("middle-center") },
        { QStringLiteral("右中"), QStringLiteral("middle-right") },
        { QStringLiteral("左下"), QStringLiteral("bottom-left") },
        { QStringLiteral("下中"), QStringLiteral("bottom-center") },
        { QStringLiteral("右下"), QStringLiteral("bottom-right") },
    });
}

QVariantList optionsDetailButtonsPos()
{
    return optionsFrom({
        { QStringLiteral("跟随标题"), QStringLiteral("text") },
        { QStringLiteral("跟随海报"), QStringLiteral("poster") },
        { QStringLiteral("背景图左下"), QStringLiteral("backdrop") },
    });
}

bool validatePosterPos(const QVariant &v)
{
    return kGrid9.contains(v.toString());
}

bool validateTextPos(const QVariant &v)
{
    return kTextPos.contains(v.toString());
}

bool validateButtonsPos(const QVariant &v)
{
    const QString s = v.toString();
    return s == QLatin1String("text") || s == QLatin1String("poster")
           || s == QLatin1String("backdrop");
}

bool validateProxy(const QVariant &v)
{
    const QString s = v.toString();
    // 空 = 直连(合法);非空需能解析为 HTTP 代理。
    return s.isEmpty() || parseProxy(s).type() != QNetworkProxy::NoProxy;
}

bool validateWheelStep(const QVariant &v)
{
    return v.toInt() >= 1;
}

// 键位文本:非空即可(QKeySequence 容错解析,非法键名 Qt 告警并忽略,
// 空字符串则快捷键彻底死掉,故拒绝)。
bool validateShortcut(const QVariant &v)
{
    return !v.toString().trimmed().isEmpty();
}


QVariantList optionsHistoryView()
{
    return { QVariantMap{ { QStringLiteral("label"), QStringLiteral("时间轴") },
                          { QStringLiteral("key"), QStringLiteral("timeline") } },
             QVariantMap{ { QStringLiteral("label"), QStringLiteral("网格") },
                          { QStringLiteral("key"), QStringLiteral("grid") } } };
}

bool validateHistoryView(const QVariant &v)
{
    const QString s = v.toString();
    return s == QLatin1String("timeline") || s == QLatin1String("grid");
}

QVariantList optionsSuperRes()
{
    return MpvClient::superResOptions();
}

bool validateSuperRes(const QVariant &v)
{
    return MpvClient::superResPreset(v.toString()) != nullptr;
}

QVariantList optionsPlayerBackend()
{
    return QVariantList{
        QVariantMap{{QStringLiteral("label"), QStringLiteral("内嵌(应用内播放)")},
                    {QStringLiteral("key"), QStringLiteral("embedded")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("外部 mpv 窗口")},
                    {QStringLiteral("key"), QStringLiteral("external")}},
    };
}

bool validatePlayerBackend(const QVariant &v)
{
    const QString s = v.toString();
    return s == QLatin1String("embedded") || s == QLatin1String("external");
}

bool validateSearchLimit(const QVariant &v)
{
    const int i = v.toInt();
    return i >= 1 && i <= 100;
}

// 配色方案(与 ThemeStore.palettes 的 key 一一对应)与背景效果(ThemeStore.effects)。
QVariantList optionsThemePalette()
{
    return QVariantList{
        QVariantMap{{QStringLiteral("label"), QStringLiteral("夜樱")},
                    {QStringLiteral("key"), QStringLiteral("yozakura")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("炭黑")},
                    {QStringLiteral("key"), QStringLiteral("sumi")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("星夜")},
                    {QStringLiteral("key"), QStringLiteral("hoshiyo")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("雾紫")},
                    {QStringLiteral("key"), QStringLiteral("kasumi")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("雨蓝")},
                    {QStringLiteral("key"), QStringLiteral("ame")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("夏夜")},
                    {QStringLiteral("key"), QStringLiteral("natsuyo")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("琥珀")},
                    {QStringLiteral("key"), QStringLiteral("kohaku")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("奶白")},
                    {QStringLiteral("key"), QStringLiteral("milk")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("浅樱")},
                    {QStringLiteral("key"), QStringLiteral("hazakura")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("薄荷")},
                    {QStringLiteral("key"), QStringLiteral("mint")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("晴空")},
                    {QStringLiteral("key"), QStringLiteral("sora")}},
    };
}

bool validateThemePalette(const QVariant &v)
{
    static const QStringList keys{QStringLiteral("yozakura"), QStringLiteral("sumi"),
                                  QStringLiteral("hoshiyo"), QStringLiteral("kasumi"),
                                  QStringLiteral("ame"), QStringLiteral("natsuyo"),
                                  QStringLiteral("kohaku"), QStringLiteral("milk"),
                                  QStringLiteral("hazakura"), QStringLiteral("mint"),
                                  QStringLiteral("sora")};
    return keys.contains(v.toString());
}

QVariantList optionsBackgroundEffect()
{
    return QVariantList{
        QVariantMap{{QStringLiteral("label"), QStringLiteral("落樱")},
                    {QStringLiteral("key"), QStringLiteral("sakura")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("萤火")},
                    {QStringLiteral("key"), QStringLiteral("firefly")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("星空流星")},
                    {QStringLiteral("key"), QStringLiteral("starry")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("夜雨")},
                    {QStringLiteral("key"), QStringLiteral("rain")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("无")},
                    {QStringLiteral("key"), QStringLiteral("none")}},
    };
}

bool validateBackgroundEffect(const QVariant &v)
{
    static const QStringList keys{QStringLiteral("sakura"), QStringLiteral("firefly"),
                                  QStringLiteral("starry"), QStringLiteral("rain"),
                                  QStringLiteral("none")};
    return keys.contains(v.toString());
}

QVariantList optionsBackgroundMotion()
{
    return QVariantList{
        QVariantMap{{QStringLiteral("label"), QStringLiteral("静止(不刷新)")},
                    {QStringLiteral("key"), QStringLiteral("off")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("极低频 · 12fps")},
                    {QStringLiteral("key"), QStringLiteral("low")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("流畅 · 30fps")},
                    {QStringLiteral("key"), QStringLiteral("high")}},
    };
}

QVariantList optionsPageTransition()
{
    return QVariantList{
        QVariantMap{{QStringLiteral("label"), QStringLiteral("横向轻移")},
                    {QStringLiteral("key"), QStringLiteral("axis_x")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("纵向上浮")},
                    {QStringLiteral("key"), QStringLiteral("slide_up")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("纯淡入淡出")},
                    {QStringLiteral("key"), QStringLiteral("fade")}},
        QVariantMap{{QStringLiteral("label"), QStringLiteral("横滑视差")},
                    {QStringLiteral("key"), QStringLiteral("ios_slide")}},
    };
}

bool validatePageTransition(const QVariant &v)
{
    static const QStringList keys{QStringLiteral("axis_x"), QStringLiteral("slide_up"),
                                  QStringLiteral("fade"), QStringLiteral("ios_slide")};
    return keys.contains(v.toString());
}

bool validatePercent(const QVariant &v)
{
    const int i = v.toInt();
    return i >= 0 && i <= 100;
}

} // namespace MoeConfig

// ---------- ConfigManager ----------

ConfigManager::ConfigManager(QObject *parent)
    : QObject(parent)
{
    m_path = AppPaths::configDir() + QLatin1Char('/') + kConfigFileName;
    // AppConfigLocation 目录(Qt 不保证存在)须自建,QSaveFile 写回才可打开。
    QDir().mkpath(QFileInfo(m_path).absolutePath());

    // 先填默认值表(commit 渲染/首启生成模板的前提;访问器另有缺键兜底)。
    for (const auto &it : MoeConfig::items())
        m_values.insert(QString::fromUtf8(it.name), it.def);

    // 首次启动:文件不存在则生成完整默认模板(便于用户直接编辑/参考),
    // 模板全部键写入 m_overrides(下次写回保持全键)。
    if (!QFile::exists(m_path)) {
        for (const auto &it : MoeConfig::items())
            m_overrides.insert(QString::fromUtf8(it.name));
        commit();
    }

    loadFromFile();

    // 外部修改热重载:防抖 400ms(编辑器保存常分多次写),值变化才发 NOTIFY。
    m_watcher = new QFileSystemWatcher(this);
    m_watcher->addPath(m_path);
    connect(m_watcher, &QFileSystemWatcher::fileChanged, this, &ConfigManager::scheduleReload);
    m_reloadTimer = new QTimer(this);
    m_reloadTimer->setSingleShot(true);
    m_reloadTimer->setInterval(400);
    connect(m_reloadTimer, &QTimer::timeout, this, &ConfigManager::reload);
}

QNetworkProxy ConfigManager::proxyObject() const
{
    return parseProxy(m_values.value(QStringLiteral("proxy")).toString());
}

bool ConfigManager::setValue(const QString &key, const QVariant &v)
{
    const MoeConfig::Item *it = MoeConfig::itemFor(key);
    if (!it) {
        qWarning() << "ConfigManager: 未知配置键" << key;
        return false;
    }
    if (!typeOk(it, v) || (it->validate && !it->validate(v))) {
        qWarning() << "ConfigManager: 忽略非法值(回退直连/保持当前)" << key << v;
        return false;
    }
    if (m_values.value(key) == v)
        return true; // 幂等:值相同不发信号不写盘
    m_values.insert(key, v);
    // 值≠默认 → 记为用户覆盖(写回);=默认 → 移除(等效删键,下次写回不含)。
    if (v == it->def)
        m_overrides.remove(key);
    else
        m_overrides.insert(key);
    emitChangedFor(key);
    commit();
    return true;
}

QVariant ConfigManager::value(const QString &key) const
{
    const MoeConfig::Item *it = MoeConfig::itemFor(key);
    if (!it)
        return {};
    return m_values.value(key, it->def);
}

QVariantList ConfigManager::items() const
{
    QVariantList out;
    for (const auto &it : MoeConfig::items()) {
        if (it.widget == MoeConfig::Widget::Hidden)
            continue;
        QVariantMap m;
        m.insert(QStringLiteral("uiSection"), QString::fromUtf8(it.uiSection));
        m.insert(QStringLiteral("key"), QString::fromUtf8(it.name));
        m.insert(QStringLiteral("label"), QString::fromUtf8(it.uiLabel));
        m.insert(QStringLiteral("description"), QString::fromUtf8(it.uiDesc));
        // 全部可见项都带 intOnly(SettingItem 无条件绑定,缺失=undefined 赋 bool 报错)。
        m.insert(QStringLiteral("intOnly"),
                 it.type == MoeConfig::Type::Int);
        switch (it.widget) {
        case MoeConfig::Widget::Switch:
            m.insert(QStringLiteral("widget"), QStringLiteral("switch"));
            break;
        case MoeConfig::Widget::Combo:
            m.insert(QStringLiteral("widget"), QStringLiteral("combo"));
            m.insert(QStringLiteral("options"),
                     it.options ? it.options() : QVariantList());
            break;
        case MoeConfig::Widget::Field:
            m.insert(QStringLiteral("widget"), QStringLiteral("field"));
            break;
        case MoeConfig::Widget::Slider:
            m.insert(QStringLiteral("widget"), QStringLiteral("slider"));
            break;
        case MoeConfig::Widget::Hidden:
            break;
        }
        out.append(m);
    }
    return out;
}

void ConfigManager::reload()
{
    // 文件被删除(用户 rm 重置):重挂监视(文件路径 watcher 已失效),保持当前值。
    if (!QFile::exists(m_path)) {
        qInfo() << "ConfigManager: 配置文件被删除,保持当前值并重挂监视";
        m_watcher->addPath(m_path);
        return;
    }
    loadFromFile();
}

void ConfigManager::resetToDefaults()
{
    for (const auto &it : MoeConfig::items())
        m_values.insert(QString::fromUtf8(it.name), it.def);
    // 恢复默认:清空用户覆盖(commit 写回空 diff——仅首启/初次模板仍在时
    // 有覆盖键;此处 m_overrides 清空 = 无键 diff,与"删除文件"等价)。
    m_overrides.clear();
    MOECONFIG_X(MOECONFIG_EMIT_ALL)
    emit configChanged(QString());
    qInfo() << "ConfigManager: 恢复默认配置";
    commit();
}

void ConfigManager::loadFromFile()
{
    try {
        const toml::table cfg = toml::parse_file(m_path.toStdString());
        // 起始 = 全默认,再 merge 文件覆盖;否则用户热重载删键会残留旧值,
        // 删键应归默认。
        for (const auto &it : MoeConfig::items())
            m_values.insert(QString::fromUtf8(it.name), it.def);
        // 收集用户显式配置键(值≠默认);缺键用默认,写回只写这些键。
        QSet<QString> fileOverrides;
        for (const auto &it : MoeConfig::items()) {
            const auto tb = cfg[it.section];
            if (!tb.is_table())
                continue;
            const auto node = tb[it.tomlKey];
            if (!node)
                continue; // 缺键:保持当前(默认)值
            QVariant v;
            bool ok = false;
            switch (it.type) {
            case MoeConfig::Type::Bool: {
                const auto r = node.value<bool>();
                if (r) {
                    v = QVariant(*r);
                    ok = true;
                }
                break;
            }
            case MoeConfig::Type::String: {
                const auto r = node.value<std::string>();
                if (r) {
                    v = QVariant(QString::fromStdString(*r));
                    ok = true;
                }
                break;
            }
            case MoeConfig::Type::Int: {
                const auto r = node.value<int64_t>();
                if (r) {
                    v = QVariant(int(*r));
                    ok = true;
                }
                break;
            }
            }
            if (!ok) {
                qWarning() << "ConfigManager: 类型不合法,回退默认(键" << it.tomlKey << ")";
                // 记入 m_overrides:下次 commit 以默认值纠正该坏键(自愈删除)。
                fileOverrides.insert(QString::fromUtf8(it.name));
                continue;
            }
            if (it.validate && !it.validate(v)) {
                qWarning() << "ConfigManager: 非法值,回退默认" << it.tomlKey << v;
                fileOverrides.insert(QString::fromUtf8(it.name)); // 同上自愈
                continue;
            }
            m_values.insert(QString::fromUtf8(it.name), v);
            // 仅"值≠默认"的键记为用户覆盖;默认值键不写回(值=默认等效删键)。
            if (m_values.value(QString::fromUtf8(it.name), it.def) != it.def)
                fileOverrides.insert(QString::fromUtf8(it.name));
        }
        // 用户覆盖 = 非默认键(热重载后新文件为准)。
        m_overrides = fileOverrides;
        // 值全部来自文件:无条件发 NOTIFY(值相同的绑定更新是幂等的,
        // 避免手改后 QML 侧漏刷新)。
        MOECONFIG_X(MOECONFIG_EMIT_ALL)
        emit configChanged(QString());
        qInfo().noquote() << "ConfigManager: 配置已加载" << m_path;
    } catch (const toml::parse_error &e) {
        qWarning().noquote() << "ConfigManager: TOML parse failed, keeping current values:"
                             << QString::fromUtf8(e.description().data(),
                                                  qsizetype(e.description().size()));
    }
}

void ConfigManager::commit()
{
    // 自写回不触发热重载(否则 fileChanged → reload → 无意义重解析)。
    m_suppressReload = true;
    QString out = QStringLiteral("# MoePlayer 用户配置(TOML)\n"
                                 "# 启动时读取;外部修改后自动热重载(立即生效)。\n"
                                 "# 缺失或类型不合法的键回退默认值;删除本文件即恢复出厂。\n"
                                 "# 敏感数据(账号密码/凭据)不存于此,仍由 QSettings 管理。\n"
                                 "# 仅写用户显式配置过的键(主题高级覆盖项除外,恒列出);未写的键=默认值\n");
    QString cur;
    for (const auto &it : MoeConfig::items()) {
        // 只写用户显式配置过的键(m_overrides);未出现的键用默认,不补写。
        // 例外:字符串型隐藏项(theme* 高级覆盖)总是写出 —— 它们是给用户手改的
        // 占位与文档(空串 = 用预设值),不写出用户无从知道有哪些可调。
        const bool advancedPlaceholder = it.widget == MoeConfig::Widget::Hidden
                                         && it.type == MoeConfig::Type::String;
        if (!m_overrides.contains(QString::fromUtf8(it.name)) && !advancedPlaceholder)
            continue;
        const QString section = QString::fromUtf8(it.section);
        if (section != cur) {
            cur = section;
            out += QStringLiteral("\n[%1]\n").arg(cur);
            out += sectionIntro(cur);
        }
        out += QStringLiteral("# %1\n").arg(QString::fromUtf8(it.comment));
        const QVariant v = m_values.value(QString::fromUtf8(it.name), it.def);
        // 写回用 tomlKey(与磁盘旧键名一致,不破坏用户手改/模板)。
        out += QStringLiteral("%1 = %2\n").arg(QString::fromUtf8(it.tomlKey),
                                               tomlValue(it.type, v));
    }
    QSaveFile file(m_path);
    if (file.open(QIODevice::WriteOnly)) {
        file.write(out.toUtf8());
        if (!file.commit())
            qWarning().noquote() << "ConfigManager: failed to commit" << m_path << file.errorString();
    } else {
        qWarning().noquote() << "ConfigManager: failed to open for write" << m_path << file.errorString();
    }
    m_suppressReload = false;
}

void ConfigManager::scheduleReload()
{
    if (m_suppressReload)
        return;
    // 编辑器保存/原子替换常更换文件 inode,QFileSystemWatcher 在首次
    // fileChanged 后即失效(仍监视旧 inode),须重新挂载,否则后续修改
    // 不再触发(实测:sed -i 一次后热重载即断)。
    m_watcher->removePath(m_path);
    m_watcher->addPath(m_path);
    m_reloadTimer->start();
}

void ConfigManager::emitChangedFor(const QString &key)
{
    MOECONFIG_X(MOECONFIG_EMIT)
    // 未知键在 setValue 已拦截,到此不可达。
    emit configChanged(key);
}