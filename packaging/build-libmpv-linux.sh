#!/bin/bash
set -euo pipefail

PREFIX="${1:-/opt/moeplayer-libmpv}"
FFMPEG_VER=7.1.5
MPV_VER=0.41.0
LIBPLACEBO_VER=7.360.1
JOBS="$(nproc)"
WORK="$PREFIX-src"

# 版本戳:同版本同配置跳过(配合 CI actions/cache 摊销编译时间)
STAMP="$PREFIX/.stamp-mpv$MPV_VER-ffmpeg$FFMPEG_VER-lp$LIBPLACEBO_VER"
if [ -f "$STAMP" ]; then
    echo "已构建($STAMP),跳过"
    exit 0
fi

# CI(jammy)装依赖
if command -v apt-get >/dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
        build-essential git pkg-config ninja-build nasm python3-pip python3-setuptools \
        libass-dev libluajit-5.1-dev libfontconfig-dev libharfbuzz-dev libfribidi-dev \
        libdav1d-dev libgnutls28-dev zlib1g-dev
    pip3 install --quiet --upgrade meson
fi

mkdir -p "$WORK" "$PREFIX"
cd "$WORK"

# ---- ffmpeg:纯播放取向(去编码/复用/设备),保留网络与硬解 ----
[ -f ffmpeg.tar.xz ] || curl -fL --retry 3 -o ffmpeg.tar.xz "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz"
tar xf ffmpeg.tar.xz
cd "ffmpeg-$FFMPEG_VER"
./configure --prefix="$PREFIX" \
    --enable-shared --disable-static --disable-debug --disable-doc \
    --disable-programs --disable-encoders --disable-muxers --disable-devices \
    --disable-xlib --enable-gpl --enable-gnutls --enable-libdav1d
make -j"$JOBS"
make install
cd ..

# ---- libplacebo:mpv 0.36+ 硬依赖;GL 渲染需要 glad(子模块,故 git clone
# 而非 tarball);vulkan 关掉(libmpv GL render 用不到)。----
# tag + commit 双钉(与 flatpak manifest 同):tag 挪动时硬失败,不静默
# 换料(cache key 只看脚本哈希,同名 tag 挪动击不穿缓存)。
LIBPLACEBO_COMMIT=cee9b076f2c63104ccfd497fa79c39a867293ec4
if [ ! -d libplacebo ]; then
    git clone --depth 1 --branch "v$LIBPLACEBO_VER" --recurse-submodules \
        --shallow-submodules https://github.com/haasn/libplacebo
fi
cd libplacebo
[ "$(git rev-parse HEAD)" = "$LIBPLACEBO_COMMIT" ] || \
    { echo "libplacebo tag v$LIBPLACEBO_VER 的 commit 已挪动,拒绝构建" >&2; exit 1; }
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
meson setup build --prefix="$PREFIX" --libdir=lib --buildtype=release \
    -Dvulkan=disabled -Ddemos=false -Dtests=false
ninja -C build install
cd ..

# ---- mpv:仅 libmpv(不建播放器本体),lua 必须(moe-hook 连播承重墙)----
[ -f "mpv.tar.gz" ] || curl -fL --retry 3 -o mpv.tar.gz "https://github.com/mpv-player/mpv/archive/refs/tags/v$MPV_VER.tar.gz"
tar xf mpv.tar.gz
cd "mpv-$MPV_VER"
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
meson setup build --prefix="$PREFIX" --libdir=lib --buildtype=release \
    -Dlibmpv=true -Dcplayer=false -Dlua=luajit -Dgl=enabled \
    -Dvulkan=disabled -Dwayland=disabled -Dx11=disabled
ninja -C build install
cd ..

# 防污染闸:libmpv 的依赖必须全部解析进 $PREFIX(宿主渗入 = 毒包,
# 硬失败);not found 同理。
BAD="$(LD_LIBRARY_PATH="$PREFIX/lib" ldd "$PREFIX/lib/libmpv.so.2" | \
      grep -E "libav|libplacebo|libswresample|libswscale|libpostproc" | \
      grep -vE "\=> $PREFIX/" || true)"
if [ -n "$BAD" ]; then
    echo "宿主渗入/缺失,拒绝收尾:" >&2
    echo "$BAD" >&2
    exit 1
fi

touch "$STAMP"
echo "libmpv $MPV_VER + ffmpeg $FFMPEG_VER + libplacebo $LIBPLACEBO_VER 已装入 $PREFIX"
ls -lh "$PREFIX/lib/libmpv.so.2"
