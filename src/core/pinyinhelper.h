#pragma once

#include <QObject>
#include <QtQml/qqmlregistration.h>

//! 拼音检索串:把文本中的汉字转成拼音,供本地模糊搜索(全拼、首字母简拼、混合输入)。
//! 拼音数据与多音字取舍见 pinyin_table.h。汉字之外的字符按字面处理:字母数字进入
//! 全拼串与简拼串(便于 "s01e07" 这类混合查询),其余作音节分隔;整串无汉字时返回空。
//! 无状态:同一输入在任何实例上结果一致,可在 QML 里当纯函数调用。
class PinyinHelper : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit PinyinHelper(QObject *parent = nullptr);

    // 返回 "|" 分隔的分段:全拼(音节以空格分隔)、首字母简拼,可能再跟一组同样的
    // 两段(字有次选读音时,即字母不同的多音字,如 乐 le/yue);无汉字返回空串。
    Q_INVOKABLE QString searchKey(const QString &text) const;
};
