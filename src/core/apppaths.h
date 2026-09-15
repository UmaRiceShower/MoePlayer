#pragma once

#include <QSettings>
#include <QString>

class AppPaths
{
public:
    //! 便携检测(每进程一次):exe 旁存在 portable_mode.txt 即便携,
    //! 并预建 data/ 目录(失败仅告警,应用继续可运行)。
    static void init();

    static bool portable();

    //! 配置根:便携 = <exeDir>/data/config;否则 AppConfigLocation。
    static QString configDir();

    //! 缓存根:便携 = <exeDir>/data/cache;否则 CacheLocation。
    static QString cacheDir();

    //! QSettings 文件:便携 = configDir()/MoePlayer.ini(IniFormat);
    //! 非便携 = 现行平台路径(探测构造取得,保证存量配置不迁移)。
    static QString settingsFilePath();

    //! 与 settingsFilePath() 配套的格式:便携恒 IniFormat;非便携
    //! Windows = IniFormat(现行),Linux = NativeFormat(现行)。
    static QSettings::Format settingsFormat();
};
