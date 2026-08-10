#include "settingsstore.h"

namespace {
// 默认 Emby 服务器地址(本机回环),用户可在设置页覆盖。
const QString kDefaultServerUrl = QStringLiteral("http://127.0.0.1:8096");
// 默认演示流:W3C 官方测试媒体(Sintel,Blender 开源短片,CC-BY),仅作无服务器时的演示,可覆盖。
const QString kDefaultTestStreamUrl = QStringLiteral("https://media.w3.org/2010/05/sintel/trailer.mp4");
} // namespace

SettingsStore::SettingsStore(QObject *parent)
    : QObject(parent)
{
}

QString SettingsStore::serverUrl() const
{
    return m_settings.value(QStringLiteral("network/serverUrl"), kDefaultServerUrl).toString();
}

void SettingsStore::setServerUrl(const QString &v)
{
    if (v == serverUrl())
        return;
    m_settings.setValue(QStringLiteral("network/serverUrl"), v);
    emit serverUrlChanged();
}

QString SettingsStore::testStreamUrl() const
{
    return m_settings.value(QStringLiteral("playback/testStreamUrl"), kDefaultTestStreamUrl).toString();
}

void SettingsStore::setTestStreamUrl(const QString &v)
{
    if (v == testStreamUrl())
        return;
    m_settings.setValue(QStringLiteral("playback/testStreamUrl"), v);
    emit testStreamUrlChanged();
}
