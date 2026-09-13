#include "pinyinhelper.h"

#include "pinyin_table.h"

namespace {

// ASCII 字母数字:原样进检索串(标题里的 "S01E07"、"4K" 等)。
bool isAsciiWordChar(QChar c)
{
    const ushort u = c.unicode();
    return (u >= u'a' && u <= u'z') || (u >= u'A' && u <= u'Z') || (u >= u'0' && u <= u'9');
}

// 拼一段检索串:useAlt 为假用首选读音,为真用次选读音(该字无次选时回落首选),
// 故 "乐" 在两次调用里分别得到 le 与 yue。返回 "全拼|首字母简拼",无汉字则空串。
QString buildKey(const QString &text, bool useAlt)
{
    QString full;
    QString initials;
    bool hasHan = false;
    for (const QChar c : text) {
        const char32_t cp = c.unicode();
        if (cp >= kPinyinFirst && cp <= kPinyinLast) {
            const quint16 primary = kPinyinMap[cp - kPinyinFirst];
            if (primary == 0)
                continue;   // 表里无此字(冷僻字/未收录)
            const quint16 secondary = kPinyinMap2[cp - kPinyinFirst];
            const quint16 idx = (useAlt && secondary != 0) ? secondary : primary;
            const QString syllable = QString::fromLatin1(kPinyinSyllables[idx - 1]);
            if (!full.isEmpty())
                full += QLatin1Char(' ');
            full += syllable;
            initials += syllable.at(0);
            hasHan = true;
        } else if (isAsciiWordChar(c)) {
            const QChar lower = c.toLower();
            full += lower;
            initials += lower;
        } else if (!full.isEmpty() && !full.endsWith(QLatin1Char(' '))) {
            full += QLatin1Char(' ');
        }
    }
    if (!hasHan)
        return QString();
    return full + QLatin1Char('|') + initials;
}

}   // namespace

PinyinHelper::PinyinHelper(QObject *parent)
    : QObject(parent)
{
}

QString PinyinHelper::searchKey(const QString &text) const
{
    const QString main = buildKey(text, false);
    if (main.isEmpty())
        return QString();
    const QString alternative = buildKey(text, true);
    // 首选与次选拼法一致(无多音字)时只返回一段。
    return alternative == main ? main : main + QLatin1Char('|') + alternative;
}
