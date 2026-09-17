# Third-Party Notices

MoePlayer is licensed under the GNU General Public License, version 3
(see `LICENSE`). It builds on the following third-party components:

## Qt 6
- Project usage: GPLv3 (per the project licensing decision).
- License: GNU General Public License v3 (also available under commercial
  and LGPLv3 terms at the licensor's option).
- Homepage: https://www.qt.io / https://doc.qt.io/qt-6/licensing.html

## libmpv / mpv
- Used for media playback (external process, or dynamic library via render API embedding).
- `third_party/mpv/include/mpv/{client,render,render_gl}.h`: client API headers
  vendored from the mpv source tree (ISC license; runtime-loaded, not linked).
- Windows installer/portable zip and the AppImage bundle a prebuilt libmpv
  (`libmpv-2.dll` from shinchiro mpv-winbuild-cmake releases; `libmpv.so.2`
  from the distro package). mpv is GPLv2-or-later; complete corresponding
  sources and build scripts: https://github.com/shinchiro/mpv-winbuild-cmake
  and https://github.com/mpv-player/mpv (and the distribution's source
  packages for the AppImage copy, which is built by the distribution with
  its default configuration).
- License: GNU General Public License v2 or later.
- Copyright: see https://github.com/mpv-player/mpv/blob/master/Copyright

## Anime4K (GLSL shaders)
- `resources/shaders/*.glsl` are the official Anime4K v4.x GLSL shaders
  (v4.0.1 tag), used as mpv user shaders via `--glsl-shaders`.
- https://github.com/bloc97/Anime4K
- License: MIT, except the `Anime4K_AutoDownscalePre_x2/x4.glsl` files, which
  are Unlicense (public domain); see each file's header.

## pinyin-data
- `src/core/pinyin_table.{h,cpp}` is generated from pinyin-data's `pinyin.txt`
  (Chinese character → pinyin readings, Unicode range U+4E00..U+9FFF, the two
  most common readings per character).
- Source: https://github.com/mozillazg/pinyin-data
- License: MIT — Copyright (c) 2016 mozillazg
- Regeneration: `tools/gen-pinyin-table.py` (see its header comment).
