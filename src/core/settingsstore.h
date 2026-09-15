#pragma once

#include <QObject>
#include <QSettings>

#include "core/apppaths.h"
#include "core/constants.h"
#include <QtQml/qqmlregistration.h>

//! QSettings 持久化的用户设置(QML 单例 "MoePlayer.Core SettingsStore")。
//! 无外部依赖,由 qmltyperegistrar 自动注册为单例(引擎创建实例;
//! 存储路径经 AppPaths 统一分配,便携模式重定向见 apppaths.h)。
class SettingsStore : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QString serverUrl READ serverUrl WRITE setServerUrl NOTIFY serverUrlChanged)
public:
    explicit SettingsStore(QObject *parent = nullptr);

    // 读取 Emby 服务器地址(键 network/serverUrl)。
    QString serverUrl() const;
    // 写入服务器地址,值未变化时不落盘不发信号。
    void setServerUrl(const QString &v);

signals:
    void serverUrlChanged();

private:
    // 存储路径经 AppPaths 统一分配:便携模式(exe 旁 portable_mode.txt)
    // 重定向到 <exeDir>/data/config/MoePlayer.ini;非便携探测取得既有
    // 平台路径,与历史构造逐字节一致(存量配置不迁移)。详见 apppaths.h。
    QSettings m_settings{AppPaths::settingsFilePath(), AppPaths::settingsFormat()};
};
