#include "platform/Backlight.h"

#include "core/Recovery.h"

#include <QCryptographicHash>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QStringList>
#include <QThread>

#include <unistd.h>
#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <utility>

namespace ember {

namespace {

QString envOr(const char *name, const QString &fallback) {
  const QByteArray value = qgetenv(name);
  return value.isEmpty() ? fallback : QString::fromUtf8(value);
}

QString invocationIdHash() {
  const QByteArray invocationId = qgetenv("INVOCATION_ID").trimmed();
  if (invocationId.isEmpty()) return {};
  return QString::fromLatin1(QCryptographicHash::hash(invocationId, QCryptographicHash::Sha256).toHex().left(24));
}

} // namespace

BacklightController::BacklightController(Paths paths) : paths_(std::move(paths)) {}

QString BacklightController::sysfsRoot() const {
  return envOr("EMBER_BACKLIGHT_ROOT", QStringLiteral("/sys/class/backlight"));
}

QString BacklightController::drmRoot() const {
  return envOr("EMBER_DRM_ROOT", QStringLiteral("/sys/class/drm"));
}

BacklightCapability BacklightController::probe() const {
  BacklightCapability result;
  result.automaticBrightnessReason = QStringLiteral(
      "Automatic brightness is unmanaged: Linux backlight sysfs has no documented generic toggle and no target-specific provider is configured");
  const QDir root(sysfsRoot());
  if (!root.exists()) {
    result.reason = QStringLiteral("Linux backlight class is unavailable");
    return result;
  }
  struct InternalConnector {
    QString name;
    QString devicePath;
    QByteArray edidHash;
  };
  QList<InternalConnector> connectors;
  const QRegularExpression internalName(QStringLiteral("^card[0-9]+-(eDP|LVDS)-[0-9]+$"),
                                        QRegularExpression::CaseInsensitiveOption);
  const QDir drm(drmRoot());
  for (const QFileInfo &entry : drm.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::Readable, QDir::Name)) {
    if (!internalName.match(entry.fileName()).hasMatch()) continue;
    const QDir connector(entry.filePath());
    if (readText(connector.filePath(QStringLiteral("status"))).trimmed() != QStringLiteral("connected")) continue;
    const QString connectorDevice = QFileInfo(connector.filePath(QStringLiteral("device"))).canonicalFilePath();
    const QByteArray edid = readBytes(connector.filePath(QStringLiteral("edid")));
    if (connectorDevice.isEmpty() || edid.isEmpty()) continue;
    connectors.append({entry.fileName(), connectorDevice,
                       QCryptographicHash::hash(edid, QCryptographicHash::Sha256).toHex()});
  }
  if (connectors.isEmpty()) {
    result.reason = QStringLiteral("No connected internal eDP/LVDS connector with a readable EDID was found");
    return result;
  }

