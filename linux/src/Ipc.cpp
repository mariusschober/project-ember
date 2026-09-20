#include "Ipc.h"

#include "AppController.h"

#include <QDBusInterface>
#include <QDBusConnectionInterface>
#include <QDBusReply>

namespace ember {

namespace {
constexpr auto serviceName = "app.projectember.Ember";
constexpr auto objectPath = "/app/projectember/Ember";
constexpr auto interfaceName = "app.projectember.Ember";
}

IpcAdaptor::IpcAdaptor(AppController *controller)
    : QDBusAbstractAdaptor(controller), controller_(controller) {
  connect(controller_, &AppController::statusChanged, this, &IpcAdaptor::StatusChanged);
}

QVariantMap IpcAdaptor::GetStatus() const { return controller_->status(); }
void IpcAdaptor::OpenSettings() { controller_->openSettings(); }
void IpcAdaptor::SetFilterEnabled(bool enabled) { controller_->setFilterEnabled(enabled); }
void IpcAdaptor::SetPreset(const QString &preset) { controller_->setPreset(preset); }
void IpcAdaptor::SetWarmth(double warmth) { controller_->setWarmth(warmth); }
void IpcAdaptor::SetBrightness(double brightness) { controller_->setBrightness(brightness); }
void IpcAdaptor::SetBacklightLock(bool enabled) { controller_->setBacklightLock(enabled); }
void IpcAdaptor::SetSchedule(bool enabled) { controller_->setSchedule(enabled); }
void IpcAdaptor::SetLocation(double latitude, double longitude) { controller_->setLocation(latitude, longitude); }
void IpcAdaptor::ClearLocation() { controller_->clearLocation(); }
void IpcAdaptor::Retry() { controller_->retry(); }
void IpcAdaptor::Restore() { controller_->restore(); }
void IpcAdaptor::Quit() { controller_->quit(); }

bool registerIpc(AppController *controller, IpcAdaptor **adaptor, QString *error) {
  QDBusConnection bus = QDBusConnection::sessionBus();
  if (!bus.isConnected()) {
    if (error != nullptr) *error = bus.lastError().message();
    return false;
  }
  if (!bus.registerService(QString::fromLatin1(serviceName))) {
    if (error != nullptr) *error = bus.lastError().message();
    return false;
  }
  auto *instance = new IpcAdaptor(controller);
  if (!bus.registerObject(QString::fromLatin1(objectPath), controller, QDBusConnection::ExportAdaptors)) {
    if (error != nullptr) *error = bus.lastError().message();
    delete instance;
    bus.unregisterService(QString::fromLatin1(serviceName));
    return false;
  }
  if (adaptor != nullptr) *adaptor = instance;
  return true;
}

void unregisterIpc() {
  QDBusConnection bus = QDBusConnection::sessionBus();
  if (bus.isConnected()) bus.unregisterService(QString::fromLatin1(serviceName));
}

bool ipcServiceAvailable() {
  QDBusConnection bus = QDBusConnection::sessionBus();
  return bus.isConnected() && bus.interface()->isServiceRegistered(QString::fromLatin1(serviceName));
}

bool ipcCall(const QString &method, const QVariantList &arguments, QVariant *reply, QString *error) {
  const QDBusConnection bus = QDBusConnection::sessionBus();
  if (!bus.isConnected()) {
    if (error != nullptr) *error = bus.lastError().message();
    return false;
  }
  QDBusInterface interface(QString::fromLatin1(serviceName), QString::fromLatin1(objectPath),
                           QString::fromLatin1(interfaceName), bus);
  if (!interface.isValid()) {
    if (error != nullptr) *error = interface.lastError().message();
    return false;
  }
  QDBusMessage message = interface.callWithArgumentList(QDBus::AutoDetect, method, arguments);
  if (message.type() == QDBusMessage::ErrorMessage) {
    if (error != nullptr) *error = message.errorMessage();
    return false;
  }
  if (reply != nullptr && !message.arguments().isEmpty()) *reply = message.arguments().constFirst();
  return true;
}

} // namespace ember
