#include "AppController.h"

#include "Ipc.h"
#include "core/Diagnostics.h"
#include "core/Recovery.h"
#include "core/Solar.h"
#include "platform/WaylandBackend.h"
#include "ui/DiagnosticsDialog.h"
#include "ui/SettingsDialog.h"

#include <QAction>
#include <QApplication>
#include <QDateTime>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusUnixFileDescriptor>
#include <QDir>
#include <QIcon>
#include <QJsonDocument>
#include <QLockFile>
#include <QMenu>
#include <QPainter>
#include <QProcess>
#include <QScopeGuard>
#include <QSystemTrayIcon>
#include <QTimeZone>
#include <QStringList>

#include <cmath>
#include <fcntl.h>
#include <unistd.h>

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

QString systemctlExecutable() {
  const QByteArray override = qgetenv("EMBER_SYSTEMCTL");
  return override.isEmpty() ? QStringLiteral("systemctl") : QString::fromLocal8Bit(override);
}

bool isolatedRootTestAllowed() {
  if (qgetenv("EMBER_TEST_ALLOW_ROOT") != QByteArray("1")) return false;
  const QString backlightRoot = QDir::cleanPath(QString::fromUtf8(qgetenv("EMBER_BACKLIGHT_ROOT")));
  return !backlightRoot.isEmpty()
      && backlightRoot.startsWith(QDir::cleanPath(QDir::tempPath()) + QLatin1Char('/'));
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
  scheduleHealthTimer_.setInterval(5 * 60 * 1000);
  connect(&scheduleHealthTimer_, &QTimer::timeout, this, &AppController::onScheduleHealthTimer);
  backendRetryTimer_.setSingleShot(true);
  connect(&backendRetryTimer_, &QTimer::timeout, this, &AppController::onBackendRetry);
  driftTimer_.setInterval(5000);
  connect(&driftTimer_, &QTimer::timeout, this, [this] {
    if (!backlightEngaged_) return;
    const BacklightCapability capability = backlight_.probe();
    if (!capability.available || capability.deviceId != backlightCapability_.deviceId) {
      backlightEngaged_ = false;
      recoveryPending_ = true;
      driftCorrections_.clear();
      driftTimer_.stop();
      releaseSleepInhibitor();
      setAttention(QStringLiteral("Backlight Lock became unavailable; hardware recovery is pending"), true);
      publish();
      return;
    }
    int value = -1;
    QString error;
    bool drifted = false;
    if (!backlight_.read(capability, &value, &error)) {
      setAttention(QStringLiteral("Backlight Lock stopped after readback failed: %1").arg(error), true);
      (void)restoreHardwareAndJournal();
      backlightEngaged_ = false;
      driftTimer_.stop();
      publish();
      return;
    }
    drifted = value < static_cast<int>(std::floor(static_cast<double>(capability.maximum) * 0.97));
    if (!drifted && capability.actualBrightnessAvailable) {
      int actual = -1;
      if (!backlight_.readActualBrightness(capability, &actual, &error)) {
        setAttention(QStringLiteral("Backlight Lock stopped after actual-brightness readback failed: %1").arg(error), true);
        (void)restoreHardwareAndJournal();
        backlightEngaged_ = false;
        driftTimer_.stop();
        publish();
        return;
      }
      drifted = actual < static_cast<int>(std::floor(static_cast<double>(capability.maximum) * 0.97));
    }
    if (backlightCapability_.automaticBrightnessAvailable) {
      int automatic = -1;
      if (!capability.automaticBrightnessAvailable
          || !backlight_.readAutomaticBrightness(capability, &automatic, &error)) {
        setAttention(QStringLiteral("Backlight Lock stopped because automatic-brightness state became unavailable: %1").arg(error), true);
        (void)restoreHardwareAndJournal();
        backlightEngaged_ = false;
        driftTimer_.stop();
        publish();
        return;
      }
      drifted = drifted || automatic != 0;
    }
    if (drifted) {
      const qint64 now = QDateTime::currentMSecsSinceEpoch();
      while (!driftCorrections_.isEmpty() && driftCorrections_.front() < now - 60000) {
        driftCorrections_.removeFirst();
      }
      if (driftCorrections_.size() >= 3) {
        setAttention(QStringLiteral("Backlight Lock paused after repeated external brightness changes"), true);
        (void)restoreHardwareAndJournal();
        backlightEngaged_ = false;
        driftTimer_.stop();
        publish();
        return;
      }
      const bool automaticCorrected = !backlightCapability_.automaticBrightnessAvailable
          || backlight_.writeAutomaticBrightness(capability, 0, &error);
      if (!automaticCorrected || !backlight_.write(capability, capability.maximum, &error)) {
        setAttention(QStringLiteral("Backlight Lock stopped after a failed correction: %1").arg(error), true);
        (void)restoreHardwareAndJournal();
        backlightEngaged_ = false;
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
  scheduleHealthTimer_.stop();
  backendRetryTimer_.stop();
  applyTimer_.stop();
  driftTimer_.stop();
  releaseSleepInhibitor();
  if (started_) {
    unregisterIpc();
    persistNow();
  }
  if (wayland_ != nullptr && waylandThread_.isRunning()) {
    QMetaObject::invokeMethod(wayland_, [backend = wayland_] { backend->stop(); }, Qt::BlockingQueuedConnection);
    waylandThread_.quit();
    (void)waylandThread_.wait(1500);
    wayland_ = nullptr;
  }
}

bool AppController::start(QString *error) {
  if (started_) return true;
  if (geteuid() == 0 && !isolatedRootTestAllowed()) {
    if (error != nullptr) *error = QStringLiteral("refusing to start a graphical display controller as root");
    return false;
  }
  if (!ensurePrivateDirectory(paths_.runtimeDir, error)) return false;
  controllerLock_ = std::make_unique<QLockFile>(paths_.controllerLockFile);
  controllerLock_->setStaleLockTime(5000);
  if (!controllerLock_->tryLock(0)) {
    if (error != nullptr) *error = QStringLiteral("another Project Ember controller or recovery helper owns this user session");
    controllerLock_.reset();
    return false;
  }
  // Reserve the single-controller name before reading recovery state or
  // touching hardware. A duplicate launch must be side-effect free.
  if (!registerIpc(this, &ipcAdaptor_, error)) {
    controllerLock_.reset();
    return false;
  }

  const SettingsLoadResult settingsResult = settingsStore_.load();
  if (settingsResult.kind == LoadKind::Loaded) {
    settings_ = settingsResult.settings;
  } else if (settingsResult.kind == LoadKind::Corrupt || settingsResult.kind == LoadKind::FutureSchema || settingsResult.kind == LoadKind::IoFailure) {
    settingsWarning_ = QStringLiteral("Saved settings were not used and were preserved: %1").arg(settingsResult.detail);
    settingsPersistenceBlocked_ = true;
    settings_ = Settings::defaults();
  }

  QByteArray safetyLatch;
  QString safetyLatchError;
  if (readRegularPrivateFile(paths_.safetyLatchFile, &safetyLatch, &safetyLatchError)) {
    settings_.automationPaused = true;
    settings_.filterEnabled = false;
  } else if (safetyLatchError != QStringLiteral("not found")) {
    settings_.automationPaused = true;
    settings_.filterEnabled = false;
    recoveryWarning_ = QStringLiteral("Automation safety state could not be verified: %1").arg(safetyLatchError);
  }

  const RecoveryLoadResult recovery = journal_.load();
  if (recovery.kind == LoadKind::Loaded) {
    recoveryUnreadable_ = false;
    RecoveryRecord record = recovery.record;
    if (recoveryRecordHasPendingFields(record)) {
      QString restoreError;
      if (backlight_.restore(&record, &restoreError)) {
        QString clearError;
        if (!journal_.clear(&clearError)) {
          recoveryPending_ = true;
          recoveryWarning_ = QStringLiteral("Hardware restored, but the recovery journal could not be cleared: %1").arg(clearError);
        }
      } else {
        recoveryPending_ = true;
        QString saveError;
        if (!journal_.save(record, &saveError) && !saveError.isEmpty()) {
          restoreError += QStringLiteral("; updated recovery evidence could not be saved: %1").arg(saveError);
        }
        recoveryWarning_ = QStringLiteral("Hardware recovery remains pending: %1").arg(restoreError);
      }
    } else {
      QString clearError;
      if (!journal_.clear(&clearError)) {
        recoveryPending_ = true;
        recoveryWarning_ = QStringLiteral("Completed recovery evidence could not be cleared: %1").arg(clearError);
      }
    }
    // A restart after an unclean exit never automatically re-engages a saved
    // filter or maximum hardware brightness. Explicit user action is required.
    if (settings_.filterEnabled) {
      settings_.filterEnabled = false;
      settings_.automationPaused = true;
    }
  } else if (recovery.kind == LoadKind::Corrupt || recovery.kind == LoadKind::FutureSchema || recovery.kind == LoadKind::IoFailure) {
    recoveryWarning_ = QStringLiteral("Recovery journal was not treated as empty: %1").arg(recovery.detail);
    recoveryUnreadable_ = true;
    if (recovery.kind == LoadKind::Corrupt) {
      QString quarantinePath;
      QString quarantineError;
      if (!journal_.quarantine(&quarantinePath, &quarantineError) && !quarantineError.isEmpty()) {
        recoveryWarning_ += QStringLiteral("; quarantine failed: %1").arg(quarantineError);
      }
    }
    settings_.filterEnabled = false;
    settings_.automationPaused = true;
    recoveryPending_ = true;
  }
  QString cleanMarkerError;
  if (!removeDurableFile(paths_.cleanExitFile, &cleanMarkerError)) {
    settings_.filterEnabled = false;
    settings_.automationPaused = true;
    recoveryWarning_ = QStringLiteral("A prior clean-exit marker could not be consumed safely: %1").arg(cleanMarkerError);
  }
  persistNow();

  // This probe is read-only and does not open Wayland or mutate hardware.
  backlightCapability_ = backlight_.probe();

  loginRegistered_ = loginIsRegistered();
  if (settings_.sunScheduleEnabled && !loginRegistered_) {
    if (!setLoginRegistration(true)) {
      setAttention(QStringLiteral("Sun schedule is active for this session only because launch-at-login could not be registered"));
    }
  } else {
    settings_.launchAtLogin = loginRegistered_;
  }
  if (guiEnabled_) {
    createTray();
    createDialogs();
  }

  QDBusConnection systemBus = QDBusConnection::systemBus();
  if (systemBus.isConnected()) {
    sleepMonitoringAvailable_ = systemBus.connect(
        QStringLiteral("org.freedesktop.login1"), QStringLiteral("/org/freedesktop/login1"),
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
  if (settings_.filterEnabled && runtimeState_ == RuntimeState::Off) {
    ++generation_;
    runtimeState_ = RuntimeState::Enabling;
    invokeApply();
  }
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

qulonglong AppController::beginIpcRequest() {
  ++lastAcceptedRequestId_;
  return lastAcceptedRequestId_;
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
  if (settings_.filterEnabled == enabled &&
      ((enabled && (runtimeState_ == RuntimeState::CompositorControlled
                    || runtimeState_ == RuntimeState::Enabling
                    || (runtimeState_ == RuntimeState::Reconciling && protocolOwned_))) ||
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
    (void)restoreHardwareAndJournal();
    invokeRelease();
  }
  if (!scheduleAction && settings_.sunScheduleEnabled && !settings_.automationPaused) {
    scheduleNextSolarBoundary();
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
  if (!enabled && (backlightEngaged_ || recoveryPending_)) {
    const bool restored = restoreHardwareAndJournal();
    backlightEngaged_ = false;
    driftCorrections_.clear();
    driftTimer_.stop();
    backlightCapability_ = backlight_.probe();
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
    scheduleHealthTimer_.stop();
    settings_.overrideExpiresAtMs.reset();
    persistSoon();
    publish();
    return;
  }
  const bool loginOk = setLoginRegistration(true);
  scheduleFromLocation();
  if (!loginOk) {
    setAttention(QStringLiteral("Sun schedule is active for this session only because launch-at-login could not be registered"));
  } else if (settings_.location.has_value()) {
    setAttention(QStringLiteral("Sun schedule enabled; Project Ember was also registered to launch with the graphical session"));
  }
  persistSoon();
  publish();
}

void AppController::setLaunchAtLogin(bool enabled) {
  if (!setLoginRegistration(enabled)) {
    setAttention(enabled
        ? QStringLiteral("Launch at login could not be registered for this graphical session")
        : QStringLiteral("Launch at login could not be disabled; its previous state was preserved"), true);
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
  const bool replacedOverride = settings_.overrideExpiresAtMs.has_value();
  settings_.overrideExpiresAtMs.reset();
  if (settings_.sunScheduleEnabled) scheduleFromLocation();
  if (replacedOverride) {
    setAttention(QStringLiteral("Location changed; the old-location manual override was cleared and the schedule was reconciled"));
  }
  persistSoon();
  publish();
}

void AppController::clearLocation() {
  settings_.location.reset();
  settings_.overrideExpiresAtMs.reset();
  scheduleTimer_.stop();
  scheduleHealthTimer_.stop();
  persistSoon();
  publish();
}

void AppController::resumeAutomation() {
  settings_.automationPaused = false;
  QString latchError;
  if (!removeDurableFile(paths_.safetyLatchFile, &latchError)) {
    settings_.automationPaused = true;
    setAttention(QStringLiteral("Automation could not be resumed because the safety latch could not be removed durably: %1").arg(latchError), true);
  } else {
    if (!recoveryPending_) recoveryWarning_.clear();
    clearAttention();
    if (settings_.sunScheduleEnabled) scheduleFromLocation();
  }
  persistSoon();
  publish();
}

void AppController::acceptCurrentHardwareState() {
  const RecoveryLoadResult loaded = journal_.load();
  if (loaded.kind == LoadKind::NoFile) {
    recoveryPending_ = false;
    recoveryUnreadable_ = false;
    recoveryWarning_.clear();
    setAttention(QStringLiteral("No hardware recovery record is pending"));
    publish();
    return;
  }
  if (loaded.kind != LoadKind::Loaded) {
    setAttention(QStringLiteral("The recovery record is unreadable and cannot be resolved automatically; preserve it for inspection"), true);
    recoveryPending_ = true;
    recoveryUnreadable_ = true;
    publish();
    return;
  }
  RecoveryRecord record = loaded.record;
  recoveryUnreadable_ = false;
  const BacklightCapability capability = backlight_.probe();
  QStringList unresolved;
  if (record.hardware.has_value()) {
    int current = -1;
    QString readError;
    if (capability.available && capability.deviceId == record.hardware->deviceId
        && backlight_.read(capability, &current, &readError)) {
      record.hardware.reset();
    } else {
      unresolved.append(readError.isEmpty() ? QStringLiteral("brightness identity is unavailable") : readError);
    }
  }
  if (record.automaticBrightness.has_value()) {
    int current = -1;
    QString readError;
    if (capability.available && capability.deviceId == record.automaticBrightness->deviceId
        && capability.automaticBrightnessAvailable
        && capability.automaticBrightnessProvider == record.automaticBrightness->provider
        && backlight_.readAutomaticBrightness(capability, &current, &readError)) {
      record.automaticBrightness.reset();
    } else {
      unresolved.append(readError.isEmpty() ? QStringLiteral("automatic-brightness identity is unavailable") : readError);
    }
  }
  QString journalError;
  if (recoveryRecordHasPendingFields(record)) {
    recoveryPending_ = true;
    if (!journal_.save(record, &journalError)) unresolved.append(journalError);
    setAttention(QStringLiteral("Only identity-verified current hardware state was accepted; recovery remains pending: %1")
                     .arg(unresolved.join(QStringLiteral("; "))), true);
  } else if (!journal_.clear(&journalError)) {
    recoveryPending_ = true;
    setAttention(QStringLiteral("Current hardware state was verified, but recovery evidence could not be cleared: %1").arg(journalError), true);
  } else {
    recoveryPending_ = false;
    recoveryWarning_.clear();
    setAttention(QStringLiteral("Current identity-verified hardware state was accepted; no hardware value was changed"));
  }
  publish();
}

void AppController::discardUnreadableRecoveryEvidence() {
  if (!recoveryUnreadable_) {
    setAttention(QStringLiteral("Recovery evidence is readable; use verified restore or keep-current resolution instead"));
    publish();
    return;
  }
  QString error;
  if (!journal_.discardUnreadable(&error)) {
    recoveryPending_ = true;
    setAttention(QStringLiteral("Unreadable recovery evidence was preserved because explicit discard failed: %1").arg(error), true);
    publish();
    return;
  }
  settings_.filterEnabled = false;
  settings_.backlightLockEnabled = false;
  settings_.automationPaused = true;
  QString latchError;
  if (!writeDurableFile(paths_.safetyLatchFile, QByteArray("paused\n"), 0600, &latchError)) {
    recoveryPending_ = true;
    setAttention(QStringLiteral("Recovery evidence was discarded, but the safety pause could not be persisted: %1").arg(latchError), true);
    publish();
    return;
  }
  recoveryPending_ = false;
  recoveryUnreadable_ = false;
  recoveryWarning_.clear();
  setAttention(QStringLiteral("Unreadable recovery evidence was explicitly discarded; current hardware was not changed and Sun automation remains paused"));
  persistSoon();
  publish();
}

void AppController::replaceUnreadableSettings() {
  if (!settingsPersistenceBlocked_) {
    setAttention(QStringLiteral("Saved settings are already readable"));
    publish();
    return;
  }
  QString error;
  if (!settingsStore_.save(settings_, &error)) {
    setAttention(QStringLiteral("Unreadable settings were preserved because replacement failed: %1").arg(error), true);
    publish();
    return;
  }
  settingsPersistenceBlocked_ = false;
  settingsWarning_.clear();
  setAttention(QStringLiteral("The unreadable settings file was explicitly replaced with the current safe settings"));
  publish();
}

void AppController::retry() {
  lastError_.clear();
  backlightCapability_ = backlight_.probe();
  backendRetryAttempts_ = 0;
  backendRetryTimer_.stop();
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
  QString latchError;
  if (!writeDurableFile(paths_.safetyLatchFile, QByteArray("paused\n"), 0600, &latchError)) {
    recoveryPending_ = true;
    setAttention(QStringLiteral("Emergency restore could not persist its automation safety latch: %1").arg(latchError), true);
  }
  ++generation_;
  applyTimer_.stop();
  runtimeState_ = RuntimeState::Restoring;
  scheduleTimer_.stop();
  scheduleHealthTimer_.stop();
  backendRetryTimer_.stop();
  (void)restoreHardwareAndJournal();
  invokeRelease();
  persistSoon();
  publish();
}

void AppController::quit() {
  if (quitting_) return;
  quitting_ = true;
  ++generation_;
  applyTimer_.stop();
  runtimeState_ = RuntimeState::Restoring;
  scheduleTimer_.stop();
  scheduleHealthTimer_.stop();
  backendRetryTimer_.stop();
  (void)restoreHardwareAndJournal();
  invokeRelease();
  persistNow();
  QString markerError;
  (void)writeDurableFile(paths_.cleanExitFile, QByteArray("clean\n"), 0600, &markerError);
  QTimer::singleShot(250, this, &AppController::finalizeQuit);
  publish();
}

void AppController::onCapabilityChanged(bool waylandAvailable, int managerVersion, int outputCount, QString reason) {
  const bool lostControllingCapability = settings_.filterEnabled && managerVersion_ >= 2
      && (!waylandAvailable || managerVersion < 2);
  waylandAvailable_ = waylandAvailable;
  managerVersion_ = managerVersion;
  outputCount_ = outputCount;
  capabilityReason_ = reason;
  if (!waylandAvailable_ || managerVersion_ < 2) {
    protocolOwned_ = false;
    if (settings_.filterEnabled) {
      if (lostControllingCapability && backlightEngaged_) {
        (void)restoreHardwareAndJournal();
        backlightEngaged_ = false;
        driftCorrections_.clear();
        driftTimer_.stop();
      }
      runtimeState_ = RuntimeState::Unsupported;
      setAttention(reason.isEmpty() ? QStringLiteral("Hyprland CTM v2 is unavailable") : reason, true);
      scheduleBackendRetry();
    }
  } else if (!settings_.filterEnabled && runtimeState_ == RuntimeState::Unsupported) {
    runtimeState_ = RuntimeState::Off;
    clearAttention();
  } else if (managerVersion_ >= 2) {
    backendRetryAttempts_ = 0;
    backendRetryTimer_.stop();
  }
  publish();
}

void AppController::onApplied(qulonglong generation) {
  if (generation != generation_ || !settings_.filterEnabled || quitting_) return;
  processedGeneration_ = generation;
  protocolOwned_ = true;
  pixelsVerified_ = false;
  runtimeState_ = RuntimeState::CompositorControlled;
  backendRetryAttempts_ = 0;
  backendRetryTimer_.stop();
  lastError_.clear();
  clearAttention();
  if (settings_.backlightLockEnabled) (void)captureAndEngageBacklight();
  if (backlightEngaged_) driftTimer_.start();
  publish();
}

void AppController::onBlocked(qulonglong generation, QString reason) {
  if (generation != 0 && generation != generation_) return;
  if (!settings_.filterEnabled || quitting_) return;
  runtimeState_ = RuntimeState::Blocked;
  protocolOwned_ = false;
  capabilityReason_ = reason;
  lastError_ = QStringLiteral("Blocked by another color controller. Release it, then choose Retry.");
  setAttention(lastError_, true);
  if (backlightEngaged_) (void)restoreHardwareAndJournal();
  backlightEngaged_ = false;
  driftCorrections_.clear();
  driftTimer_.stop();
  publish();
}

void AppController::onBackendFailed(qulonglong generation, QString reason) {
  if (generation != 0 && generation != generation_) return;
  if (quitting_) return;
  if (!settings_.filterEnabled) return;
  lastError_ = reason;
  protocolOwned_ = false;
  runtimeState_ = managerVersion_ < 2 ? RuntimeState::Unsupported : RuntimeState::Degraded;
  setAttention(reason, true);
  if (backlightEngaged_) {
    (void)restoreHardwareAndJournal();
    backlightEngaged_ = false;
    driftCorrections_.clear();
    driftTimer_.stop();
  }
  scheduleBackendRetry();
  publish();
}

void AppController::onTopologyChanged() {
  if (!settings_.filterEnabled || quitting_) return;
  ++generation_;
  runtimeState_ = RuntimeState::Reconciling;
  invokeApply();
  publish();
}

void AppController::onReleased(qulonglong generation) {
  if (generation != generation_) return;
  protocolOwned_ = false;
  if (sleepRestoreInFlight_) {
    sleepRestoreInFlight_ = false;
    runtimeState_ = RuntimeState::Suspended;
  } else {
    runtimeState_ = recoveryPending_ ? RuntimeState::Degraded : RuntimeState::Off;
  }
  backlightEngaged_ = false;
  driftCorrections_.clear();
  driftTimer_.stop();
  releaseSleepInhibitor();
  publish();
}

void AppController::onScheduleTimer() { reconcileSchedule(); }

void AppController::onScheduleHealthTimer() { reconcileSchedule(); }

void AppController::onBackendRetry() {
  if (!settings_.filterEnabled || quitting_) return;
  ++generation_;
  runtimeState_ = RuntimeState::Enabling;
  invokeProbe();
  invokeApply();
  publish();
}

void AppController::onPrepareForSleep(bool sleeping) {
  if (sleeping) {
    sleepWasDesired_ = settings_.filterEnabled;
    if (settings_.filterEnabled) {
      ++generation_;
      runtimeState_ = RuntimeState::Restoring;
      sleepRestoreInFlight_ = true;
      const bool hardwareRestored = restoreHardwareAndJournal();
      releaseSleepInhibitor();
      if (hardwareRestored) {
        invokeRelease();
      } else {
        sleepRestoreInFlight_ = false;
        runtimeState_ = RuntimeState::Degraded;
        setAttention(QStringLiteral("Hardware recovery did not verify before sleep; Ember did not intentionally release its software dimming owner"), true);
      }
      publish();
    }
    return;
  }
  if (settings_.sunScheduleEnabled && !settings_.automationPaused && settings_.location.has_value()) {
    reconcileSchedule();
  } else if (sleepWasDesired_ && settings_.filterEnabled) {
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

void AppController::flushSettings() {
  const QString previousError = settingsSaveError_;
  persistNow();
  if (settingsSaveError_ != previousError) publish();
}

void AppController::updateTray() {
  if (tray_ == nullptr) return;
  const QVariantMap current = status();
  const bool active = current.value(QStringLiteral("effectiveFilterEnabled")).toBool();
  const bool attention = current.value(QStringLiteral("attentionSeverity")).toString() == QStringLiteral("error");
  tray_->setIcon(trayIcon(active, attention));
  tray_->setToolTip(QStringLiteral("Project Ember — %1").arg(current.value(QStringLiteral("statusTitle")).toString()));
  if (toggleAction_ != nullptr) toggleAction_->setText(active ? QStringLiteral("Turn Ember Off") : QStringLiteral("Turn Ember On"));
}

void AppController::createTray() {
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
    if (reason != QSystemTrayIcon::Trigger) return;
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
  wayland_->invalidateBefore(generation);
  QMetaObject::invokeMethod(wayland_, [backend = wayland_, matrix, generation] { backend->apply(matrix, generation); }, Qt::QueuedConnection);
}

void AppController::invokeRelease() {
  if (wayland_ == nullptr) {
    onReleased(generation_);
    return;
  }
  const qulonglong generation = generation_;
  wayland_->invalidateBefore(generation);
  QMetaObject::invokeMethod(wayland_, [backend = wayland_, generation] { backend->release(generation); }, Qt::QueuedConnection);
}

void AppController::invokeStop() {
  if (wayland_ == nullptr) return;
  QMetaObject::invokeMethod(wayland_, [backend = wayland_] { backend->stop(); }, Qt::BlockingQueuedConnection);
}

void AppController::scheduleFromLocation() {
  if (!settings_.sunScheduleEnabled || settings_.automationPaused) {
    scheduleTimer_.stop();
    scheduleHealthTimer_.stop();
    return;
  }
  scheduleHealthTimer_.start();
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
    scheduleHealthTimer_.stop();
    publish();
    return;
  }
  const QDateTime now = QDateTime::currentDateTime();
  bool overrideExpired = false;
  if (settings_.overrideExpiresAtMs.has_value() && now.toMSecsSinceEpoch() >= *settings_.overrideExpiresAtMs) {
    settings_.overrideExpiresAtMs.reset();
    overrideExpired = true;
  }
  const SolarSchedule schedule = solarSchedule(now, *settings_.location, QTimeZone::systemTimeZone());
  const bool target = settings_.overrideExpiresAtMs.has_value() ? settings_.overrideFilterEnabled : schedule.isNight;
  if (settings_.filterEnabled != target
      || (target && runtimeState_ != RuntimeState::CompositorControlled && runtimeState_ != RuntimeState::Enabling)) {
    setFilterEnabledInternal(target, true);
  }
  scheduleNextSolarBoundary();
  if (!scheduleHealthTimer_.isActive()) scheduleHealthTimer_.start();
  if (overrideExpired) persistSoon();
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

void AppController::scheduleBackendRetry() {
  if (!settings_.filterEnabled || quitting_ || backendRetryTimer_.isActive() || backendRetryAttempts_ >= 5) return;
  const int delayMs = 1000 * (1 << backendRetryAttempts_);
  ++backendRetryAttempts_;
  backendRetryTimer_.start(delayMs);
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
  if (recoveryWarning_.isEmpty() && settingsWarning_.isEmpty()) {
    attentionMessage_.clear();
    attentionError_ = false;
  }
}

void AppController::persistSoon() {
  persistTimer_.start();
}

void AppController::persistNow() {
  if (settingsPersistenceBlocked_) return;
  QString error;
  if (!settingsStore_.save(settings_, &error)) {
    settingsSaveError_ = QStringLiteral("Settings could not be saved: %1").arg(error);
  } else {
    settingsSaveError_.clear();
  }
}

bool AppController::restoreHardwareAndJournal() {
  const auto inhibitorGuard = qScopeGuard([this] { releaseSleepInhibitor(); });
  const RecoveryLoadResult result = journal_.load();
  if (result.kind == LoadKind::NoFile) {
    recoveryPending_ = false;
    recoveryUnreadable_ = false;
    recoveryWarning_.clear();
    return true;
  }
  if (result.kind != LoadKind::Loaded) {
    recoveryPending_ = true;
    recoveryUnreadable_ = true;
    recoveryWarning_ = QStringLiteral("Hardware recovery evidence could not be read: %1").arg(result.detail);
    return false;
  }
  RecoveryRecord record = result.record;
  recoveryUnreadable_ = false;
  if (!recoveryRecordHasPendingFields(record)) {
    QString clearError;
    if (!journal_.clear(&clearError)) {
      recoveryPending_ = true;
      recoveryWarning_ = QStringLiteral("Completed hardware recovery evidence could not be cleared: %1").arg(clearError);
      return false;
    }
    recoveryPending_ = false;
    recoveryUnreadable_ = false;
    recoveryWarning_.clear();
    return true;
  }
  QString error;
  if (!backlight_.restore(&record, &error)) {
    recoveryPending_ = true;
    QString saveError;
    if (!journal_.save(record, &saveError) && !saveError.isEmpty()) {
      error += QStringLiteral("; updated recovery evidence could not be saved: %1").arg(saveError);
    }
    recoveryWarning_ = QStringLiteral("Hardware restore needs attention: %1").arg(error);
    return false;
  }
  recoveryPending_ = false;
  recoveryUnreadable_ = false;
  QString clearError;
  if (!journal_.clear(&clearError)) {
    recoveryPending_ = true;
    recoveryWarning_ = QStringLiteral("Hardware restored but journal cleanup failed: %1").arg(clearError);
    return false;
  }
  recoveryWarning_.clear();
  return true;
}

bool AppController::captureAndEngageBacklight() {
  if (backlightEngaged_) return true;
  if (recoveryPending_) {
    setAttention(QStringLiteral("Backlight Lock is blocked until the pending hardware recovery evidence is resolved"), true);
    return false;
  }
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
  const QString bootId = hashBootId();
  const QString sessionId = hashSessionId();
  if (bootId.isEmpty() || sessionId.isEmpty()) {
    setAttention(QStringLiteral("Backlight Lock requires verified boot and graphical-session identity (XDG_SESSION_ID) for crash recovery"), true);
    return false;
  }
  if (backlightCapability_.devicePath.startsWith(QStringLiteral("/sys/")) && !sleepMonitoringAvailable_) {
    setAttention(QStringLiteral("Backlight Lock requires a working logind PrepareForSleep subscription"), true);
    return false;
  }
  if (!acquireSleepInhibitor(&error)) {
    setAttention(QStringLiteral("Backlight Lock requires a bounded logind sleep-delay inhibitor: %1").arg(error), true);
    return false;
  }
  bool keepInhibitor = false;
  const auto inhibitorGuard = qScopeGuard([this, &keepInhibitor] {
    if (!keepInhibitor) releaseSleepInhibitor();
  });
  RecoveryRecord record;
  record.createdAtMs = QDateTime::currentMSecsSinceEpoch();
  record.safetyPaused = false;
  HardwareRecord hardware;
  hardware.deviceId = backlightCapability_.deviceId;
  hardware.devicePath = backlightCapability_.devicePath;
  hardware.bootIdHash = bootId;
  hardware.sessionIdHash = sessionId;
  hardware.originalBrightness = original;
  hardware.lastWrittenBrightness = backlightCapability_.maximum;
  hardware.maximumBrightness = backlightCapability_.maximum;
  hardware.unresolved = true;
  record.hardware = hardware;
  if (backlightCapability_.automaticBrightnessAvailable) {
    int automatic = -1;
    if (!backlight_.readAutomaticBrightness(backlightCapability_, &automatic, &error)) {
      setAttention(QStringLiteral("Backlight Lock could not capture automatic-brightness state: %1").arg(error), true);
      return false;
    }
    if (automatic == 1) {
      AutomaticBrightnessRecord automaticRecord;
      automaticRecord.deviceId = backlightCapability_.deviceId;
      automaticRecord.devicePath = backlightCapability_.devicePath;
      automaticRecord.provider = backlightCapability_.automaticBrightnessProvider;
      automaticRecord.bootIdHash = bootId;
      automaticRecord.sessionIdHash = sessionId;
      automaticRecord.originalValue = 1;
      automaticRecord.lastWrittenValue = 0;
      automaticRecord.unresolved = true;
      record.automaticBrightness = automaticRecord;
    }
  }
  // The immutable baseline is durable before the maximum-brightness mutation.
  if (!journal_.save(record, &error)) {
    setAttention(QStringLiteral("Backlight Lock refused to change hardware because its recovery journal could not be saved: %1").arg(error), true);
    return false;
  }
  if (record.automaticBrightness.has_value()
      && !backlight_.writeAutomaticBrightness(backlightCapability_, 0, &error)) {
    recoveryPending_ = true;
    record.automaticBrightness->error = error;
    (void)backlight_.restore(&record);
    if (recoveryRecordHasPendingFields(record)) (void)journal_.save(record);
    else (void)journal_.clear();
    setAttention(QStringLiteral("Backlight Lock could not disable automatic brightness after journaling its baseline: %1").arg(error), true);
    return false;
  }
  if (!backlight_.write(backlightCapability_, backlightCapability_.maximum, &error)) {
    recoveryPending_ = true;
    record.hardware->unresolved = true;
    record.hardware->error = error;
    QString rollbackError;
    (void)backlight_.restore(&record, &rollbackError);
    if (recoveryRecordHasPendingFields(record)) (void)journal_.save(record);
    else (void)journal_.clear();
    setAttention(QStringLiteral("Backlight Lock failed after journaling the baseline: %1").arg(error), true);
    return false;
  }
  record.hardware->unresolved = false;
  if (record.automaticBrightness.has_value()) record.automaticBrightness->unresolved = false;
  if (!journal_.save(record, &error)) {
    recoveryPending_ = true;
    QString rollbackError;
    (void)backlight_.restore(&record, &rollbackError);
    if (recoveryRecordHasPendingFields(record)) (void)journal_.save(record);
    else (void)journal_.clear();
    setAttention(QStringLiteral("Backlight Lock rolled back because its engaged recovery record could not be updated: %1").arg(error), true);
    return false;
  }
  backlightEngaged_ = true;
  keepInhibitor = true;
  driftCorrections_.clear();
  recoveryPending_ = false;
  clearAttention();
  return true;
}

bool AppController::acquireSleepInhibitor(QString *error) {
  if (sleepInhibitorFd_ >= 0) return true;
  // Test backlights live outside sysfs and cannot involve the host logind.
  if (!backlightCapability_.devicePath.startsWith(QStringLiteral("/sys/"))) return true;
  const QDBusConnection bus = QDBusConnection::systemBus();
  if (!bus.isConnected()) {
    if (error != nullptr) *error = QStringLiteral("system D-Bus is unavailable");
    return false;
  }
  QDBusMessage request = QDBusMessage::createMethodCall(
      QStringLiteral("org.freedesktop.login1"), QStringLiteral("/org/freedesktop/login1"),
      QStringLiteral("org.freedesktop.login1.Manager"), QStringLiteral("Inhibit"));
  request.setArguments({QStringLiteral("sleep"), QStringLiteral("Project Ember"),
                        QStringLiteral("Restore Backlight Lock before sleep"), QStringLiteral("delay")});
  const QDBusMessage reply = bus.call(request, QDBus::Block, 1000);
  if (reply.type() == QDBusMessage::ErrorMessage || reply.arguments().isEmpty()) {
    if (error != nullptr) *error = reply.errorMessage().isEmpty() ? QStringLiteral("logind rejected the inhibitor") : reply.errorMessage();
    return false;
  }
  const QDBusUnixFileDescriptor descriptor = qvariant_cast<QDBusUnixFileDescriptor>(reply.arguments().constFirst());
  if (!descriptor.isValid()) {
    if (error != nullptr) *error = QStringLiteral("logind returned an invalid inhibitor descriptor");
    return false;
  }
  sleepInhibitorFd_ = fcntl(descriptor.fileDescriptor(), F_DUPFD_CLOEXEC, 3);
  if (sleepInhibitorFd_ < 0) {
    if (error != nullptr) *error = QStringLiteral("could not retain the sleep inhibitor");
    return false;
  }
  return true;
}

void AppController::releaseSleepInhibitor() {
  if (sleepInhibitorFd_ >= 0) {
    (void)close(sleepInhibitorFd_);
    sleepInhibitorFd_ = -1;
  }
}

bool AppController::setLoginRegistration(bool enabled) {
  QProcess process;
  QStringList arguments = {QStringLiteral("--user"), enabled ? QStringLiteral("enable") : QStringLiteral("disable"), QStringLiteral("project-ember.service")};
  process.start(systemctlExecutable(), arguments);
  if (!process.waitForStarted(500) || !process.waitForFinished(1500)) {
    process.kill();
    (void)process.waitForFinished(500);
    return false;
  }
  if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) return false;
  loginRegistered_ = enabled;
  settings_.launchAtLogin = enabled;
  return true;
}

bool AppController::loginIsRegistered() const {
  QProcess process;
  process.start(systemctlExecutable(), {QStringLiteral("--user"), QStringLiteral("is-enabled"), QStringLiteral("project-ember.service")});
  if (!process.waitForStarted(500) || !process.waitForFinished(1000)) {
    process.kill();
    (void)process.waitForFinished(500);
    return false;
  }
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
  const QString protocolOwnership = protocolOwned_ ? QStringLiteral("owned")
      : runtimeState_ == RuntimeState::Enabling ? QStringLiteral("acquiring")
      : runtimeState_ == RuntimeState::Blocked ? QStringLiteral("blocked")
      : runtimeState_ == RuntimeState::Restoring ? QStringLiteral("releasing")
      : QStringLiteral("none");
  result.insert(QStringLiteral("protocolOwnership"), protocolOwnership);
  result.insert(QStringLiteral("effectiveFilterEnabled"),
               settings_.filterEnabled && protocolOwned_);
  result.insert(QStringLiteral("waylandAvailable"), waylandAvailable_);
  result.insert(QStringLiteral("managerVersion"), managerVersion_);
  result.insert(QStringLiteral("onlineOutputs"), outputCount_);
  result.insert(QStringLiteral("requestProcessed"),
               settings_.filterEnabled && processedGeneration_ != 0 && processedGeneration_ == generation_);
  result.insert(QStringLiteral("requestedGeneration"), generation_);
  result.insert(QStringLiteral("requestProcessedGeneration"), processedGeneration_);
  result.insert(QStringLiteral("lastAcceptedRequestId"), lastAcceptedRequestId_);
  result.insert(QStringLiteral("pixelsVerified"), pixelsVerified_);
  result.insert(QStringLiteral("opticalReadback"), QStringLiteral("unavailable: Hyprland CTM has no pixel/color readback"));
  result.insert(QStringLiteral("backlightLockPreference"), settings_.backlightLockEnabled);
  result.insert(QStringLiteral("backlightEngaged"), backlightEngaged_);
  result.insert(QStringLiteral("backlightAvailable"), backlightCapability_.available);
  result.insert(QStringLiteral("backlightActualReadbackAvailable"), backlightCapability_.actualBrightnessAvailable);
  result.insert(QStringLiteral("backlightReason"), backlightCapability_.available ? QString() : backlightCapability_.reason);
  result.insert(QStringLiteral("automaticBrightnessManaged"),
                backlightEngaged_ && backlightCapability_.automaticBrightnessAvailable);
  result.insert(QStringLiteral("automaticBrightnessAvailable"), backlightCapability_.automaticBrightnessAvailable);
  result.insert(QStringLiteral("automaticBrightnessReason"), backlightCapability_.automaticBrightnessAvailable
      ? QString() : backlightCapability_.automaticBrightnessReason);
  result.insert(QStringLiteral("sunScheduleEnabled"), settings_.sunScheduleEnabled);
  result.insert(QStringLiteral("scheduleSessionOnly"), settings_.sunScheduleEnabled && !loginRegistered_);
  result.insert(QStringLiteral("locationConfigured"), settings_.location.has_value());
  result.insert(QStringLiteral("automationPaused"), settings_.automationPaused);
  result.insert(QStringLiteral("scheduleTimerActive"), scheduleTimer_.isActive());
  result.insert(QStringLiteral("scheduleHealthTimerActive"), scheduleHealthTimer_.isActive());
  result.insert(QStringLiteral("sleepDelayInhibitorHeld"), sleepInhibitorFd_ >= 0);
  result.insert(QStringLiteral("sleepMonitoringAvailable"), sleepMonitoringAvailable_);
  result.insert(QStringLiteral("launchAtLogin"), settings_.launchAtLogin);
  result.insert(QStringLiteral("loginRegistered"), loginRegistered_);
  result.insert(QStringLiteral("recoveryPending"), recoveryPending_);
  result.insert(QStringLiteral("recoveryUnreadable"), recoveryUnreadable_);
  result.insert(QStringLiteral("recoveryWarning"), recoveryWarning_);
  result.insert(QStringLiteral("settingsPersistenceBlocked"), settingsPersistenceBlocked_);
  result.insert(QStringLiteral("settingsWarning"), settingsWarning_);
  result.insert(QStringLiteral("settingsSaveError"), settingsSaveError_);
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
    result.insert(QStringLiteral("solarState"), settings_.automationPaused
        ? QStringLiteral("paused") : QStringLiteral("waiting_for_location"));
    result.insert(QStringLiteral("solarOverrideActive"), settings_.overrideExpiresAtMs.has_value());
  }
  const QString attention = !recoveryWarning_.isEmpty() ? recoveryWarning_
      : (!settingsWarning_.isEmpty() ? settingsWarning_
          : (!settingsSaveError_.isEmpty() ? settingsSaveError_
              : (!lastError_.isEmpty() ? lastError_ : attentionMessage_)));
  result.insert(QStringLiteral("attentionMessage"), attention);
  const bool attentionIsError = attentionError_ || !lastError_.isEmpty() || !settingsSaveError_.isEmpty()
      || !recoveryWarning_.isEmpty() || !settingsWarning_.isEmpty();
  result.insert(QStringLiteral("attentionSeverity"), attention.isEmpty() ? QStringLiteral("none")
      : (attentionIsError ? QStringLiteral("error") : QStringLiteral("info")));
  const QString statusTitle = runtimeState_ == RuntimeState::Restoring ? QStringLiteral("Ember is restoring")
      : !settings_.filterEnabled && recoveryPending_ ? QStringLiteral("Hardware recovery needs attention")
      : !settings_.filterEnabled && settings_.sunScheduleEnabled && settings_.automationPaused
          ? QStringLiteral("Ember is off — Sun automation paused")
      : !settings_.filterEnabled ? QStringLiteral("Ember is off")
      : runtimeState_ == RuntimeState::CompositorControlled ? QStringLiteral("Ember is on")
      : runtimeState_ == RuntimeState::Reconciling && protocolOwned_ ? QStringLiteral("Ember is updating")
      : runtimeState_ == RuntimeState::Enabling ? QStringLiteral("Ember is turning on")
      : QStringLiteral("Ember needs attention");
  result.insert(QStringLiteral("statusTitle"), statusTitle);
  QString statusDetail;
  if (runtimeState_ == RuntimeState::Restoring) {
    statusDetail = QStringLiteral("Restoration is in progress; displayed pixels and hardware brightness are not verified");
  } else if (recoveryPending_) {
    statusDetail = QStringLiteral("Ember does not claim restoration while hardware recovery remains pending");
  } else if (settings_.filterEnabled && runtimeState_ == RuntimeState::CompositorControlled) {
    statusDetail = QStringLiteral("Compositor-controlled; displayed pixels are not read back");
  } else if (settings_.filterEnabled) {
    statusDetail = runtimeStateName(runtimeState_);
  } else if (settings_.sunScheduleEnabled && settings_.automationPaused) {
    statusDetail = QStringLiteral("Filter intent is off; Sun automation requires explicit Resume after the safety restore");
  } else {
    statusDetail = QStringLiteral("Filter intent is off; Ember does not own a CTM manager");
  }
  result.insert(QStringLiteral("statusDetail"), statusDetail);
  return result;
}

QString AppController::diagnosticsText() const {
  const QVariantMap sanitized = sanitizedDiagnostics(status());
  return QString::fromUtf8(QJsonDocument::fromVariant(sanitized).toJson(QJsonDocument::Indented));
}

} // namespace ember