  const QFileInfoList entries = root.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::Readable, QDir::Name);
  QList<BacklightCapability> candidates;
  for (const QFileInfo &entry : entries) {
    const QString name = entry.fileName();
    const QDir deviceDirectory(entry.filePath());
    const QString maxText = readText(deviceDirectory.filePath(QStringLiteral("max_brightness"))).trimmed();
    const QString currentText = readText(deviceDirectory.filePath(QStringLiteral("brightness"))).trimmed();
    bool maxOk = false;
    bool currentOk = false;
    const int maximum = maxText.toInt(&maxOk);
    const int current = currentText.toInt(&currentOk);
    if (!maxOk || !currentOk || maximum <= 0 || current < 0 || current > maximum) continue;
    const QString type = readText(deviceDirectory.filePath(QStringLiteral("type"))).trimmed().toLower();
    if (!type.isEmpty() && type != QStringLiteral("raw") && type != QStringLiteral("platform") && type != QStringLiteral("firmware")) continue;
    const QString devicePath = QFileInfo(deviceDirectory.filePath(QStringLiteral("device"))).canonicalFilePath();
    if (devicePath.isEmpty()) continue;
    QList<InternalConnector> matches;
    for (const InternalConnector &connector : connectors) {
      if (connector.devicePath == devicePath) matches.append(connector);
    }
    if (matches.size() != 1) continue;
    const QString brightnessPath = deviceDirectory.filePath(QStringLiteral("brightness"));
    const bool writable = ::access(brightnessPath.toUtf8().constData(), W_OK) == 0;
    if (!writable) continue;
    const QString driverPath = QFileInfo(deviceDirectory.filePath(QStringLiteral("device/driver"))).canonicalFilePath();
    if (driverPath.isEmpty()) continue;
    BacklightCapability candidate;
    candidate.available = true;
    // canonicalFilePath() resolves the /sys/class/backlight symlink to the
    // actual backlight directory, whose brightness file is the controlled
    // attribute. devicePath above is only used for built-in association.
    candidate.devicePath = entry.canonicalFilePath();
    const QByteArray identity = matches.first().edidHash + '\n'
        + QFileInfo(driverPath).fileName().toUtf8() + '\n'
        + type.toUtf8() + '\n' + QByteArray::number(maximum);
    candidate.deviceId = makeDeviceId(identity);
    candidate.maximum = maximum;
    candidate.brightness = current;
    candidate.writable = true;
    candidate.connectorName = matches.first().name;
    const QString actualText = readText(deviceDirectory.filePath(QStringLiteral("actual_brightness"))).trimmed();
    bool actualOk = false;
    const int actual = actualText.toInt(&actualOk);
    if (actualOk && actual >= 0 && actual <= maximum) {
      candidate.actualBrightnessAvailable = true;
      candidate.actualBrightness = actual;
    }
    const QString automaticPath = deviceDirectory.filePath(QStringLiteral("auto_brightness"));
    // Linux's documented backlight class has no generic automatic-brightness
    // switch. The boolean file adapter is available only for isolated tests;
    // a real target remains unmanaged until a provider with documented
    // capture/disable/restore semantics is identified.
    const bool testAutomaticProvider = qgetenv("EMBER_TEST_AUTOMATIC_BRIGHTNESS_PROVIDER") == QByteArray("sysfs-boolean-v1")
        && !QFileInfo(sysfsRoot()).canonicalFilePath().startsWith(QStringLiteral("/sys/"));
    if (testAutomaticProvider && QFileInfo::exists(automaticPath)) {
      bool automaticOk = false;
      const int automatic = readText(automaticPath).trimmed().toInt(&automaticOk);
      if (automaticOk && (automatic == 0 || automatic == 1)
          && ::access(automaticPath.toUtf8().constData(), W_OK) == 0) {
        candidate.automaticBrightnessAvailable = true;
        candidate.automaticBrightnessProvider = QStringLiteral("test:sysfs:auto_brightness:boolean-v1");
        candidate.automaticBrightness = automatic;
      } else {
        candidate.automaticBrightnessReason = QStringLiteral("auto_brightness exists but is not a writable 0/1 provider");
      }
    } else {
      candidate.automaticBrightnessReason = QStringLiteral("Automatic brightness is unmanaged: Linux backlight sysfs has no documented generic toggle and no target-specific provider is configured");
    }
    candidates.append(candidate);
  }
  if (candidates.size() != 1) {
    result.reason = candidates.isEmpty()
        ? QStringLiteral("No unambiguous writable built-in LCD backlight was found")
        : QStringLiteral("Multiple possible built-in backlights were found; left untouched");
    return result;
  }
  return candidates.first();
}

bool BacklightController::read(const BacklightCapability &capability, int *value, QString *error) const {
  if (!capability.available || capability.devicePath.isEmpty()) {
    if (error != nullptr) *error = QStringLiteral("backlight capability is unavailable");
    return false;
  }
  const QString path = QDir(capability.devicePath).filePath(QStringLiteral("brightness"));
  bool ok = false;
  const int current = readText(path).trimmed().toInt(&ok);
  if (!ok || current < 0 || current > capability.maximum) {
    if (error != nullptr) *error = QStringLiteral("backlight readback is invalid");
    return false;
  }
  *value = current;
  return true;
}

