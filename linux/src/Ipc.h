#pragma once

#include <QDBusConnection>
#include <QDBusContext>
#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

namespace ember {

class AppController;

class IpcAdaptor final : public QObject, protected QDBusContext {
  Q_OBJECT
  Q_CLASSINFO("D-Bus Interface", "app.projectember.Ember")

public:
  explicit IpcAdaptor(AppController *controller);

public slots:
  Q_SCRIPTABLE QVariantMap GetStatus() const;
  Q_SCRIPTABLE qulonglong OpenSettings();
  Q_SCRIPTABLE qulonglong SetFilterEnabled(bool enabled);
  Q_SCRIPTABLE qulonglong SetPreset(const QString &preset);
  Q_SCRIPTABLE qulonglong SetWarmth(double warmth);
  Q_SCRIPTABLE qulonglong SetBrightness(double brightness);
  Q_SCRIPTABLE qulonglong SetBacklightLock(bool enabled);
  Q_SCRIPTABLE qulonglong SetSchedule(bool enabled);
  Q_SCRIPTABLE qulonglong SetLocation(double latitude, double longitude);
  Q_SCRIPTABLE qulonglong ClearLocation();
  Q_SCRIPTABLE qulonglong ResumeAutomation();
  Q_SCRIPTABLE qulonglong AcceptCurrentHardwareState();
  Q_SCRIPTABLE qulonglong DiscardUnreadableRecoveryEvidence();
  Q_SCRIPTABLE qulonglong ReplaceUnreadableSettings();
  Q_SCRIPTABLE qulonglong Retry();
  Q_SCRIPTABLE qulonglong Restore();
  Q_SCRIPTABLE qulonglong Quit();

signals:
  Q_SCRIPTABLE void StatusChanged(const QVariantMap &status);

private:
  AppController *controller_;
};

bool registerIpc(AppController *controller, IpcAdaptor **adaptor, QString *error = nullptr);
void unregisterIpc();

bool ipcServiceAvailable();
bool ipcCall(const QString &method, const QVariantList &arguments, QVariant *reply, QString *error = nullptr);

} // namespace ember
