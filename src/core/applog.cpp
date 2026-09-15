#include "applog.h"
#include "apppaths.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>

#include <QtCore/qlogging.h>
#include <QtGlobal>

#include <cstdio>
#if defined(Q_OS_UNIX)
#include <unistd.h>
#elif defined(Q_OS_WIN)
#include <io.h> // MSVC 的 _isatty/_fileno 在此(glibc 由 stdio 顺带给出)
#endif

namespace {
// 轮转阈值:单文件超过 1MB 时启动轮转(旧文件顺延 .old,留 1 份)。
constexpr qint64 kRotateBytes = 1024 * 1024;

QFile *g_logFile = nullptr;
// 级别过滤:按严重度(DEBUG < INFO < WARN < ERROR < FATAL)丢弃低于
// g_minLevel 的消息。注意 QtMsgType 数值不是严重度顺序(QtDebugMsg=0,
// QtWarningMsg=1, QtCriticalMsg=2, QtFatalMsg=3, QtInfoMsg=4——Info 数值
// 最高),必须经 severity() 映射,不能直接数值比较。
// 默认 QtInfoMsg:滤 qDebug/console.debug 调试噪音;流程(qInfo)与错误保留。
QtMsgType g_minLevel = QtInfoMsg;
// stderr 是否连接到终端(install 时缓存):重定向到文件/管道时终端输出也带
// 时间戳(事后可分析时序),交互终端保持简洁。
bool g_stderrTty = true;

bool stderrIsTty()
{
#if defined(Q_OS_UNIX)
    return ::isatty(::fileno(stderr)) != 0;
#elif defined(Q_OS_WIN)
    return ::_isatty(::_fileno(stderr)) != 0;
#else
    return true;
#endif
}

// QtMsgType → 严重度序(数值无关;默认值取 QtInfoMsg 即保留 Info 及以上)。
int severity(QtMsgType type)
{
    switch (type) {
    case QtDebugMsg: return 0;
    case QtInfoMsg: return 1;
    case QtWarningMsg: return 2;
    case QtCriticalMsg: return 3;
    case QtFatalMsg: return 4;
    }
    return 1;
}

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
    if (severity(type) < severity(g_minLevel))
        return;
    // 时间戳只算一次:终端(重定向时)与日志文件共用,时序一致。
    const QString ts = QDateTime::currentDateTime()
                           .toString(QStringLiteral("yyyy-MM-dd HH:mm:ss.zzz"));
    const QLatin1String lvl(levelName(type));
    // 状态行(消息以 \r 开头,mpv 进度行):终端回 \r 单行原位覆盖(不加
    // 时间戳,否则破坏覆盖),文件仍逐行(去掉 \r 前缀)。
    if (msg.startsWith(QLatin1Char('\r'))) {
        const QString body = msg.mid(1);
        fprintf(stderr, "\r%s", qPrintable(body));
        if (g_logFile) {
            g_logFile->write(QStringLiteral("%1 %2 %3\n").arg(ts, lvl, body).toUtf8());
            g_logFile->flush();
        }
        return;
    }
    // 默认格式(QT_MESSAGE_PATTERN 未设时为「类别: 内容」,不含 file:line)。
    const QString formatted = qFormatLogMessage(type, ctx, msg);
    // 终端:交互 tty 只输出内容(简洁);重定向到文件/管道时补时间戳与
    // 级别,与日志文件格式一致。
    if (g_stderrTty)
        fprintf(stderr, "%s\n", qPrintable(formatted));
    else
        fprintf(stderr, "%s %s %s\n", qPrintable(ts), lvl.data(), qPrintable(formatted));
    if (!g_logFile)
        return;
    g_logFile->write(QStringLiteral("%1 %2 %3\n").arg(ts, lvl, formatted).toUtf8());
    g_logFile->flush();
}
} // namespace

void AppLog::install()
{
    if (g_logFile)
        return;
    const QString dir = AppPaths::configDir() + QStringLiteral("/logs");
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
    g_stderrTty = stderrIsTty();
    qInstallMessageHandler(messageHandler);
}

void AppLog::setLevel(QtMsgType level)
{
    g_minLevel = level;
}
