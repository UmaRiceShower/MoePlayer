#pragma once

#include <QObject>
#include <QSettings>

//! QSettings 持久化的用户设置(QML 单例 "MoePlayer.Core SettingsStore")。
class SettingsStore : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString serverUrl READ serverUrl WRITE setServerUrl NOTIFY serverUrlChanged)
    Q_PROPERTY(QString testStreamUrl READ testStreamUrl WRITE setTestStreamUrl NOTIFY testStreamUrlChanged)
public:
    explicit SettingsStore(QObject *parent = nullptr);

    // 读取 Emby 服务器地址(键 network/serverUrl)。
    QString serverUrl() const;
    // 写入服务器地址,值未变化时不落盘不发信号。
    void setServerUrl(const QString &v);

    // 读取演示测试流地址(键 playback/testStreamUrl)。
    QString testStreamUrl() const;
    // 写入测试流地址,值未变化时不落盘不发信号。
    void setTestStreamUrl(const QString &v);

signals:
    void serverUrlChanged();
    void testStreamUrlChanged();

private:
    // 默认构造依赖 main.cpp 中已设置的 organizationName/applicationName。
    QSettings m_settings;
};
