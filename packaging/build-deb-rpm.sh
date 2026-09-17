set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$SRC_DIR/dist}"
mkdir -p "$OUT_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -C "$SRC_DIR" --exclude=build --exclude=dist --exclude=.git -cf - . | tar -C "$WORK" -xf -

echo "==> DEB(Debian trixie,Qt 6.8.2)"
docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -v "$WORK:/src" -w /src debian:trixie bash -c '
  set -e
  apt-get update -qq
  apt-get install -y -qq cmake ninja-build g++ dpkg-dev file \
    qt6-base-dev qt6-declarative-dev qt6-websockets-dev qt6-shadertools-dev libmpv-dev
  cmake -B build-deb -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
  cmake --build build-deb --parallel "$(nproc)"
  cd build-deb && cpack -G DEB
  chown -R "$HOST_UID:$HOST_GID" /src/build-deb
'
cp "$WORK"/build-deb/*.deb "$OUT_DIR/"

echo "==> RPM(Fedora 42,Qt 6.9)"
docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -v "$WORK:/src" -w /src fedora:42 bash -c '
  set -e
  dnf install -y -q cmake ninja-build gcc-c++ rpm-build \
    qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtwebsockets-devel qt6-qtshadertools-devel mpv-libs-devel
  cmake -B build-rpm -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
  cmake --build build-rpm --parallel "$(nproc)"
  cd build-rpm && cpack -G RPM
  chown -R "$HOST_UID:$HOST_GID" /src/build-rpm
'
cp "$WORK"/build-rpm/*.rpm "$OUT_DIR/"

ls -lh "$OUT_DIR"/*.deb "$OUT_DIR"/*.rpm
