#pragma once

#include <QDBusConnection>
#include <QDBusAbstractAdaptor>
#include <QDBusContext>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

namespace ember {

class AppController;

class IpcAdaptor final : public QDBusAbstractAdaptor, protected QDBusContext {
  Q_OBJECT
  Q_CLASSINFO("D-Bus Interface", "app.projectember.Ember")

public:
  explicit IpcAdaptor(AppController *controller);

public slots:
  QVariantMap GetStatus() const;
  qulonglong OpenSettings();
  qulonglong SetFilterEnabled(bool enabled);
  qulonglong SetPreset(const QString &preset);
  qulonglong SetWarmth(double warmth);
  qulonglong SetBrightness(double brightness);
  qulonglong SetBacklightLock(bool enabled);
  qulonglong SetSchedule(bool enabled);
  qulonglong SetLocation(double latitude, double longitude);
  qulonglong ClearLocation();
  qulonglong ResumeAutomation();
  qulonglong AcceptCurrentHardwareState();
  qulonglong DiscardUnreadableRecoveryEvidence();
  qulonglong ReplaceUnreadableSettings();
  qulonglong Retry();
  qulonglong Restore();
  qulonglong Quit();

signals:
  void StatusChanged(const QVariantMap &status);

private:
  AppController *controller_;
};

bool registerIpc(AppController *controller, IpcAdaptor **adaptor, QString *error = nullptr);
void unregisterIpc();

bool ipcServiceAvailable();
bool ipcCall(const QString &method, const QVariantList &arguments, QVariant *reply, QString *error = nullptr);

} // namespace ember
