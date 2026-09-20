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
  bool writable = false;
};

class BacklightController {
public:
  explicit BacklightController(Paths paths);

  BacklightCapability probe() const;
  bool read(const BacklightCapability &capability, int *value, QString *error = nullptr) const;
  bool write(const BacklightCapability &capability, int value, QString *error = nullptr) const;
  bool guardianArmed() const;
  bool armGuardian(QString *error = nullptr) const;
  bool disarmGuardian() const;

  bool restore(RecoveryRecord *record, QString *error = nullptr) const;

private:
  QString sysfsRoot() const;
  static QString readText(const QString &path);
  static bool writeText(const QString &path, const QString &value, QString *error);
  static QString makeDeviceId(const QString &canonicalPath, const QString &type, const QString &name);
  static bool looksLikeBuiltIn(const QString &name, const QString &canonicalDevicePath);

  Paths paths_;
};

} // namespace ember
