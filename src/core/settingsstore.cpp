#include "settingsstore.h"

#include "core/constants.h"

SettingsStore::SettingsStore(QObject *parent)
    : QObject(parent)
{
}

QString SettingsStore::serverUrl() const
{
    return m_settings.value(MoePlayer::kSettingsServerUrlKey, MoePlayer::kDefaultServerUrl).toString();
}

void SettingsStore::setServerUrl(const QString &v)
{
    if (v == serverUrl())
        return;
    m_settings.setValue(MoePlayer::kSettingsServerUrlKey, v);
    emit serverUrlChanged();
}
