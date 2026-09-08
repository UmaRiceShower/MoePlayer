#pragma once

#include <QtCore/qlogging.h>

//! 文件日志:qInstallMessageHandler 把 Qt 消息(C++ q* 与 QML console.*)
//! 同时写文件与 stderr,便于桌面启动(无终端)时定位问题。
namespace AppLog {
//! 安装消息处理器;日志文件 AppConfigLocation/logs/moeplayer.log,超 1MB 启动轮转。
void install();
//! 级别过滤:低于该级别的消息不进文件也不写 stderr(默认 QtInfoMsg——
//! 滤掉 qDebug/console.debug 调试噪音,保留 qInfo/qWarning/qCritical 流程
//! 与错误;mpv 转发日志为 qInfo 级,默认级别下仍全量保留)。
void setLevel(QtMsgType level);
}
