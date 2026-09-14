import QtQuick
import MoePlayer.Core

//! 全站统一文字:默认随主题(Theme.textPrimary,亮暗自动切换)。
//! 显式覆盖 color 时保留覆盖色(如次要/强调层级色);
//! 海报/横幅等图片上的文字用 Theme.textOnBadge。
Text {
    color: Theme.textPrimary
}
