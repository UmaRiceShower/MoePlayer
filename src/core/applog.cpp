#include "applog.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>

#include <QtCore/qlogging.h>

#include <cstdio>

namespace {
// 轮转阈值:单文件超过 1MB 时启动轮转(旧文件顺延 .old,留 1 份)。
constexpr qint64 kRotateBytes = 1024 * 1024;

QFile *g_logFile = nullptr;
// 级别过滤:低于该级别的消息(数值 QtDebugMsg < QtInfoMsg < ...)直接丢弃。
// 默认 QtInfoMsg:滤 qDebug/console.debug 调试噪音;流程(qInfo)与错误保留。
QtMsgType g_minLevel = QtInfoMsg;

const char *levelName(QtMsgType type)
{
    switch (type) {
    case QtDebugMsg: return "DEBUG";       // QML console.log / qDebug
    case QtInfoMsg: return "INFO";         // qInfo
    case QtWarningMsg: return "WARN";      // qWarning / QML console.warn
    case QtCriticalMsg: return "ERROR";    // qCritical / QML console.error
    case QtFatalMsg: return "FATAL";
    }
    return "?";
}

// 消息处理器:仅写 stderr 与文件,禁止再触发任何日志调用(会递归进
// 本 handler)。QFile 写入/flush 本身不产生日志。
void messageHandler(QtMsgType type, const QMessageLogContext &ctx, const QString &msg)
{
    if (type < g_minLevel)
        return;
    // 状态行(消息以 \r 开头,mpv 进度行):终端回 \r 单行原位覆盖,
    // 文件仍逐行(去掉 \r 前缀)——与 mpv 在 tty 上的官方表现一致。
    // 其余消息:默认格式,stderr 与文件一致。
    if (msg.startsWith(QLatin1Char('\r'))) {
        const QString body = msg.mid(1);
        fprintf(stderr, "\r%s", qPrintable(body));
        if (g_logFile) {
            const QString line = QStringLiteral("%1 %2 %3\n")
                .arg(QDateTime::currentDateTime().toString(QStringLiteral("yyyy-MM-dd HH:mm:ss.zzz")))
                .arg(QLatin1String(levelName(type)))
                .arg(body);
            g_logFile->write(line.toUtf8());
            g_logFile->flush();
        }
        return;
    }
    // 默认格式(含 file:line/类别),stderr 与文件一致,定位信息不丢失。
    const QString formatted = qFormatLogMessage(type, ctx, msg);
    // stderr 保留(终端启动调试);终端不存在时 Qt 忽略该写。
    fprintf(stderr, "%s\n", qPrintable(formatted));
    if (!g_logFile)
        return;
    const QString line = QStringLiteral("%1 %2 %3\n")
        .arg(QDateTime::currentDateTime().toString(QStringLiteral("yyyy-MM-dd HH:mm:ss.zzz")))
        .arg(QLatin1String(levelName(type)))
        .arg(formatted);
    g_logFile->write(line.toUtf8());
    g_logFile->flush();
}
} // namespace

void AppLog::install()
{
    if (g_logFile)
        return;
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation)
                        + QStringLiteral("/logs");
    QDir().mkpath(dir);
    const QString path = dir + QStringLiteral("/moeplayer.log");
    // 启动轮转:日志过大时旧文件先删 .old 再顺延,避免 rename 覆盖失败。
    const QFileInfo info(path);
    if (info.exists() && info.size() > kRotateBytes) {
        QFile::remove(path + QStringLiteral(".old"));
        if (!QFile::rename(path, path + QStringLiteral(".old")))
            fprintf(stderr, "AppLog: 日志轮转失败(无法重命名 %s)\n", qPrintable(path));
    }
    auto *file = new QFile(path);
    if (file->open(QIODevice::WriteOnly | QIODevice::Append))
        g_logFile = file;
    else {
        // handler 尚未安装,不能用 qWarning;直接写 stderr 告知。
        fprintf(stderr, "AppLog: 无法打开日志文件 %s: %s\n", qPrintable(path),
                qPrintable(file->errorString()));
        delete file;
    }
    qInstallMessageHandler(messageHandler);
}

void AppLog::setLevel(QtMsgType level)
{
    g_minLevel = level;
}