bool BacklightController::write(const BacklightCapability &capability, int value, QString *error) const {
  if (!capability.available || value < 0 || value > capability.maximum) {
    if (error != nullptr) *error = QStringLiteral("backlight write is outside the captured capability");
    return false;
  }
  const QString path = QDir(capability.devicePath).filePath(QStringLiteral("brightness"));
  if (!writeText(path, QString::number(value), error)) return false;
  int observed = -1;
  if (!read(capability, &observed, error) || observed != value) {
    if (error != nullptr && error->isEmpty()) *error = QStringLiteral("backlight write did not verify");
    return false;
  }
  if (capability.actualBrightnessAvailable) {
    const int tolerance = std::max(1, static_cast<int>(std::ceil(static_cast<double>(capability.maximum) * 0.02)));
    bool verified = false;
    QString readbackError;
    for (int attempt = 0; attempt < 4; ++attempt) {
      if (attempt != 0) QThread::msleep(10);
      readbackError.clear();
      if (readActualBrightness(capability, &observed, &readbackError) && std::abs(observed - value) <= tolerance) {
        verified = true;
        break;
      }
    }
    if (!verified) {
      if (error != nullptr) {
        *error = readbackError.isEmpty()
            ? QStringLiteral("actual backlight readback remained outside the 2% driver tolerance")
            : readbackError;
      }
      return false;
    }
    if (error != nullptr) error->clear();
  }
  return true;
}

bool BacklightController::readActualBrightness(const BacklightCapability &capability, int *value, QString *error) const {
  if (!capability.available || !capability.actualBrightnessAvailable) {
    if (error != nullptr) *error = QStringLiteral("actual backlight readback is unavailable");
    return false;
  }
  bool ok = false;
  const int current = readText(QDir(capability.devicePath).filePath(QStringLiteral("actual_brightness"))).trimmed().toInt(&ok);
  if (!ok || current < 0 || current > capability.maximum) {
    if (error != nullptr) *error = QStringLiteral("actual backlight readback is invalid");
    return false;
  }
  *value = current;
  return true;
}

bool BacklightController::readAutomaticBrightness(const BacklightCapability &capability, int *value, QString *error) const {
  if (!capability.available || !capability.automaticBrightnessAvailable || capability.devicePath.isEmpty()) {
    if (error != nullptr) *error = QStringLiteral("automatic-brightness capability is unavailable");
    return false;
  }
  bool ok = false;
  const int current = readText(QDir(capability.devicePath).filePath(QStringLiteral("auto_brightness"))).trimmed().toInt(&ok);
  if (!ok || (current != 0 && current != 1)) {
    if (error != nullptr) *error = QStringLiteral("automatic-brightness readback is invalid");
    return false;
  }
  *value = current;
  return true;
}

bool BacklightController::writeAutomaticBrightness(const BacklightCapability &capability, int value, QString *error) const {
  if (!capability.automaticBrightnessAvailable || (value != 0 && value != 1)) {
    if (error != nullptr) *error = QStringLiteral("automatic-brightness write is outside the captured capability");
    return false;
  }
  const QString path = QDir(capability.devicePath).filePath(QStringLiteral("auto_brightness"));
  if (!writeText(path, QString::number(value), error)) return false;
  int observed = -1;
  if (!readAutomaticBrightness(capability, &observed, error) || observed != value) {
    if (error != nullptr && error->isEmpty()) *error = QStringLiteral("automatic-brightness write did not verify");
    return false;
  }
  return true;
}

bool BacklightController::guardianArmed() const {
  QByteArray data;
  if (!readRegularPrivateFile(paths_.guardianFile, &data)) return false;
  QJsonParseError parseError {};
  const QJsonDocument document = QJsonDocument::fromJson(data, &parseError);
  if (parseError.error != QJsonParseError::NoError || !document.isObject()) return false;
  const QJsonObject object = document.object();
  const QString currentInvocation = invocationIdHash();
  return !currentInvocation.isEmpty()
      && object.value(QStringLiteral("armed")).toBool(false)
      && object.value(QStringLiteral("bootIdHash")).toString() == hashBootId()
      && object.value(QStringLiteral("invocationIdHash")).toString() == currentInvocation;
}

bool BacklightController::armGuardian(QString *error) const {
  const QString invocation = invocationIdHash();
  if (invocation.isEmpty()) {
    if (error != nullptr) *error = QStringLiteral("the recovery guardian must be armed by the supervised systemd user service");
    return false;
  }
  if (!ensurePrivateDirectory(paths_.runtimeDir, error)) return false;
  QJsonObject object;
  object.insert(QStringLiteral("armed"), true);
  object.insert(QStringLiteral("bootIdHash"), hashBootId());
  object.insert(QStringLiteral("invocationIdHash"), invocation);
  object.insert(QStringLiteral("pid"), static_cast<qint64>(QCoreApplication::applicationPid()));
  return writeDurableFile(paths_.guardianFile, QJsonDocument(object).toJson(QJsonDocument::Compact), 0600, error);
}

