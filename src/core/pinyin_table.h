#pragma once

#include <QtGlobal>

//! 汉字 → 拼音音节表(数据见 pinyin_table.cpp):本地模糊搜索的拼音依据。
//! 拼音无调,ü 记作 v(女 = nv);每字两个读音(首选 kPinyinMap、次选 kPinyinMap2,
//! 次选为 0 表示该字只有一个读音),覆盖字母不同的多音字(乐 lè/yuè、行 xíng/háng)。
//! 查找方式:码点 - kPinyinFirst ⇒ 表下标 ⇒ kPinyinSyllables[值 - 1];0 = 无读音。
inline constexpr char32_t kPinyinFirst = 0x4E00;   // 一
inline constexpr char32_t kPinyinLast = 0x9FFF;    // 龿
extern const char *const kPinyinSyllables[];
extern const int kPinyinSyllableCount;
extern const quint16 kPinyinMap[];    // 首选读音
extern const quint16 kPinyinMap2[];   // 次选读音(0 = 无)
