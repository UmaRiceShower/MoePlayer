#!/usr/bin/env python3
"""生成 src/core/pinyin_table.{h,cpp}:汉字 → 拼音音节表(供本地模糊搜索用)。

数据来源:mozillazg/pinyin-data(MIT 许可),文件 pinyin.txt 逐行形如
    U+4E50: lè,yuè  # 乐
取用其中的 Unicode 表(覆盖 U+4E00..U+9FFF);读音按该项目的常用度排序。

取两个读音:首选 + 次选。只取首选会漏搜字母不同的多音字(乐 lè/yuè、行 xíng/háng、
长 zhǎng/cháng),检索侧据此生成"首选拼法"与"次选拼法"两条检索串,任一命中即可。

ü 统一记作 v(女 nǚ → nv,与中文输入法简拼习惯一致);去声调。

用法:
    curl -o /tmp/pinyin.txt https://raw.githubusercontent.com/mozillazg/pinyin-data/master/pinyin.txt
    python3 tools/gen-pinyin-table.py /tmp/pinyin.txt [输出目录,默认 src/core]
"""
import os
import re
import sys
import unicodedata

FIRST, LAST = 0x4E00, 0x9FFF
READINGS_PER_CHAR = 2
LINE_RE = re.compile(r"^U\+([0-9A-Fa-f]+):\s*([^#]*)")


def norm(pinyin):
    """去声调、ü → v,只留 a-z(如 lǜ → lv,nǚ → nv,lè → le)。"""
    out = []
    for ch in unicodedata.normalize("NFD", pinyin.strip()):
        if unicodedata.combining(ch):
            if ch == "\u0308":          # 分音符 = ü:改写前一个 u 为 v(nǚ → nv,不是 nuv)
                if out and out[-1] == "u":
                    out[-1] = "v"
                else:
                    out.append("v")
            continue
        if ch.isascii() and ch.isalpha():
            out.append(ch.lower())
    return "".join(out)


def load(path):
    """返回 {码点: [读音...]}(最多 READINGS_PER_CHAR 个,按数据顺序)。"""
    table = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#"):
                continue
            m = LINE_RE.match(line)
            if not m:
                continue
            cp = int(m.group(1), 16)
            if not (FIRST <= cp <= LAST):
                continue
            readings = []
            for raw in m.group(2).split(","):
                py = norm(raw)
                if py and py not in readings:
                    readings.append(py)
            if readings:
                table[cp] = readings[:READINGS_PER_CHAR]
    return table


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = sys.argv[1]
    out_dir = sys.argv[2] if len(sys.argv) > 2 else "src/core"
    table = load(src)

    syllables = sorted({py for readings in table.values() for py in readings})
    index = {s: i + 1 for i, s in enumerate(syllables)}   # 0 保留给"无读音"

    primary, secondary = [], []
    for cp in range(FIRST, LAST + 1):
        readings = table.get(cp, [])
        primary.append(index[readings[0]] if readings else 0)
        secondary.append(index[readings[1]] if len(readings) > 1 else 0)

    def emit(values, per_line=16):
        return "\n".join("    " + " ".join("%d," % v for v in values[i:i + per_line])
                         for i in range(0, len(values), per_line))

    header = '''#pragma once

#include <QtGlobal>

//! 汉字 → 拼音音节表(数据见 pinyin_table.cpp):本地模糊搜索的拼音依据。
//! 拼音无调,ü 记作 v(女 = nv);每字两个读音(首选 kPinyinMap、次选 kPinyinMap2,
//! 次选为 0 表示该字只有一个读音),覆盖字母不同的多音字(乐 lè/yuè、行 xíng/háng)。
//! 查找方式:码点 - kPinyinFirst ⇒ 表下标 ⇒ kPinyinSyllables[值 - 1];0 = 无读音。
inline constexpr char32_t kPinyinFirst = 0x%X;   // 一
inline constexpr char32_t kPinyinLast = 0x%X;    // 龿
extern const char *const kPinyinSyllables[];
extern const int kPinyinSyllableCount;
extern const quint16 kPinyinMap[];    // 首选读音
extern const quint16 kPinyinMap2[];   // 次选读音(0 = 无)
''' % (FIRST, LAST)

    source = '''// 本文件由 tools/gen-pinyin-table.py 生成,勿手改。
// 数据来源:mozillazg/pinyin-data(MIT,https://github.com/mozillazg/pinyin-data),
// 取其 Unicode 表;每字取最常用的两个读音,去声调,ü → v。覆盖 U+4E00..U+9FFF,
// 0 = 无读音。再生成方式见 tools/gen-pinyin-table.py 头部注释。
#include "pinyin_table.h"

const char *const kPinyinSyllables[] = {
%s
};

const int kPinyinSyllableCount = %d;

const quint16 kPinyinMap[] = {
%s
};

const quint16 kPinyinMap2[] = {
%s
};
''' % ("\n".join("    " + " ".join('"%s",' % s for s in syllables[i:i + 8])
                 for i in range(0, len(syllables), 8)),
       len(syllables), emit(primary), emit(secondary))

    os.makedirs(out_dir, exist_ok=True)
    for name, text in (("pinyin_table.h", header), ("pinyin_table.cpp", source)):
        with open(os.path.join(out_dir, name), "w", encoding="utf-8") as f:
            f.write(text)
    with_second = sum(1 for cp in range(FIRST, LAST + 1)
                      if len(table.get(cp, [])) > 1)
    print("音节数 %d,覆盖汉字 %d/%d,其中多音字 %d"
          % (len(syllables), len(table), LAST - FIRST + 1, with_second))


if __name__ == "__main__":
    main()