bool BacklightController::disarmGuardian() const {
  return removeDurableFile(paths_.guardianFile);
}

bool BacklightController::restore(RecoveryRecord *record, QString *error) const {
  if (!recoveryRecordHasPendingFields(*record)) return true;
  const BacklightCapability capability = probe();
  QStringList errors;
  const QString bootId = hashBootId();
  const QString sessionId = hashSessionId();
  if (record->hardware.has_value()) {
    const HardwareRecord hardware = *record->hardware;
    QString fieldError;
    if (!capability.available || capability.deviceId != hardware.deviceId) {
      fieldError = QStringLiteral("saved backlight identity is unavailable or ambiguous");
    } else {
      int current = -1;
      if (!read(capability, &current, &fieldError)) {
        // Preserve this field and continue with automatic brightness.
      } else {
        const HardwareRestoreDecision decision = decideHardwareRestore(hardware, current, bootId, sessionId);
        if (decision == HardwareRestoreDecision::PreserveUncertain) {
          fieldError = QStringLiteral("backlight changed outside Ember; brightness recovery was preserved");
        } else if (decision == HardwareRestoreDecision::Restore
                   && !write(capability, hardware.originalBrightness, &fieldError)) {
          // Preserve the record.
        } else {
          record->hardware.reset();
        }
      }
    }
    if (!fieldError.isEmpty()) {
      record->hardware->unresolved = true;
      record->hardware->error = fieldError;
      errors.append(fieldError);
    }
  }
  if (record->automaticBrightness.has_value()) {
    const AutomaticBrightnessRecord automatic = *record->automaticBrightness;
    QString fieldError;
    if (!capability.available || capability.deviceId != automatic.deviceId
        || !capability.automaticBrightnessAvailable
        || capability.automaticBrightnessProvider != automatic.provider) {
      fieldError = QStringLiteral("saved automatic-brightness provider is unavailable or ambiguous");
    } else {
      int current = -1;
      if (!readAutomaticBrightness(capability, &current, &fieldError)) {
        // Preserve this field independently.
      } else {
        const HardwareRestoreDecision decision = decideAutomaticBrightnessRestore(automatic, current, bootId, sessionId);
        if (decision == HardwareRestoreDecision::PreserveUncertain) {
          fieldError = QStringLiteral("automatic brightness changed outside Ember; recovery was preserved");
        } else if (decision == HardwareRestoreDecision::Restore
                   && !writeAutomaticBrightness(capability, automatic.originalValue, &fieldError)) {
          // Preserve the record.
        } else {
          record->automaticBrightness.reset();
        }
      }
    }
    if (!fieldError.isEmpty()) {
      record->automaticBrightness->unresolved = true;
      record->automaticBrightness->error = fieldError;
      errors.append(fieldError);
    }
  }
  if (error != nullptr) *error = errors.join(QStringLiteral("; "));
  return !recoveryRecordHasPendingFields(*record);
}

QString BacklightController::readText(const QString &path) {
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly)) return {};
  return QString::fromUtf8(file.readAll());
}

QByteArray BacklightController::readBytes(const QString &path, qsizetype maximumBytes) {
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly)) return {};
  const QByteArray data = file.read(maximumBytes + 1);
  if (data.size() > maximumBytes || file.error() != QFileDevice::NoError) return {};
  return data;
}

bool BacklightController::writeText(const QString &path, const QString &value, QString *error) {
  const QByteArray bytes = value.toUtf8();
  const int fd = ::open(path.toUtf8().constData(), O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) {
    if (error != nullptr) *error = QString::fromLocal8Bit(std::strerror(errno));
    return false;
  }
  qsizetype offset = 0;
  while (offset < bytes.size()) {
    const ssize_t written = ::write(fd, bytes.constData() + offset, static_cast<size_t>(bytes.size() - offset));
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) {
      if (error != nullptr) *error = QStringLiteral("backlight write failed: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
      (void)close(fd);
      return false;
    }
    offset += written;
  }
  if (close(fd) != 0) {
    if (error != nullptr) *error = QStringLiteral("backlight write close failed");
    return false;
  }
  return true;
}

QString BacklightController::makeDeviceId(const QByteArray &identityMaterial) {
  return QString::fromLatin1(QCryptographicHash::hash(identityMaterial, QCryptographicHash::Sha256).toHex().left(24));
}

} // namespace ember
