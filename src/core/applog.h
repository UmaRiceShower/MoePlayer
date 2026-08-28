#pragma once

//! 文件日志:qInstallMessageHandler 把 Qt 消息(C++ q* 与 QML console.*)
//! 同时写文件与 stderr,便于桌面启动(无终端)时定位问题。
namespace AppLog {
//! 安装消息处理器;日志文件 AppConfigLocation/logs/moeplayer.log,超 1MB 启动轮转。
void install();
}
