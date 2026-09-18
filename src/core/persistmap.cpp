#include "persistmap.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QSaveFile>

#include <QtGlobal>

// 版本头键名。
namespace {
constexpr auto kVKey = "v";
constexpr auto kDataKey = "data";
} // namespace

PersistMap::PersistMap(QString cacheBase)
    : m_cacheBase(std::move(cacheBase))
{
}

bool PersistMap::loadCache(const QString &name, QVariant &out)
{
    const QString path = m_cacheBase + QLatin1Char('/') + name + QStringLiteral(".json");
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return false; // 首次无缓存:常态,静默
    const QString raw = QString::fromUtf8(f.readAll());
    if (loadInner(raw, QVariant(), out, name))
        return true;
    // 损坏(坏 JSON/版本高于当前):不删文件——历史类是本地独有数据,
    // 读失败也可能只是一次抖动;文件保留,下次成功写自然覆盖自愈。
    qWarning().noquote() << "PersistMap: 缓存读失败,回默认(文件保留)" << path;
    return false;
}

bool PersistMap::saveCache(const QString &name, const QVariant &value)
{
    const QString path = m_cacheBase + QLatin1Char('/') + name + QStringLiteral(".json");
    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly)) {
        qWarning().noquote() << "PersistMap: 缓存写入失败" << path << f.errorString();
        return false;
    }
    f.write(saveInner(value));
    if (!f.commit()) {
        qWarning().noquote() << "PersistMap: 缓存提交失败" << path << f.errorString();
        return false;
    }
    return true;
}

bool PersistMap::loadInner(const QString &raw, const QVariant &def, QVariant &out,
                           const QString &key)
{
    QJsonParseError pe;
    const QJsonDocument doc = QJsonDocument::fromJson(raw.toUtf8(), &pe);
    if (pe.error != QJsonParseError::NoError) {
        qWarning().noquote() << "PersistMap: 数据损坏(坏 JSON)" << key << pe.errorString();
        out = def;
        return false;
    }
    // 无头数据(JSON 数组或无 v 键对象):按当前版本原样读出,静默兼容。
    // ★ 保护存量数据,勿删:首版即带头之前的缓存文件可能长期保持无头
    //   (写回只在数据变化时发生);删掉会把存量读成"损坏"回默认。
    //   这是现状兼容,不是历史迁移链。
    if (doc.isArray() || !doc.object().contains(QLatin1String(kVKey))) {
        out = doc.toVariant();
        return true;
    }
    const QJsonObject o = doc.object();
    const int ver = o.value(QLatin1String(kVKey)).toInt(0);
    if (ver > kCurrentVer) {
        qWarning().noquote() << "PersistMap: 数据版本高于当前,回默认" << key << ver;
        out = def;
        return false;
    }
    if (!o.contains(QLatin1String(kDataKey))) {
        qWarning().noquote() << "PersistMap: 数据缺少 data 段,回默认" << key;
        out = def;
        return false;
    }
    QVariant data = o.value(QLatin1String(kDataKey)).toVariant();
    if (ver < kCurrentVer)
        migrate(ver, data); // 迁移不落盘:下次保存自然写新结构
    out = data;
    return true;
}

QByteArray PersistMap::saveInner(const QVariant &value)
{
    return QJsonDocument(QJsonObject{
                             { QLatin1String(kVKey), kCurrentVer },
                             { QLatin1String(kDataKey), QJsonValue::fromVariant(value) },
                         })
        .toJson(QJsonDocument::Compact);
}

void PersistMap::migrate(int fromVer, QVariant &data)
{
    Q_UNUSED(data)
    // 当前无历史版本(首版 1):不应触发;未来结构变更在此按版本逐级挂
    // 迁移并去掉此告警。
    qWarning().noquote() << "PersistMap: 数据版本" << fromVer << "低于当前,无迁移实现";
}