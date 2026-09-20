#include "platform/Backlight.h"

#include "core/Recovery.h"

#include <QCryptographicHash>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>

#include <unistd.h>
#include <cerrno>
#include <utility>

namespace ember {

namespace {

QString envOr(const char *name, const QString &fallback) {
  const QByteArray value = qgetenv(name);
  return value.isEmpty() ? fallback : QString::fromUtf8(value);
}

} // namespace

BacklightController::BacklightController(Paths paths) : paths_(std::move(paths)) {}

QString BacklightController::sysfsRoot() const {
  return envOr("EMBER_BACKLIGHT_ROOT", QStringLiteral("/sys/class/backlight"));
}

BacklightCapability BacklightController::probe() const {
  BacklightCapability result;
  const QDir root(sysfsRoot());
  if (!root.exists()) {
    result.reason = QStringLiteral("Linux backlight class is unavailable");
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
    if (!looksLikeBuiltIn(name, devicePath)) continue;
    const QString brightnessPath = deviceDirectory.filePath(QStringLiteral("brightness"));
    const bool writable = ::access(brightnessPath.toUtf8().constData(), W_OK) == 0;
    if (!writable) continue;
    BacklightCapability candidate;
    candidate.available = true;
    // canonicalFilePath() resolves the /sys/class/backlight symlink to the
    // actual backlight directory, whose brightness file is the controlled
    // attribute. devicePath above is only used for built-in association.
    candidate.devicePath = entry.canonicalFilePath();
    candidate.deviceId = makeDeviceId(devicePath, type, name);
    candidate.maximum = maximum;
    candidate.brightness = current;
    candidate.writable = true;
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
  return true;
}

bool BacklightController::guardianArmed() const {
  QByteArray data;
  QFile file(paths_.guardianFile);
  if (!file.open(QIODevice::ReadOnly)) return false;
  data = file.readAll();
  QJsonParseError parseError {};
  const QJsonDocument document = QJsonDocument::fromJson(data, &parseError);
  if (parseError.error != QJsonParseError::NoError || !document.isObject()) return false;
  const QJsonObject object = document.object();
  return object.value(QStringLiteral("armed")).toBool(false)
      && object.value(QStringLiteral("bootIdHash")).toString() == hashBootId();
}

bool BacklightController::armGuardian(QString *error) const {
  if (!ensurePrivateDirectory(paths_.runtimeDir, error)) return false;
  QJsonObject object;
  object.insert(QStringLiteral("armed"), true);
  object.insert(QStringLiteral("bootIdHash"), hashBootId());
  object.insert(QStringLiteral("pid"), static_cast<qint64>(QCoreApplication::applicationPid()));
  return writeDurableFile(paths_.guardianFile, QJsonDocument(object).toJson(QJsonDocument::Compact), 0600, error);
}

bool BacklightController::disarmGuardian() const {
  return unlink(paths_.guardianFile.toUtf8().constData()) == 0 || errno == ENOENT;
}

bool BacklightController::restore(RecoveryRecord *record, QString *error) const {
  if (!record->hardware.has_value()) return true;
  const HardwareRecord hardware = *record->hardware;
  const BacklightCapability capability = probe();
  if (!capability.available || capability.deviceId != hardware.deviceId || capability.devicePath != hardware.devicePath) {
    if (error != nullptr) *error = QStringLiteral("saved backlight identity is unavailable or ambiguous");
    return false;
  }
  int current = -1;
  if (!read(capability, &current, error)) return false;
  const HardwareRestoreDecision decision = decideHardwareRestore(hardware, current, hashBootId());
  if (decision == HardwareRestoreDecision::PreserveUncertain) {
    if (error != nullptr) *error = QStringLiteral("backlight changed outside Ember; recovery was preserved");
    return false;
  }
  if (decision == HardwareRestoreDecision::Restore && !write(capability, hardware.originalBrightness, error)) return false;
  int observed = -1;
  if (!read(capability, &observed, error) || observed != hardware.originalBrightness) {
    if (error != nullptr && error->isEmpty()) *error = QStringLiteral("restored backlight value did not verify");
    return false;
  }
  record->hardware.reset();
  return true;
}

QString BacklightController::readText(const QString &path) {
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly)) return {};
  return QString::fromUtf8(file.readAll());
}

bool BacklightController::writeText(const QString &path, const QString &value, QString *error) {
  QFile file(path);
  if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
    if (error != nullptr) *error = file.errorString();
    return false;
  }
  if (file.write(value.toUtf8()) != value.toUtf8().size() || !file.flush()) {
    if (error != nullptr) *error = file.errorString();
    return false;
  }
  return true;
}

QString BacklightController::makeDeviceId(const QString &canonicalPath, const QString &type, const QString &name) {
  const QByteArray material = (canonicalPath + QLatin1Char('\n') + type + QLatin1Char('\n') + name).toUtf8();
  return QString::fromLatin1(QCryptographicHash::hash(material, QCryptographicHash::Sha256).toHex().left(24));
}

bool BacklightController::looksLikeBuiltIn(const QString &name, const QString &canonicalDevicePath) {
  const QString material = (name + QLatin1Char(' ') + canonicalDevicePath).toLower();
  static const QStringList hints = {QStringLiteral("edp"), QStringLiteral("lvds"), QStringLiteral("panel"), QStringLiteral("internal")};
  return std::any_of(hints.cbegin(), hints.cend(), [&material](const QString &hint) { return material.contains(hint); });
}

} // namespace ember
