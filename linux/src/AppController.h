#pragma once

#include "core/Model.h"
#include "core/Persistence.h"
#include "platform/Backlight.h"

#include <QThread>
#include <QTimer>
#include <QList>
#include <QVariantMap>

class QAction;
class QMenu;
class QSystemTrayIcon;

namespace ember {

class WaylandBackend;
class SettingsDialog;
class DiagnosticsDialog;
class IpcAdaptor;

class AppController final : public QObject {
  Q_OBJECT

public:
  explicit AppController(bool guiEnabled, QObject *parent = nullptr);
  ~AppController() override;

  bool start(QString *error = nullptr);
  QVariantMap status() const;
  QString diagnosticsText() const;
  const Settings &settings() const { return settings_; }
  bool guiEnabled() const { return guiEnabled_; }

public slots:
  void openSettings();
  void openDiagnostics();
  void setFilterEnabled(bool enabled);
  void setPreset(const QString &preset);
  void setWarmth(double warmth);
  void setBrightness(double brightness);
  void setBacklightLock(bool enabled);
  void setSchedule(bool enabled);
  void setLaunchAtLogin(bool enabled);
  void setPrimaryAction(const QString &action);
  void setLocation(double latitude, double longitude);
  void clearLocation();
  void retry();
  void restore();
  void quit();

signals:
  void statusChanged(const QVariantMap &status);
  void requestQuit();

private slots:
  void onCapabilityChanged(bool waylandAvailable, int managerVersion, int outputCount, QString reason);
  void onApplied(qulonglong generation);
  void onBlocked(QString reason);
  void onBackendFailed(QString reason);
  void onTopologyChanged();
  void onReleased();
  void onScheduleTimer();
  void onPrepareForSleep(bool sleeping);
  void flushSettings();
  void updateTray();

private:
  void createTray();
  void createDialogs();
  void invokeProbe();
  void invokeApply();
  void invokeRelease();
  void invokeStop();
  void setFilterEnabledInternal(bool enabled, bool scheduleAction);
  void scheduleFromLocation();
  void reconcileSchedule();
  void scheduleNextSolarBoundary();
  void setAttention(const QString &message, bool error = false);
  void scheduleApply();
  void clearAttention();
  void persistSoon();
  void persistNow();
  bool restoreHardwareAndJournal();
  bool captureAndEngageBacklight();
  bool setLoginRegistration(bool enabled);
  bool loginIsRegistered() const;
  void publish();
  void finalizeQuit();

  bool guiEnabled_ = false;
  bool started_ = false;
  bool quitting_ = false;
  bool sleepRestoreInFlight_ = false;
  bool sleepWasDesired_ = false;
  bool waylandAvailable_ = false;
  bool pixelsVerified_ = false;
  bool backlightEngaged_ = false;
  bool recoveryPending_ = false;
  bool loginRegistered_ = false;
  int managerVersion_ = 0;
  int outputCount_ = 0;
  qulonglong generation_ = 0;
  qulonglong processedGeneration_ = 0;
  RuntimeState runtimeState_ = RuntimeState::Off;
  Settings settings_ = Settings::defaults();
  Paths paths_ = Paths::fromEnvironment();
  SettingsStore settingsStore_;
  RecoveryJournal journal_;
  BacklightController backlight_;
  BacklightCapability backlightCapability_;
  QString capabilityReason_;
  QString attentionMessage_;
  bool attentionError_ = false;
  QString lastError_;
  QString recoveryWarning_;
  bool settingsPersistenceBlocked_ = false;
  QList<qint64> driftCorrections_;

  QThread waylandThread_;
  WaylandBackend *wayland_ = nullptr;
  IpcAdaptor *ipcAdaptor_ = nullptr;
  QTimer persistTimer_;
  QTimer applyTimer_;
  QTimer scheduleTimer_;
  QTimer driftTimer_;
  QSystemTrayIcon *tray_ = nullptr;
  QMenu *trayMenu_ = nullptr;
  QAction *settingsAction_ = nullptr;
  QAction *toggleAction_ = nullptr;
  QAction *restoreAction_ = nullptr;
  QAction *quitAction_ = nullptr;
  SettingsDialog *settingsDialog_ = nullptr;
  DiagnosticsDialog *diagnosticsDialog_ = nullptr;
};

} // namespace ember
