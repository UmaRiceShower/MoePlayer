#pragma once

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

    //! 状态根(日志等):便携 = <exeDir>/data/state;否则 StateLocation。
    static QString stateDir();

    //! 用户数据根:便携 = <exeDir>/data/share;
    //! 内容不因清缓存而丢。
    static QString dataDir();

};
