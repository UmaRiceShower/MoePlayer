set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$SRC_DIR/dist}"
APP_ID="io.github.umariceshower.MoePlayer"

mkdir -p "$OUT_DIR"

flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
if ! flatpak info --user "org.kde.Sdk//6.10" >/dev/null 2>&1; then
    echo "==> 安装 KDE runtime(约 400MB)"
    flatpak install --user -y flathub "org.kde.Sdk//6.10" "org.kde.Platform//6.10"
fi

echo "==> 构建(首次含 mpv 编译)"
flatpak-builder --user --force-clean --repo="$OUT_DIR/flatpak-repo" \
    "$OUT_DIR/flatpak-build" "$SRC_DIR/packaging/flatpak/$APP_ID.yml"

flatpak build-bundle "$OUT_DIR/flatpak-repo" "$OUT_DIR/MoePlayer.flatpak" "$APP_ID"
ls -lh "$OUT_DIR/MoePlayer.flatpak"
