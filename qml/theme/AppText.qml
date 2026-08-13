import QtQuick

//! 全站统一文字:白字 + 一圈黑描边,任意(含莫奈彩色)背景可读。
//! 显式覆盖 color 时保留覆盖色(如次要/强调层级色),描边恒生效。
Text {
    color: "white"
    style: Text.Outline
    styleColor: "black"
}
