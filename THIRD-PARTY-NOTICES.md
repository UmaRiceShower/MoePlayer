# Third-Party Notices

MoePlayer is licensed under the GNU General Public License, version 3
(see `LICENSE`). It builds on the following third-party components:

## Qt 6
- Project usage: GPLv3 (per the project licensing decision).
- License: GNU General Public License v3 (also available under commercial
  and LGPLv3 terms at the licensor's option).
- Homepage: https://www.qt.io / https://doc.qt.io/qt-6/licensing.html

## libmpv / mpv
- Dynamic library used for media playback (render API embedding).
- Built by the distribution with the default GPLv2+ configuration.
- License: GNU General Public License v2 or later.
- Copyright: see https://github.com/mpv-player/mpv/blob/master/Copyright

## mpv-examples (MpvItem adaptation)
- `src/playback/mpvitem.{h,cpp}` is adapted from the QML embedding example
  in https://github.com/mpv-player/mpv-examples (directory `libmpv/qml/`).
- Per that repository's `libmpv/Copyright` file, the example code is
  multi-licensed (WTFPL, ISC, Ms-PL, AGPLv3, BSD — pick any) and may also
  be treated as public domain. This project treats it as ISC.
- License texts: https://opensource.org/licenses/alphabetical
