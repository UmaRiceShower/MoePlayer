#include "settingsstore.h"

namespace {
// 默认 Emby 服务器地址(本地回环),用户可在设置页覆盖。
const QString kDefaultServerUrl = QStringLiteral("http://127.0.0.1:8096");
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
