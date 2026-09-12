set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$SRC_DIR/build}"
OUT_DIR="${1:-$SRC_DIR/dist}"
TOOLS_DIR="$OUT_DIR/.tools"
APPDIR="$OUT_DIR/AppDir"
APP_ID="io.github.umariceshower.MoePlayer"
VERSION="$(sed -n 's/^project(MoePlayer VERSION \([0-9.]*\).*/\1/p' "$SRC_DIR/CMakeLists.txt")"

mkdir -p "$OUT_DIR" "$TOOLS_DIR"

cmake -B "$BUILD_DIR" -S "$SRC_DIR" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build "$BUILD_DIR" --parallel "$(nproc)"
rm -rf "$APPDIR"
DESTDIR="$APPDIR" cmake --install "$BUILD_DIR"

fetch() {
    [ -x "$2" ] || { echo "下载 $(basename "$2")"; curl -fL --retry 3 -o "$2" "$1"; chmod +x "$2"; }
}
fetch https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage \
      "$TOOLS_DIR/linuxdeploy.AppImage"
fetch https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage \
      "$TOOLS_DIR/linuxdeploy-plugin-qt.AppImage"

if [ "${MOEPLAYER_BUNDLE_MPV:-0}" = "1" ]; then
    cp "$(command -v mpv)" "$APPDIR/usr/bin/mpv"
    echo "已内置 mpv:$(mpv --version | head -1)"
fi

export APPIMAGE_EXTRACT_AND_RUN=1
export QML_SOURCES_PATHS="$SRC_DIR/qml"
export NO_STRIP=1

QT_PLUGINS_DIR="$(qmake6 -query QT_INSTALL_PLUGINS 2>/dev/null || echo /usr/lib/qt6/plugins)"
EXTRA_PLUGINS=""
for p in libqwayland.so libqwayland-egl.so libqwayland-generic.so; do
    [ -f "$QT_PLUGINS_DIR/platforms/$p" ] && EXTRA_PLUGINS="${EXTRA_PLUGINS:+$EXTRA_PLUGINS;}$p"
done
if [ -n "$EXTRA_PLUGINS" ]; then
    export EXTRA_PLATFORM_PLUGINS="$EXTRA_PLUGINS"
else
    echo "警告:未找到 Wayland 平台插件,产物仅支持 X11/XWayland" >&2
fi
export OUTPUT="$OUT_DIR/MoePlayer-${VERSION}-x86_64.AppImage"

"$TOOLS_DIR/linuxdeploy.AppImage" --appdir "$APPDIR" --plugin qt --output appimage \
    --desktop-file "$APPDIR/usr/share/applications/$APP_ID.desktop" \
    --icon-file "$APPDIR/usr/share/icons/hicolor/512x512/apps/$APP_ID.png"

ls -lh "$OUTPUT"
