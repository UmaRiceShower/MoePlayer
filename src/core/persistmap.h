#pragma once

#include <QByteArray>
#include <QString>
#include <QVariant>

class QSettings;

//! 程序文档持久化统一封装:配置层 QSettings 单键 JSON + 缓存层
//! 缓存根(AppPaths::cacheDir())/<name>.json(QSaveFile 原子写)。共享语义:
//!  - 版本头 { v, data }(首版 1):无头数据(开发期历史)按当前版本原样
//!    读出,静默兼容;v<当前 → migrate 钩子;v>当前 → 回默认 + 告警;
//!  - 读失败回默认;错误内部统一 qWarning(key + 原因);
//!  - 缺键/缺文件 = 首次启动常态,静默回默认(不告警);
//!  - 缓存损坏(坏 JSON/版本回退)= 可重建件,删除重来。
//! 域转换(struct↔QVariantMap)由调用方做,本类不碰业务结构。
class PersistMap
{
public:
    explicit PersistMap(QSettings *settings, const QString &cacheBase);
    PersistMap(const PersistMap &) = delete; // 单实例归属,防拷贝

    // 配置层:QSettings 单键 JSON;写后 sync()+status()==NoError 检查
    // (失败 qWarning并返回 false)。读失败(缺键静默/坏 JSON/版本回退
    // qWarning)out 置 def 并返回 false。
    bool loadSettings(const QString &key, QVariant &out, const QVariant &def);
    bool saveSettings(const QString &key, const QVariant &value);

    // 缓存层:CacheLocation/<name>.json;QSaveFile 原子写。文件缺失静默
    // 返回 false(首次启动常态);损坏(坏 JSON/版本回退)删除文件重来
    // (可重建件),qWarning 并返回 false。
    bool loadCache(const QString &name, QVariant &out);
    bool saveCache(const QString &name, const QVariant &value);

    // 当前结构版本(首版 1)。未来结构变更递增并挂 migrate。
    static constexpr int kCurrentVer = 1;

private:
    // 解开版本头:raw 为介质层读出的 JSON 字符串。无 v 键(开发期无头
    // 数据)按当前版本原样读出(静默兼容,无迁移逻辑——没有历史);
    // v<当前 → migrate(迁移不落盘,下次保存自然写新结构);v>当前(未来
    // 版回退)→ 回默认 + qWarning。解析失败/缺 data → qWarning + 回默认。
    // 返回 false 表示值不可用(调用方用 def/默认)。
    bool loadInner(const QString &raw, const QVariant &def, QVariant &out,
                   const QString &key);
    // 包版本头并序列化为紧凑 JSON 字符串。
    QByteArray saveInner(const QVariant &value);
    // 版本迁移钩子:默认空实现 + qWarning;未来结构变更在此按版本逐级挂。
    void migrate(int fromVer, QVariant &data);

    QSettings *m_settings;
    QString m_cacheBase;
};