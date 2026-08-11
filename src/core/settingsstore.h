#pragma once

#include <QObject>
#include <QSettings>

//! QSettings 持久化的用户设置(QML 单例 "MoePlayer.Core SettingsStore")。
class SettingsStore : public QObject
{
    Q_OBJECT
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
    // 默认构造依赖 main.cpp 中已设置的 organizationName/applicationName。
    QSettings m_settings;
};
