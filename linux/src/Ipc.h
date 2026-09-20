#pragma once

#include <QDBusConnection>
#include <QDBusAbstractAdaptor>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

namespace ember {

class AppController;

class IpcAdaptor final : public QDBusAbstractAdaptor {
  Q_OBJECT
  Q_CLASSINFO("D-Bus Interface", "app.projectember.Ember")

public:
  explicit IpcAdaptor(AppController *controller);

public slots:
  QVariantMap GetStatus() const;
  void OpenSettings();
  void SetFilterEnabled(bool enabled);
  void SetPreset(const QString &preset);
  void SetWarmth(double warmth);
  void SetBrightness(double brightness);
  void SetBacklightLock(bool enabled);
  void SetSchedule(bool enabled);
  void SetLocation(double latitude, double longitude);
  void ClearLocation();
  void Retry();
  void Restore();
  void Quit();

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
