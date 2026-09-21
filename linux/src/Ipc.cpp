#include "Ipc.h"

#include "AppController.h"

#include <QDBusArgument>
#include <QDBusInterface>
#include <QDBusConnectionInterface>
#include <QDBusReply>

#include <cmath>

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
qulonglong IpcAdaptor::OpenSettings() {
  const qulonglong requestId = controller_->beginIpcRequest();
  controller_->openSettings();
  return requestId;
}
qulonglong IpcAdaptor::SetFilterEnabled(bool enabled) {
  const qulonglong requestId = controller_->beginIpcRequest();
  controller_->setFilterEnabled(enabled);
  return requestId;
}
qulonglong IpcAdaptor::SetPreset(const QString &preset) {
  if (preset.size() > 32 || !presetFromName(preset).has_value()) {
    sendErrorReply(QDBusError::InvalidArgs, QStringLiteral("preset must be neutral, evening, or pure-red"));
    return 0;
  }
  const qulonglong requestId = controller_->beginIpcRequest();
  controller_->setPreset(preset);
  return requestId;
}
qulonglong IpcAdaptor::SetWarmth(double warmth) {
  if (!std::isfinite(warmth) || warmth < 0.0 || warmth > 1.0) {
    sendErrorReply(QDBusError::InvalidArgs, QStringLiteral("warmth must be finite and between 0 and 1"));
    return 0;
  }
  const qulonglong requestId = controller_->beginIpcRequest();
  controller_->setWarmth(warmth);
  return requestId;
}
qulonglong IpcAdaptor::SetBrightness(double brightness) {
  if (!std::isfinite(brightness) || brightness < 0.10 || brightness > 1.0) {
    sendErrorReply(QDBusError::InvalidArgs, QStringLiteral("brightness must be finite and between 0.10 and 1"));
    return 0;
  }
  const qulonglong requestId = controller_->beginIpcRequest();
  controller_->setBrightness(brightness);
  return requestId;
}
qulonglong IpcAdaptor::SetBacklightLock(bool enabled) {
  const qulonglong requestId = controller_->beginIpcRequest();
  controller_->setBacklightLock(enabled);
  return requestId;
}
qulonglong IpcAdaptor::SetSchedule(bool enabled) {
  const qulonglong requestId = controller_->beginIpcRequest();
  controller_->setSchedule(enabled);
  return requestId;
}
qulonglong IpcAdaptor::SetLocation(double latitude, double longitude) {
  if (!std::isfinite(latitude) || !std::isfinite(longitude)
      || latitude < -90.0 || latitude > 90.0 || longitude < -180.0 || longitude > 180.0) {
    sendErrorReply(QDBusError::InvalidArgs, QStringLiteral("location is outside the documented range"));
    return 0;
  }
  const qulonglong requestId = controller_->beginIpcRequest();
  controller_->setLocation(latitude, longitude);
  return requestId;
}
qulonglong IpcAdaptor::ClearLocation() {
  const qulonglong requestId = controller_->beginIpcRequest();
  controller_->clearLocation();
  return requestId;
}
qulonglong IpcAdaptor::ResumeAutomation() {
  const qulonglong requestId = controller_->beginIpcRequest();
  controller_->resumeAutomation();
  return requestId;
}
qulonglong IpcAdaptor::AcceptCurrentHardwareState() {
  const qulonglong requestId = controller_->beginIpcRequest();
  controller_->acceptCurrentHardwareState();
  return requestId;
}
qulonglong IpcAdaptor::DiscardUnreadableRecoveryEvidence() {
  const qulonglong requestId = controller_->beginIpcRequest();
  controller_->discardUnreadableRecoveryEvidence();
  return requestId;
}
qulonglong IpcAdaptor::ReplaceUnreadableSettings() {
  const qulonglong requestId = controller_->beginIpcRequest();
  controller_->replaceUnreadableSettings();
  return requestId;
}
qulonglong IpcAdaptor::Retry() {
  const qulonglong requestId = controller_->beginIpcRequest();
  controller_->retry();
  return requestId;
}
qulonglong IpcAdaptor::Restore() {
  const qulonglong requestId = controller_->beginIpcRequest();
  controller_->restore();
  return requestId;
}
qulonglong IpcAdaptor::Quit() {
  const qulonglong requestId = controller_->beginIpcRequest();
  controller_->quit();
  return requestId;
}

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
  interface.setTimeout(2000);
  QDBusMessage message = interface.callWithArgumentList(QDBus::AutoDetect, method, arguments);
  if (message.type() == QDBusMessage::ErrorMessage) {
    if (error != nullptr) *error = message.errorMessage();
    return false;
  }
  if (reply != nullptr) {
    if (message.arguments().isEmpty()) {
      if (error != nullptr) *error = QStringLiteral("resident returned an empty D-Bus reply");
      return false;
    }
    const QVariant value = message.arguments().constFirst();
    if (method == QStringLiteral("GetStatus")) {
      if (value.metaType() == QMetaType::fromType<QDBusArgument>()) {
        *reply = QVariant::fromValue(qdbus_cast<QVariantMap>(value));
      } else if (value.canConvert<QVariantMap>()) {
        *reply = value.toMap();
      } else {
        if (error != nullptr) *error = QStringLiteral("resident returned an invalid status payload");
        return false;
      }
    } else {
      *reply = value;
    }
  }
  return true;
}

} // namespace ember
