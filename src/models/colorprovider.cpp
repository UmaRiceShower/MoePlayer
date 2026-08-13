#include "colorprovider.h"

#include <QColor>
#include <QImage>
#include <QPointer>
#include <QRunnable>
#include <QThreadPool>
#include <QUrl>

#include <algorithm>

#include "posterprovider.h"

ColorProvider::ColorProvider(PosterProvider *posters)
    : m_posters(posters)
{
}

QVariantMap ColorProvider::colors() const
{
    return m_colors;
}

// 后台取色任务:解析海报 id → 复用 PosterProvider 缓存/回源加载海报 →
// 提取角色色,经 onColorReady 排队回填 GUI 线程;响应对象销毁时跳过。
namespace {
class ColorTask : public QRunnable
{
public:
    ColorTask(QPointer<ColorProvider> self, PosterProvider *posters, QString posterId)
        : m_self(self)
        , m_posters(posters)
        , m_posterId(std::move(posterId))
    {
    }

    void run() override
    {
        QString serverUrl, token, itemId, tag, kind;
        QVariantMap roles;
        if (m_posters->resolveImageId(m_posterId, &serverUrl, &token, &itemId, &tag, &kind)) {
            const QUrl url = PosterProvider::imageUrl(serverUrl, itemId, tag, kind);
            QString err;
            const QImage img = PosterProvider::loadImageSync(url, token, &err);
            if (!img.isNull())
                roles = ColorProvider::extractRoles(img);
        }
        if (m_self)
            QMetaObject::invokeMethod(m_self, "onColorReady", Qt::QueuedConnection,
                                      Q_ARG(QString, m_posterId), Q_ARG(QVariantMap, roles));
    }

private:
    QPointer<ColorProvider> m_self;
    PosterProvider *m_posters;
    QString m_posterId;
};
} // namespace

void ColorProvider::requestColor(const QString &posterId)
{
    // 幂等:取色中/已取到不再重复。
    if (posterId.isEmpty() || m_colors.contains(posterId) || m_pending.contains(posterId))
        return;
    m_pending.insert(posterId);
    QThreadPool::globalInstance()->start(
        new ColorTask(QPointer<ColorProvider>(this), m_posters, posterId));
}

void ColorProvider::onColorReady(const QString &posterId, const QVariantMap &roles)
{
    m_pending.remove(posterId);
    if (!roles.isEmpty())
        m_colors.insert(posterId, roles);
    emit colorsChanged();
}

namespace {
struct Rgb
{
    quint8 r, g, b;
};

// 中位切分量化:按最宽通道排序后从中间递归切分,到桶数上限或桶内像素过少停止。
void medianCut(const QVector<Rgb> &px, QVector<QVector<Rgb>> &out, int depth,
               int maxBuckets, int minPerBucket)
{
    if (depth >= maxBuckets || px.size() < minPerBucket) {
        out.append(px);
        return;
    }
    int minR = 255, maxR = 0, minG = 255, maxG = 0, minB = 255, maxB = 0;
    for (const Rgb &p : px) {
        minR = qMin(minR, int(p.r));
        maxR = qMax(maxR, int(p.r));
        minG = qMin(minG, int(p.g));
        maxG = qMax(maxG, int(p.g));
        minB = qMin(minB, int(p.b));
        maxB = qMax(maxB, int(p.b));
    }
    const int chan = ((maxR - minR) >= (maxG - minG) && (maxR - minR) >= (maxB - minB))
                         ? 0
                         : ((maxG - minG) >= (maxB - minB) ? 1 : 2);
    QVector<Rgb> sorted = px;
    std::sort(sorted.begin(), sorted.end(), [chan](const Rgb &a, const Rgb &b) {
        return chan == 0 ? a.r < b.r : (chan == 1 ? a.g < b.g : a.b < b.b);
    });
    const int mid = sorted.size() / 2;
    medianCut(sorted.mid(0, mid), out, depth + 1, maxBuckets, minPerBucket);
    medianCut(sorted.mid(mid), out, depth + 1, maxBuckets, minPerBucket);
}
} // namespace

QVariantMap ColorProvider::extractRoles(const QImage &image)
{
    QVariantMap roles;
    if (image.isNull())
        return roles;
    // 缩略采样(≤96px 高,平滑),大幅降低像素遍历量。
    const int h = qMin(96, image.height());
    const QImage src = image.scaledToHeight(h, Qt::SmoothTransformation);

    // 1) HSV 过滤:丢弃近黑/近白/低饱和像素(Monet dislike-filter 思想)。
    QVector<Rgb> px;
    px.reserve(src.width() * src.height());
    for (int y = 0; y < src.height(); ++y) {
        for (int x = 0; x < src.width(); ++x) {
            const QColor c = src.pixelColor(x, y);
            const qreal ss = c.hsvSaturationF();
            const qreal vv = c.valueF();
            if (vv < 0.15 || vv > 0.92 || ss < 0.15)
                continue;
            const QRgb p = src.pixel(x, y);
            px.append({quint8(qRed(p)), quint8(qGreen(p)), quint8(qBlue(p))});
        }
    }
    if (px.isEmpty())
        return roles;

    // 2) 中位切分量化到 16 桶,桶均色按 (0.6S+0.4V)×覆盖率 打分,最高分桶为 source。
    QVector<QVector<Rgb>> buckets;
    medianCut(px, buckets, 0, 16, 32);
    QColor source;
    qreal best = -1.0;
    const qreal total = qreal(px.size());
    for (const QVector<Rgb> &b : buckets) {
        if (b.isEmpty())
            continue;
        qint64 sr = 0, sg = 0, sb = 0;
        for (const Rgb &p : b) {
            sr += p.r;
            sg += p.g;
            sb += p.b;
        }
        const QColor avg(int(sr / b.size()), int(sg / b.size()), int(sb / b.size()));
        const qreal ss = avg.hsvSaturationF();
        const qreal vv = avg.valueF();
        const qreal score = (0.6 * ss + 0.4 * vv) * (qreal(b.size()) / total);
        if (score > best) {
            best = score;
            source = avg;
        }
    }
    if (!source.isValid())
        return roles;

    // 3) 角色色:背景调暗降饱和(深色氛围底),强调提饱和提亮(可读强调)。
    const qreal hh = source.hslHueF();
    const qreal ss = source.hslSaturationF();
    const QColor heroFrom = QColor::fromHslF(hh, qMin<qreal>(1.0, ss * 0.45), 0.22);
    const QColor accent = QColor::fromHslF(hh, qMax<qreal>(0.55, ss), 0.58);
    roles.insert(QStringLiteral("heroFrom"), heroFrom.name());
    roles.insert(QStringLiteral("accent"), accent.name());
    return roles;
}
