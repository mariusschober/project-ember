#pragma once

#include "core/Model.h"
#include "core/Persistence.h"

#include <QString>

namespace ember {

struct BacklightCapability {
  bool available = false;
  QString reason;
  QString deviceId;
  QString devicePath;
  int maximum = 0;
  int brightness = -1;
  bool actualBrightnessAvailable = false;
  int actualBrightness = -1;
  bool writable = false;
  QString connectorName;
  bool automaticBrightnessAvailable = false;
  QString automaticBrightnessProvider;
  int automaticBrightness = -1;
  QString automaticBrightnessReason;
};

class BacklightController {
public:
  explicit BacklightController(Paths paths);

  BacklightCapability probe() const;
  bool read(const BacklightCapability &capability, int *value, QString *error = nullptr) const;
  bool readActualBrightness(const BacklightCapability &capability, int *value, QString *error = nullptr) const;
  bool write(const BacklightCapability &capability, int value, QString *error = nullptr) const;
  bool readAutomaticBrightness(const BacklightCapability &capability, int *value, QString *error = nullptr) const;
  bool writeAutomaticBrightness(const BacklightCapability &capability, int value, QString *error = nullptr) const;
  bool guardianArmed() const;
  bool armGuardian(QString *error = nullptr) const;
  bool disarmGuardian() const;

  bool restore(RecoveryRecord *record, QString *error = nullptr) const;

private:
  QString sysfsRoot() const;
  QString drmRoot() const;
  static QString readText(const QString &path);
  static QByteArray readBytes(const QString &path, qsizetype maximumBytes = 65536);
  static bool writeText(const QString &path, const QString &value, QString *error);
  static QString makeDeviceId(const QByteArray &identityMaterial);

  Paths paths_;
};

} // namespace ember
