#pragma once

#include <QObject>
#include <QSet>
#include <QVariantMap>

class PosterProvider;

//! 海报莫奈取色器(简化 Monet):从海报提取背景氛围色(heroFrom)与强调色(accent)。
//! 零第三方依赖自研:HSV 过滤(丢弃近黑/近白/低饱和)→ 中位切分量化 →
//! 饱和×亮度加权打分选 source 色 → 按 HSL 推导角色色(背景调暗降饱和、强调提饱和)。
//! 结果按海报 id 缓存进 colors map,QML 绑定 ColorProvider.colors[id] 自动更新;
//! 复用 PosterProvider 的缓存/回源加载,不新增网络请求。
class ColorProvider : public QObject
{
    Q_OBJECT
    // posterId → { heroFrom: "#rrggbb", accent: "#rrggbb" }
    Q_PROPERTY(QVariantMap colors READ colors NOTIFY colorsChanged)
public:
    explicit ColorProvider(PosterProvider *posters);

    QVariantMap colors() const;

    // 请求对某张海报取色(幂等:已在取/已取到则忽略)。
    Q_INVOKABLE void requestColor(const QString &posterId);

    // 从图片提取角色色(供测试/复用):heroFrom=暗色背景,accent=亮色强调。
    static QVariantMap extractRoles(const QImage &image);

signals:
    void colorsChanged();

private slots:
    // 后台任务回填(GUI 线程执行):存 map 并广播重绑定。
    void onColorReady(const QString &posterId, const QVariantMap &roles);

private:
    PosterProvider *m_posters;
    QVariantMap m_colors;
    QSet<QString> m_pending;
};
