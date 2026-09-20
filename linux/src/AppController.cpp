#include "AppController.h"

#include "Ipc.h"
#include "core/Diagnostics.h"
#include "core/Solar.h"
#include "platform/WaylandBackend.h"
#include "ui/DiagnosticsDialog.h"
#include "ui/SettingsDialog.h"

#include <QAction>
#include <QApplication>
#include <QDateTime>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDir>
#include <QIcon>
#include <QJsonDocument>
#include <QMenu>
#include <QPainter>
#include <QProcess>
#include <QSystemTrayIcon>
#include <QTimeZone>

#include <cmath>

namespace ember {

namespace {

QIcon trayIcon(bool active, bool attention) {
  QPixmap pixmap(32, 32);
  pixmap.fill(Qt::transparent);
  QPainter painter(&pixmap);
  painter.setRenderHint(QPainter::Antialiasing, true);
  const QColor fill = attention ? QColor(220, 120, 45) : (active ? QColor(225, 142, 70) : QColor(135, 135, 135));
  painter.setBrush(fill);
  painter.setPen(Qt::NoPen);
  painter.drawEllipse(QRectF(5.0, 5.0, 22.0, 22.0));
  painter.setBrush(QColor(35, 35, 35, 220));
  painter.drawEllipse(QRectF(11.0, 11.0, 10.0, 10.0));
  painter.end();
  return QIcon(pixmap);
}

} // namespace

AppController::AppController(bool guiEnabled, QObject *parent)
    : QObject(parent), guiEnabled_(guiEnabled), settingsStore_(paths_), journal_(paths_), backlight_(paths_) {
  persistTimer_.setSingleShot(true);
  persistTimer_.setInterval(150);
  connect(&persistTimer_, &QTimer::timeout, this, &AppController::flushSettings);
  applyTimer_.setSingleShot(true);
  applyTimer_.setInterval(40);
  connect(&applyTimer_, &QTimer::timeout, this, &AppController::invokeApply);
  scheduleTimer_.setSingleShot(true);
  connect(&scheduleTimer_, &QTimer::timeout, this, &AppController::onScheduleTimer);
  driftTimer_.setInterval(5000);
  connect(&driftTimer_, &QTimer::timeout, this, [this] {
    if (!backlightEngaged_) return;
    const BacklightCapability capability = backlight_.probe();
    if (!capability.available || capability.deviceId != backlightCapability_.deviceId) {
      backlightEngaged_ = false;
      recoveryPending_ = true;
      driftCorrections_.clear();
      driftTimer_.stop();
      setAttention(QStringLiteral("Backlight Lock became unavailable; hardware recovery is pending"), true);
      publish();
      return;
    }
    int value = -1;
    QString error;
    if (!backlight_.read(capability, &value, &error)) return;
    if (value < static_cast<int>(std::floor(static_cast<double>(capability.maximum) * 0.97))) {
      const qint64 now = QDateTime::currentMSecsSinceEpoch();
      while (!driftCorrections_.isEmpty() && driftCorrections_.front() < now - 60000) {
        driftCorrections_.removeFirst();
      }
      if (driftCorrections_.size() >= 3) {
        setAttention(QStringLiteral("Backlight Lock paused after repeated external brightness changes"), true);
        backlightEngaged_ = false;
        recoveryPending_ = true;
        driftTimer_.stop();
        publish();
        return;
      }
      if (!backlight_.write(capability, capability.maximum, &error)) {
        setAttention(QStringLiteral("Backlight Lock stopped after a failed correction: %1").arg(error), true);
        backlightEngaged_ = false;
        recoveryPending_ = true;
        driftTimer_.stop();
        publish();
      } else {
        driftCorrections_.append(now);
      }
    }
  });
}

AppController::~AppController() {
  scheduleTimer_.stop();
  applyTimer_.stop();
  driftTimer_.stop();
  persistNow();
  if (wayland_ != nullptr && waylandThread_.isRunning()) {
    QMetaObject::invokeMethod(wayland_, [backend = wayland_] { backend->stop(); }, Qt::BlockingQueuedConnection);
    waylandThread_.quit();
    (void)waylandThread_.wait(1500);
    wayland_ = nullptr;
  }
}

bool AppController::start(QString *error) {
  if (started_) return true;

  const SettingsLoadResult settingsResult = settingsStore_.load();
  if (settingsResult.kind == LoadKind::Loaded) {
    settings_ = settingsResult.settings;
  } else if (settingsResult.kind == LoadKind::Corrupt || settingsResult.kind == LoadKind::FutureSchema || settingsResult.kind == LoadKind::IoFailure) {
    recoveryWarning_ = QStringLiteral("Saved settings were not used: %1").arg(settingsResult.detail);
    settingsPersistenceBlocked_ = true;
    settings_ = Settings::defaults();
  }

  const RecoveryLoadResult recovery = journal_.load();
  if (recovery.kind == LoadKind::Loaded) {
    RecoveryRecord record = recovery.record;
    if (record.hardware.has_value()) {
      QString restoreError;
      if (backlight_.restore(&record, &restoreError)) {
        QString clearError;
        if (!journal_.clear(&clearError)) {
          recoveryPending_ = true;
          recoveryWarning_ = QStringLiteral("Hardware restored, but the recovery journal could not be cleared: %1").arg(clearError);
        }
      } else {
        recoveryPending_ = true;
        record.hardware->unresolved = true;
        record.hardware->error = restoreError;
        QString saveError;
        (void)journal_.save(record, &saveError);
        recoveryWarning_ = QStringLiteral("Hardware recovery remains pending: %1").arg(restoreError);
      }
    } else {
      (void)journal_.clear();
    }
    // A restart after an unclean exit never automatically re-engages a saved
    // filter or maximum hardware brightness. Explicit user action is required.
    if (settings_.filterEnabled) {
      settings_.filterEnabled = false;
      settings_.automationPaused = true;
    }
  } else if (recovery.kind == LoadKind::Corrupt || recovery.kind == LoadKind::FutureSchema || recovery.kind == LoadKind::IoFailure) {
    recoveryWarning_ = QStringLiteral("Recovery journal was not treated as empty: %1").arg(recovery.detail);
    if (recovery.kind == LoadKind::Corrupt) {
      QString quarantinePath;
      (void)journal_.quarantine(&quarantinePath);
    }
    settings_.filterEnabled = false;
    settings_.automationPaused = true;
    recoveryPending_ = true;
  }
  persistNow();

  loginRegistered_ = loginIsRegistered();
  if (!registerIpc(this, &ipcAdaptor_, error)) return false;

  if (guiEnabled_) {
    createTray();
    createDialogs();
  }

  QDBusConnection systemBus = QDBusConnection::systemBus();
  if (systemBus.isConnected()) {
    (void)systemBus.connect(QStringLiteral("org.freedesktop.login1"), QStringLiteral("/org/freedesktop/login1"),
                            QStringLiteral("org.freedesktop.login1.Manager"), QStringLiteral("PrepareForSleep"),
                            this, SLOT(onPrepareForSleep(bool)));
  }

  wayland_ = new WaylandBackend;
  wayland_->moveToThread(&waylandThread_);
  connect(&waylandThread_, &QThread::finished, wayland_, &QObject::deleteLater);
  connect(wayland_, &WaylandBackend::capabilityChanged, this, &AppController::onCapabilityChanged, Qt::QueuedConnection);
  connect(wayland_, &WaylandBackend::applied, this, &AppController::onApplied, Qt::QueuedConnection);
  connect(wayland_, &WaylandBackend::blocked, this, &AppController::onBlocked, Qt::QueuedConnection);
  connect(wayland_, &WaylandBackend::failed, this, &AppController::onBackendFailed, Qt::QueuedConnection);
  connect(wayland_, &WaylandBackend::topologyChanged, this, &AppController::onTopologyChanged, Qt::QueuedConnection);
  connect(wayland_, &WaylandBackend::released, this, &AppController::onReleased, Qt::QueuedConnection);
  waylandThread_.start();
  invokeProbe();
  started_ = true;
  if (settings_.sunScheduleEnabled && !settings_.automationPaused) scheduleFromLocation();
  publish();
  return true;
}

void AppController::openSettings() {
  if (!guiEnabled_) return;
  if (settingsDialog_ == nullptr) createDialogs();
  settingsDialog_->refreshFromController();
  settingsDialog_->show();
  settingsDialog_->raise();
  settingsDialog_->activateWindow();
}

void AppController::openDiagnostics() {
  if (!guiEnabled_) return;
  if (diagnosticsDialog_ == nullptr) createDialogs();
  diagnosticsDialog_->refreshFromController();
  diagnosticsDialog_->show();
  diagnosticsDialog_->raise();
  diagnosticsDialog_->activateWindow();
}

void AppController::setFilterEnabled(bool enabled) {
  if (settings_.sunScheduleEnabled && !settings_.automationPaused && settings_.location.has_value()) {
    const SolarSchedule schedule = solarSchedule(QDateTime::currentDateTime(), *settings_.location, QTimeZone::systemTimeZone());
    if (schedule.nextEvent.has_value()) {
      settings_.overrideFilterEnabled = enabled;
      settings_.overrideExpiresAtMs = schedule.nextEvent->time.toMSecsSinceEpoch();
    }
  }
  setFilterEnabledInternal(enabled, false);
}

void AppController::setFilterEnabledInternal(bool enabled, bool scheduleAction) {
  if (enabled && !scheduleAction && settings_.automationPaused) {
    settings_.automationPaused = false;
    (void)unlink(paths_.safetyLatchFile.toUtf8().constData());
  }
  if (settings_.filterEnabled == enabled &&
      ((enabled && (runtimeState_ == RuntimeState::CompositorControlled || runtimeState_ == RuntimeState::Enabling)) ||
       (!enabled && runtimeState_ == RuntimeState::Off))) {
    persistSoon();
    publish();
    return;
  }
  settings_.filterEnabled = enabled;
  ++generation_;
  pixelsVerified_ = false;
  if (enabled) {
    runtimeState_ = RuntimeState::Enabling;
    lastError_.clear();
    invokeApply();
  } else {
    runtimeState_ = RuntimeState::Restoring;
    applyTimer_.stop();
    scheduleTimer_.stop();
    (void)restoreHardwareAndJournal();
    invokeRelease();
  }
  persistSoon();
  publish();
}

void AppController::setPreset(const QString &preset) {
  const auto parsed = presetFromName(preset);
  if (!parsed.has_value()) {
    setAttention(QStringLiteral("Unknown preset: %1").arg(preset), true);
    publish();
    return;
  }
  settings_.warmth = presetWarmth(*parsed);
  if (settings_.filterEnabled) scheduleApply();
  persistSoon();
  publish();
}

void AppController::setWarmth(double warmth) {
  if (!std::isfinite(warmth) || warmth < 0.0 || warmth > 1.0) {
    setAttention(QStringLiteral("Warmth must be a finite value from 0 to 100"), true);
    publish();
    return;
  }
  settings_.warmth = warmth;
  if (settings_.filterEnabled) scheduleApply();
  persistSoon();
  publish();
}

void AppController::setBrightness(double brightness) {
  if (!std::isfinite(brightness) || brightness < 0.10 || brightness > 1.0) {
    setAttention(QStringLiteral("Software brightness must be a finite value from 10 to 100"), true);
    publish();
    return;
  }
  settings_.brightness = brightness;
  if (settings_.filterEnabled) scheduleApply();
  persistSoon();
  publish();
}

void AppController::setBacklightLock(bool enabled) {
  settings_.backlightLockEnabled = enabled;
  if (!enabled && backlightEngaged_) {
    const bool restored = restoreHardwareAndJournal();
    backlightEngaged_ = false;
    driftCorrections_.clear();
    driftTimer_.stop();
    backlightCapability_ = {};
    if (!restored) publish();
  }
  if (enabled && settings_.filterEnabled && processedGeneration_ == generation_) {
    if (!captureAndEngageBacklight()) publish();
  }
  persistSoon();
  publish();
}

void AppController::setSchedule(bool enabled) {
  settings_.sunScheduleEnabled = enabled;
  if (!enabled) {
    scheduleTimer_.stop();
    settings_.overrideExpiresAtMs.reset();
    persistSoon();
    publish();
    return;
  }
  const bool loginOk = setLoginRegistration(true);
  if (!loginOk) setAttention(QStringLiteral("Sun schedule is session-only because launch-at-login could not be registered"));
  scheduleFromLocation();
  persistSoon();
  publish();
}

void AppController::setLaunchAtLogin(bool enabled) {
  if (!setLoginRegistration(enabled)) {
    settings_.launchAtLogin = false;
    setAttention(QStringLiteral("Launch at login could not be registered for this graphical session"), true);
  } else {
    clearAttention();
  }
  persistSoon();
  publish();
}

void AppController::setPrimaryAction(const QString &action) {
  const auto parsed = primaryActionFromName(action);
  if (!parsed.has_value()) return;
  settings_.primaryAction = *parsed;
  persistSoon();
  publish();
}

void AppController::setLocation(double latitude, double longitude) {
  if (!std::isfinite(latitude) || !std::isfinite(longitude) || latitude < -90.0 || latitude > 90.0 || longitude < -180.0 || longitude > 180.0) {
    setAttention(QStringLiteral("Location must use finite latitude -90..90 and longitude -180..180"), true);
    publish();
    return;
  }
  settings_.location = Coordinate{std::round(latitude * 10.0) / 10.0, std::round(longitude * 10.0) / 10.0};
  settings_.overrideExpiresAtMs.reset();
  settings_.automationPaused = false;
  recoveryWarning_.clear();
  if (settings_.sunScheduleEnabled) scheduleFromLocation();
  persistSoon();
  publish();
}

void AppController::clearLocation() {
  settings_.location.reset();
  settings_.overrideExpiresAtMs.reset();
  scheduleTimer_.stop();
  persistSoon();
  publish();
}

void AppController::retry() {
  lastError_.clear();
  if (settings_.filterEnabled) {
    ++generation_;
    runtimeState_ = RuntimeState::Enabling;
    applyTimer_.stop();
    invokeProbe();
    invokeApply();
  } else {
    invokeProbe();
  }
  publish();
}

void AppController::restore() {
  settings_.filterEnabled = false;
  settings_.backlightLockEnabled = false;
  settings_.overrideExpiresAtMs.reset();
  settings_.automationPaused = true;
  (void)writeDurableFile(paths_.safetyLatchFile, QByteArray("paused\n"), 0600);
  ++generation_;
  applyTimer_.stop();
  runtimeState_ = RuntimeState::Restoring;
  scheduleTimer_.stop();
  (void)restoreHardwareAndJournal();
  invokeRelease();
  persistSoon();
  publish();
}

void AppController::quit() {
  if (quitting_) return;
  quitting_ = true;
  settings_.filterEnabled = false;
  ++generation_;
  applyTimer_.stop();
  runtimeState_ = RuntimeState::Restoring;
  scheduleTimer_.stop();
  (void)restoreHardwareAndJournal();
  invokeRelease();
  persistNow();
  QTimer::singleShot(250, this, &AppController::finalizeQuit);
  publish();
}

void AppController::onCapabilityChanged(bool waylandAvailable, int managerVersion, int outputCount, QString reason) {
  waylandAvailable_ = waylandAvailable;
  managerVersion_ = managerVersion;
  outputCount_ = outputCount;
  capabilityReason_ = reason;
  if (!waylandAvailable_ || managerVersion_ < 2) {
    if (settings_.filterEnabled) {
      runtimeState_ = RuntimeState::Unsupported;
      setAttention(reason.isEmpty() ? QStringLiteral("Hyprland CTM v2 is unavailable") : reason, true);
    }
  } else if (!settings_.filterEnabled && runtimeState_ == RuntimeState::Unsupported) {
    runtimeState_ = RuntimeState::Off;
    clearAttention();
  }
  publish();
}

void AppController::onApplied(qulonglong generation) {
  if (generation != generation_ || !settings_.filterEnabled || quitting_) return;
  processedGeneration_ = generation;
  pixelsVerified_ = false;
  runtimeState_ = RuntimeState::CompositorControlled;
  lastError_.clear();
  clearAttention();
  if (settings_.backlightLockEnabled) (void)captureAndEngageBacklight();
  if (backlightEngaged_) driftTimer_.start();
  publish();
}

void AppController::onBlocked(QString reason) {
  runtimeState_ = RuntimeState::Blocked;
  lastError_ = reason;
  setAttention(QStringLiteral("Blocked by another color controller. Release it, then choose Retry."), true);
  backlightEngaged_ = false;
  driftCorrections_.clear();
  driftTimer_.stop();
  publish();
}

void AppController::onBackendFailed(QString reason) {
  if (quitting_) return;
  lastError_ = reason;
  runtimeState_ = managerVersion_ < 2 ? RuntimeState::Unsupported : RuntimeState::Degraded;
  setAttention(reason, true);
  if (backlightEngaged_) {
    (void)restoreHardwareAndJournal();
    backlightEngaged_ = false;
    driftCorrections_.clear();
    driftTimer_.stop();
  }
  publish();
}

void AppController::onTopologyChanged() {
  if (!settings_.filterEnabled || quitting_) return;
  ++generation_;
  runtimeState_ = RuntimeState::Reconciling;
  invokeApply();
  publish();
}

void AppController::onReleased() {
  if (sleepRestoreInFlight_) {
    sleepRestoreInFlight_ = false;
    runtimeState_ = RuntimeState::Suspended;
  } else {
    runtimeState_ = recoveryPending_ ? RuntimeState::Degraded : RuntimeState::Off;
  }
  backlightEngaged_ = false;
  driftCorrections_.clear();
  driftTimer_.stop();
  publish();
}

void AppController::onScheduleTimer() { reconcileSchedule(); }

void AppController::onPrepareForSleep(bool sleeping) {
  if (sleeping) {
    sleepWasDesired_ = settings_.filterEnabled;
    if (settings_.filterEnabled) {
      runtimeState_ = RuntimeState::Restoring;
      sleepRestoreInFlight_ = true;
      (void)restoreHardwareAndJournal();
      invokeRelease();
      publish();
    }
    return;
  }
  if (sleepWasDesired_ && settings_.filterEnabled && !settings_.automationPaused) {
    ++generation_;
    applyTimer_.stop();
    runtimeState_ = RuntimeState::Enabling;
    invokeProbe();
    invokeApply();
  } else {
    runtimeState_ = RuntimeState::Off;
    publish();
  }
  sleepWasDesired_ = false;
}

void AppController::flushSettings() { persistNow(); }

void AppController::updateTray() {
  if (tray_ == nullptr) return;
  const QVariantMap current = status();
  const bool active = current.value(QStringLiteral("filterEnabled")).toBool()
      && current.value(QStringLiteral("protocolOwnership")).toString() == QStringLiteral("compositor_controlled");
  const bool attention = current.value(QStringLiteral("attentionSeverity")).toString() == QStringLiteral("error");
  tray_->setIcon(trayIcon(active, attention));
  tray_->setToolTip(QStringLiteral("Project Ember — %1").arg(current.value(QStringLiteral("statusTitle")).toString()));
  if (toggleAction_ != nullptr) toggleAction_->setText(active ? QStringLiteral("Turn Ember Off") : QStringLiteral("Turn Ember On"));
}

void AppController::createTray() {
  if (!QSystemTrayIcon::isSystemTrayAvailable()) return;
  tray_ = new QSystemTrayIcon(this);
  trayMenu_ = new QMenu;
  settingsAction_ = trayMenu_->addAction(QStringLiteral("Settings…"));
  toggleAction_ = trayMenu_->addAction(QStringLiteral("Turn Ember On"));
  restoreAction_ = trayMenu_->addAction(QStringLiteral("Restore"));
  trayMenu_->addSeparator();
  quitAction_ = trayMenu_->addAction(QStringLiteral("Quit"));
  tray_->setContextMenu(trayMenu_);
  tray_->setIcon(trayIcon(false, false));
  connect(settingsAction_, &QAction::triggered, this, &AppController::openSettings);
  connect(toggleAction_, &QAction::triggered, this, [this] { setFilterEnabled(!settings_.filterEnabled); });
  connect(restoreAction_, &QAction::triggered, this, &AppController::restore);
  connect(quitAction_, &QAction::triggered, this, &AppController::quit);
  connect(tray_, &QSystemTrayIcon::activated, this, [this](QSystemTrayIcon::ActivationReason reason) {
    if (reason == QSystemTrayIcon::Context) return;
    if (reason != QSystemTrayIcon::Trigger && reason != QSystemTrayIcon::DoubleClick) return;
    if (settings_.primaryAction == PrimaryAction::OpenControls) openSettings();
    else setFilterEnabled(!settings_.filterEnabled);
  });
  tray_->show();
}

void AppController::createDialogs() {
  if (settingsDialog_ == nullptr) settingsDialog_ = new SettingsDialog(this);
  if (diagnosticsDialog_ == nullptr) diagnosticsDialog_ = new DiagnosticsDialog(this);
}

void AppController::invokeProbe() {
  if (wayland_ == nullptr) return;
  QMetaObject::invokeMethod(wayland_, [backend = wayland_] { backend->probe(); }, Qt::QueuedConnection);
}

void AppController::invokeApply() {
  if (wayland_ == nullptr) return;
  const ColorMatrix matrix = matrixFor(settings_);
  const qulonglong generation = generation_;
  QMetaObject::invokeMethod(wayland_, [backend = wayland_, matrix, generation] { backend->apply(matrix, generation); }, Qt::QueuedConnection);
}

void AppController::invokeRelease() {
  if (wayland_ == nullptr) {
    onReleased();
    return;
  }
  QMetaObject::invokeMethod(wayland_, [backend = wayland_] { backend->release(); }, Qt::QueuedConnection);
}

void AppController::invokeStop() {
  if (wayland_ == nullptr) return;
  QMetaObject::invokeMethod(wayland_, [backend = wayland_] { backend->stop(); }, Qt::BlockingQueuedConnection);
}

void AppController::scheduleFromLocation() {
  if (!settings_.sunScheduleEnabled || settings_.automationPaused) return;
  if (!settings_.location.has_value()) {
    scheduleTimer_.stop();
    setAttention(QStringLiteral("Sun schedule is waiting for an approximate latitude and longitude"));
    publish();
    return;
  }
  reconcileSchedule();
}

void AppController::reconcileSchedule() {
  if (!settings_.sunScheduleEnabled || settings_.automationPaused || !settings_.location.has_value()) {
    scheduleTimer_.stop();
    publish();
    return;
  }
  const QDateTime now = QDateTime::currentDateTime();
  if (settings_.overrideExpiresAtMs.has_value() && now.toMSecsSinceEpoch() >= *settings_.overrideExpiresAtMs) {
    settings_.overrideExpiresAtMs.reset();
  }
  const SolarSchedule schedule = solarSchedule(now, *settings_.location, QTimeZone::systemTimeZone());
  const bool target = settings_.overrideExpiresAtMs.has_value() ? settings_.overrideFilterEnabled : schedule.isNight;
  if (settings_.filterEnabled != target) setFilterEnabledInternal(target, true);
  scheduleNextSolarBoundary();
  publish();
}

void AppController::scheduleNextSolarBoundary() {
  if (!settings_.location.has_value() || !settings_.sunScheduleEnabled || settings_.automationPaused) {
    scheduleTimer_.stop();
    return;
  }
  const SolarSchedule schedule = solarSchedule(QDateTime::currentDateTime(), *settings_.location, QTimeZone::systemTimeZone());
  if (!schedule.nextEvent.has_value()) {
    scheduleTimer_.start(15 * 60 * 1000);
    return;
  }
  const qint64 delay = std::max<qint64>(1000, QDateTime::currentDateTime().msecsTo(schedule.nextEvent->time) + 250);
  scheduleTimer_.start(static_cast<int>(std::min<qint64>(delay, 24LL * 60LL * 60LL * 1000LL)));
}

void AppController::setAttention(const QString &message, bool error) {
  attentionMessage_ = message;
  attentionError_ = error;
}

void AppController::scheduleApply() {
  if (!settings_.filterEnabled || quitting_) return;
  ++generation_;
  pixelsVerified_ = false;
  runtimeState_ = RuntimeState::Reconciling;
  applyTimer_.start();
}

void AppController::clearAttention() {
  if (recoveryWarning_.isEmpty()) {
    attentionMessage_.clear();
    attentionError_ = false;
  }
}

void AppController::persistSoon() {
  settingsPersistenceBlocked_ = false;
  persistTimer_.start();
}

void AppController::persistNow() {
  if (settingsPersistenceBlocked_) return;
  QString error;
  if (!settingsStore_.save(settings_, &error)) {
    lastError_ = QStringLiteral("Settings could not be saved: %1").arg(error);
  }
}

bool AppController::restoreHardwareAndJournal() {
  const RecoveryLoadResult result = journal_.load();
  if (result.kind == LoadKind::NoFile) {
    recoveryPending_ = false;
    return true;
  }
  if (result.kind != LoadKind::Loaded) {
    recoveryPending_ = true;
    return false;
  }
  RecoveryRecord record = result.record;
  if (!record.hardware.has_value()) {
    recoveryPending_ = false;
    (void)journal_.clear();
    return true;
  }
  QString error;
  if (!backlight_.restore(&record, &error)) {
    recoveryPending_ = true;
    record.hardware->unresolved = true;
    record.hardware->error = error;
    QString saveError;
    (void)journal_.save(record, &saveError);
    recoveryWarning_ = QStringLiteral("Hardware restore needs attention: %1").arg(error);
    return false;
  }
  recoveryPending_ = false;
  QString clearError;
  if (!journal_.clear(&clearError)) {
    recoveryPending_ = true;
    recoveryWarning_ = QStringLiteral("Hardware restored but journal cleanup failed: %1").arg(clearError);
    return false;
  }
  return true;
}

bool AppController::captureAndEngageBacklight() {
  if (backlightEngaged_) return true;
  backlightCapability_ = backlight_.probe();
  if (!backlightCapability_.available) {
    setAttention(QStringLiteral("Backlight Lock unavailable: %1").arg(backlightCapability_.reason));
    return false;
  }
  if (!backlight_.guardianArmed()) {
    setAttention(QStringLiteral("Backlight Lock is unavailable until the supervised recovery guardian is armed"));
    return false;
  }
  int original = -1;
  QString error;
  if (!backlight_.read(backlightCapability_, &original, &error)) {
    setAttention(QStringLiteral("Backlight Lock could not capture the current brightness: %1").arg(error), true);
    return false;
  }
  RecoveryRecord record;
  record.createdAtMs = QDateTime::currentMSecsSinceEpoch();
  record.safetyPaused = false;
  record.hardware = HardwareRecord{
      backlightCapability_.deviceId,
      backlightCapability_.devicePath,
      hashBootId(),
      original,
      backlightCapability_.maximum,
      backlightCapability_.maximum,
      true,
      QString(),
  };
  // The immutable baseline is durable before the maximum-brightness mutation.
  if (!journal_.save(record, &error)) {
    setAttention(QStringLiteral("Backlight Lock refused to change hardware because its recovery journal could not be saved: %1").arg(error), true);
    return false;
  }
  if (!backlight_.write(backlightCapability_, backlightCapability_.maximum, &error)) {
    recoveryPending_ = true;
    record.hardware->unresolved = true;
    record.hardware->error = error;
    (void)journal_.save(record);
    setAttention(QStringLiteral("Backlight Lock failed after journaling the baseline: %1").arg(error), true);
    return false;
  }
  record.hardware->unresolved = false;
  if (!journal_.save(record, &error)) {
    recoveryPending_ = true;
    setAttention(QStringLiteral("Backlight Lock is engaged but its recovery record could not be updated: %1").arg(error), true);
    return false;
  }
  backlightEngaged_ = true;
  driftCorrections_.clear();
  recoveryPending_ = false;
  clearAttention();
  return true;
}

bool AppController::setLoginRegistration(bool enabled) {
  QProcess process;
  QStringList arguments = {QStringLiteral("--user"), enabled ? QStringLiteral("enable") : QStringLiteral("disable"), QStringLiteral("project-ember.service")};
  process.start(QStringLiteral("systemctl"), arguments);
  if (!process.waitForFinished(1500)) return false;
  loginRegistered_ = enabled ? process.exitCode() == 0 : false;
  if (!loginRegistered_ && enabled) settings_.launchAtLogin = false;
  else settings_.launchAtLogin = enabled;
  return enabled ? loginRegistered_ : process.exitCode() == 0;
}

bool AppController::loginIsRegistered() const {
  QProcess process;
  process.start(QStringLiteral("systemctl"), {QStringLiteral("--user"), QStringLiteral("is-enabled"), QStringLiteral("project-ember.service")});
  if (!process.waitForFinished(1000)) return false;
  return process.exitCode() == 0 && QString::fromLocal8Bit(process.readAllStandardOutput()).trimmed() == QStringLiteral("enabled");
}

void AppController::publish() {
  const QVariantMap current = status();
  emit statusChanged(current);
  updateTray();
}

void AppController::finalizeQuit() {
  unregisterIpc();
  if (wayland_ != nullptr && waylandThread_.isRunning()) {
    invokeStop();
    waylandThread_.quit();
    (void)waylandThread_.wait(1500);
    wayland_ = nullptr;
  }
  emit requestQuit();
  QCoreApplication::quit();
}

QVariantMap AppController::status() const {
  QVariantMap result;
  result.insert(QStringLiteral("version"), QStringLiteral("0.1.0-linux-alpha.1"));
  result.insert(QStringLiteral("filterEnabled"), settings_.filterEnabled);
  result.insert(QStringLiteral("desiredFilterEnabled"), settings_.filterEnabled);
  result.insert(QStringLiteral("warmth"), settings_.warmth);
  result.insert(QStringLiteral("brightness"), settings_.brightness);
  result.insert(QStringLiteral("warmthDescription"), describeWarmth(settings_.warmth));
  result.insert(QStringLiteral("runtimeState"), runtimeStateName(runtimeState_));
  result.insert(QStringLiteral("protocolOwnership"), runtimeStateName(runtimeState_));
  result.insert(QStringLiteral("effectiveFilterEnabled"),
               settings_.filterEnabled && runtimeState_ == RuntimeState::CompositorControlled);
  result.insert(QStringLiteral("waylandAvailable"), waylandAvailable_);
  result.insert(QStringLiteral("managerVersion"), managerVersion_);
  result.insert(QStringLiteral("onlineOutputs"), outputCount_);
  result.insert(QStringLiteral("requestProcessed"),
               settings_.filterEnabled && processedGeneration_ != 0 && processedGeneration_ == generation_);
  result.insert(QStringLiteral("requestProcessedGeneration"), processedGeneration_);
  result.insert(QStringLiteral("pixelsVerified"), pixelsVerified_);
  result.insert(QStringLiteral("opticalReadback"), QStringLiteral("unavailable: Hyprland CTM has no pixel/color readback"));
  result.insert(QStringLiteral("backlightLockPreference"), settings_.backlightLockEnabled);
  result.insert(QStringLiteral("backlightEngaged"), backlightEngaged_);
  result.insert(QStringLiteral("backlightAvailable"), backlightCapability_.available);
  result.insert(QStringLiteral("backlightReason"), backlightCapability_.available ? QString() : backlightCapability_.reason);
  result.insert(QStringLiteral("sunScheduleEnabled"), settings_.sunScheduleEnabled);
  result.insert(QStringLiteral("locationConfigured"), settings_.location.has_value());
  result.insert(QStringLiteral("automationPaused"), settings_.automationPaused);
  result.insert(QStringLiteral("launchAtLogin"), settings_.launchAtLogin);
  result.insert(QStringLiteral("loginRegistered"), loginRegistered_);
  result.insert(QStringLiteral("recoveryPending"), recoveryPending_);
  result.insert(QStringLiteral("recoveryWarning"), recoveryWarning_);
  result.insert(QStringLiteral("capabilityReason"), capabilityReason_);
  if (settings_.sunScheduleEnabled && settings_.location.has_value() && !settings_.automationPaused) {
    const SolarSchedule schedule = solarSchedule(QDateTime::currentDateTime(), *settings_.location, QTimeZone::systemTimeZone());
    result.insert(QStringLiteral("solarState"), schedule.isNight ? QStringLiteral("night") : QStringLiteral("day"));
    result.insert(QStringLiteral("solarOverrideActive"), settings_.overrideExpiresAtMs.has_value());
    if (schedule.nextEvent.has_value()) {
      result.insert(QStringLiteral("solarNextEvent"), schedule.nextEvent->time.toString(Qt::ISODate));
      result.insert(QStringLiteral("solarNextEventKind"), schedule.nextEvent->kind == SolarEventKind::Sunrise
          ? QStringLiteral("sunrise") : QStringLiteral("sunset"));
    }
  } else if (settings_.sunScheduleEnabled) {
    result.insert(QStringLiteral("solarState"), QStringLiteral("waiting_for_location"));
    result.insert(QStringLiteral("solarOverrideActive"), false);
  }
  const QString attention = !recoveryWarning_.isEmpty() ? recoveryWarning_ : (!lastError_.isEmpty() ? lastError_ : attentionMessage_);
  result.insert(QStringLiteral("attentionMessage"), attention);
  result.insert(QStringLiteral("attentionSeverity"), attention.isEmpty() ? QStringLiteral("none") : (attentionError_ || !lastError_.isEmpty() ? QStringLiteral("error") : QStringLiteral("info")));
  const QString statusTitle = !settings_.filterEnabled ? QStringLiteral("Ember is off")
      : runtimeState_ == RuntimeState::CompositorControlled ? QStringLiteral("Ember is on")
      : QStringLiteral("Ember needs attention");
  result.insert(QStringLiteral("statusTitle"), statusTitle);
  result.insert(QStringLiteral("statusDetail"), settings_.filterEnabled
      ? (runtimeState_ == RuntimeState::CompositorControlled ? QStringLiteral("Compositor-controlled; displayed pixels are not read back") : runtimeStateName(runtimeState_))
      : QStringLiteral("Your displays look normal; no CTM manager is owned"));
  return result;
}

QString AppController::diagnosticsText() const {
  const QVariantMap sanitized = sanitizedDiagnostics(status());
  return QString::fromUtf8(QJsonDocument::fromVariant(sanitized).toJson(QJsonDocument::Indented));
}

} // namespace ember
