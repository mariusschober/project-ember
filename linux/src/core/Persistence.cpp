#include "core/Persistence.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonParseError>
#include <QLockFile>
#include <QStandardPaths>
#include <QCoreApplication>

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace ember {

namespace {

constexpr int maxSupportedSettingsSchema = Settings::schemaVersion;
constexpr int maxSupportedRecoverySchema = RecoveryRecord::schemaVersion;

QString envOr(const char *name, const QString &fallback) {
  const QByteArray value = qgetenv(name);
  return value.isEmpty() ? fallback : QString::fromUtf8(value);
}

bool rejectSymlink(const QString &path, QString *error) {
  struct stat info {};
  if (lstat(path.toUtf8().constData(), &info) == 0 && S_ISLNK(info.st_mode)) {
    if (error != nullptr) *error = QStringLiteral("refusing symlink: %1").arg(path);
    return false;
  }
  return true;
}

bool writeAll(int fd, const QByteArray &data, QString *error) {
  qsizetype offset = 0;
  while (offset < data.size()) {
    const ssize_t written = ::write(fd, data.constData() + offset, static_cast<size_t>(data.size() - offset));
    if (written < 0) {
      if (errno == EINTR) continue;
      if (error != nullptr) *error = QStringLiteral("write failed: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
      return false;
    }
    if (written == 0) {
      if (error != nullptr) *error = QStringLiteral("write returned zero");
      return false;
    }
    offset += written;
  }
  return true;
}

bool jsonNumber(const QJsonObject &object, const char *key, double *value, QString *error) {
  const QJsonValue json = object.value(QLatin1String(key));
  if (!json.isDouble()) {
    if (error != nullptr) *error = QStringLiteral("%1 must be a number").arg(QString::fromLatin1(key));
    return false;
  }
  *value = json.toDouble();
  return true;
}

bool jsonBool(const QJsonObject &object, const char *key, bool *value, QString *error) {
  const QJsonValue json = object.value(QLatin1String(key));
  if (!json.isBool()) {
    if (error != nullptr) *error = QStringLiteral("%1 must be boolean").arg(QString::fromLatin1(key));
    return false;
  }
  *value = json.toBool();
  return true;
}

bool lockRecoveryJournal(const Paths &paths, QLockFile *lock, QString *error, bool createDirectory) {
  if (createDirectory) {
    if (!ensurePrivateDirectory(paths.stateDir, error)) return false;
  } else if (!QFileInfo::exists(paths.stateDir)) {
    return true;
  } else if (!rejectSymlink(paths.stateDir, error)) {
    return false;
  }
  lock->setStaleLockTime(5000);
  if (lock->tryLock(1000)) return true;
  if (error != nullptr) *error = QStringLiteral("recovery journal is busy");
  return false;
}

} // namespace

Paths Paths::fromEnvironment() {
  const QString home = QDir::homePath();
  const QString configRoot = envOr("XDG_CONFIG_HOME", QDir(home).filePath(QStringLiteral(".config")));
  const QString stateRoot = envOr("XDG_STATE_HOME", QDir(home).filePath(QStringLiteral(".local/state")));
  const QString runtimeRoot = envOr("XDG_RUNTIME_DIR", QDir::tempPath());
  Paths paths;
  paths.configDir = QDir(configRoot).filePath(QStringLiteral("project-ember"));
  paths.stateDir = QDir(stateRoot).filePath(QStringLiteral("project-ember"));
  paths.runtimeDir = QDir(runtimeRoot).filePath(QStringLiteral("project-ember"));
  paths.settingsFile = QDir(paths.configDir).filePath(QStringLiteral("settings.json"));
  paths.recoveryFile = QDir(paths.stateDir).filePath(QStringLiteral("recovery.json"));
  paths.safetyLatchFile = QDir(paths.stateDir).filePath(QStringLiteral("automation-paused"));
  paths.guardianFile = QDir(paths.runtimeDir).filePath(QStringLiteral("guardian.json"));
  paths.cleanExitFile = QDir(paths.runtimeDir).filePath(QStringLiteral("clean-exit"));
  return paths;
}

SettingsStore::SettingsStore(Paths paths) : paths_(std::move(paths)) {}

SettingsLoadResult SettingsStore::load() const {
  SettingsLoadResult result;
  QByteArray data;
  QString error;
  if (!readRegularPrivateFile(paths_.settingsFile, &data, &error)) {
    if (error == QStringLiteral("not found")) return result;
    result.kind = LoadKind::IoFailure;
    result.detail = error;
    return result;
  }
  QJsonParseError parseError {};
  const QJsonDocument document = QJsonDocument::fromJson(data, &parseError);
  if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
    result.kind = LoadKind::Corrupt;
    result.detail = parseError.errorString();
    return result;
  }
  QString decodeError;
  int schema = 0;
  if (!settingsFromJson(document.object(), &result.settings, &schema, &decodeError)) {
    result.kind = decodeError.startsWith(QStringLiteral("unsupported schema"))
        ? LoadKind::FutureSchema : LoadKind::Corrupt;
    result.detail = decodeError;
    result.schema = schema;
    return result;
  }
  result.kind = LoadKind::Loaded;
  result.schema = schema;
  return result;
}

bool SettingsStore::save(const Settings &settings, QString *error) const {
  QString validation;
  if (!settings.validate(&validation)) {
    if (error != nullptr) *error = validation;
    return false;
  }
  if (!ensurePrivateDirectory(paths_.configDir, error)) return false;
  const QByteArray data = QJsonDocument(settingsToJson(settings)).toJson(QJsonDocument::Compact) + '\n';
  return writeDurableFile(paths_.settingsFile, data, 0600, error);
}

RecoveryJournal::RecoveryJournal(Paths paths) : paths_(std::move(paths)) {}

RecoveryLoadResult RecoveryJournal::load() const {
  RecoveryLoadResult result;
  QLockFile lock(paths_.recoveryFile + QStringLiteral(".lock"));
  QString lockError;
  if (!lockRecoveryJournal(paths_, &lock, &lockError, false)) {
    result.kind = LoadKind::IoFailure;
    result.detail = lockError;
    return result;
  }
  QByteArray data;
  QString error;
  if (!readRegularPrivateFile(paths_.recoveryFile, &data, &error)) {
    if (error == QStringLiteral("not found")) return result;
    result.kind = LoadKind::IoFailure;
    result.detail = error;
    return result;
  }
  if (data.isEmpty()) {
    result.kind = LoadKind::Corrupt;
    result.detail = QStringLiteral("recovery journal is empty");
    return result;
  }
  QJsonParseError parseError {};
  const QJsonDocument document = QJsonDocument::fromJson(data, &parseError);
  if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
    result.kind = LoadKind::Corrupt;
    result.detail = parseError.errorString();
    return result;
  }
  QString decodeError;
  int schema = 0;
  if (!recoveryFromJson(document.object(), &result.record, &schema, &decodeError)) {
    result.kind = decodeError.startsWith(QStringLiteral("unsupported schema"))
        ? LoadKind::FutureSchema : LoadKind::Corrupt;
    result.detail = decodeError;
    result.schema = schema;
    return result;
  }
  result.kind = LoadKind::Loaded;
  result.schema = schema;
  return result;
}

bool RecoveryJournal::save(const RecoveryRecord &record, QString *error) const {
  if (record.schema > maxSupportedRecoverySchema) {
    if (error != nullptr) *error = QStringLiteral("unsupported recovery schema");
    return false;
  }
  QLockFile lock(paths_.recoveryFile + QStringLiteral(".lock"));
  if (!lockRecoveryJournal(paths_, &lock, error, true)) return false;
  const QByteArray data = QJsonDocument(recoveryToJson(record)).toJson(QJsonDocument::Compact) + '\n';
  return writeDurableFile(paths_.recoveryFile, data, 0600, error);
}

bool RecoveryJournal::clear(QString *error) const {
  QLockFile lock(paths_.recoveryFile + QStringLiteral(".lock"));
  if (!lockRecoveryJournal(paths_, &lock, error, false)) return false;
  if (!exists()) return true;
  if (unlink(paths_.recoveryFile.toUtf8().constData()) != 0 && errno != ENOENT) {
    if (error != nullptr) *error = QStringLiteral("could not clear recovery journal: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
    return false;
  }
  const int directoryFd = ::open(paths_.stateDir.toUtf8().constData(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (directoryFd >= 0) {
    (void)fsync(directoryFd);
    (void)close(directoryFd);
  }
  return true;
}

bool RecoveryJournal::quarantine(QString *quarantinedPath, QString *error) const {
  QLockFile lock(paths_.recoveryFile + QStringLiteral(".lock"));
  if (!lockRecoveryJournal(paths_, &lock, error, false)) return false;
  if (!exists()) return true;
  const QString target = paths_.recoveryFile + QStringLiteral(".corrupt");
  if (!rejectSymlink(paths_.recoveryFile, error) || !rejectSymlink(target, error)) return false;
  (void)unlink(target.toUtf8().constData());
  if (rename(paths_.recoveryFile.toUtf8().constData(), target.toUtf8().constData()) != 0) {
    if (error != nullptr) *error = QStringLiteral("could not quarantine recovery journal: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
    return false;
  }
  if (quarantinedPath != nullptr) *quarantinedPath = target;
  return true;
}

bool RecoveryJournal::exists() const {
  struct stat info {};
  return lstat(paths_.recoveryFile.toUtf8().constData(), &info) == 0 && S_ISREG(info.st_mode);
}

bool ensurePrivateDirectory(const QString &path, QString *error) {
  if (!QDir().mkpath(path)) {
    if (error != nullptr) *error = QStringLiteral("could not create private directory: %1").arg(path);
    return false;
  }
  if (!rejectSymlink(path, error)) return false;
  if (chmod(path.toUtf8().constData(), 0700) != 0) {
    if (error != nullptr) *error = QStringLiteral("could not restrict directory: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
    return false;
  }
  struct stat info {};
  if (stat(path.toUtf8().constData(), &info) != 0 || !S_ISDIR(info.st_mode) || info.st_uid != geteuid()) {
    if (error != nullptr) *error = QStringLiteral("private directory has unsafe type or owner");
    return false;
  }
  return true;
}

bool writeDurableFile(const QString &path, const QByteArray &data, mode_t mode, QString *error) {
  const QString directory = QFileInfo(path).absolutePath();
  if (!ensurePrivateDirectory(directory, error)) return false;
  if (!rejectSymlink(path, error)) return false;
  const QString temporary = path + QStringLiteral(".tmp.") + QString::number(static_cast<qint64>(QCoreApplication::applicationPid()));
  if (!rejectSymlink(temporary, error)) return false;
  const int fd = ::open(temporary.toUtf8().constData(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode);
  if (fd < 0) {
    if (error != nullptr) *error = QStringLiteral("could not create temporary file: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
    return false;
  }
  bool ok = writeAll(fd, data, error);
  if (ok && fchmod(fd, mode) != 0) {
    ok = false;
    if (error != nullptr) *error = QStringLiteral("file chmod failed: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
  }
  if (ok && fsync(fd) != 0) {
    ok = false;
    if (error != nullptr) *error = QStringLiteral("file fsync failed: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
  }
  (void)close(fd);
  if (!ok) {
    (void)unlink(temporary.toUtf8().constData());
    return false;
  }
  if (rename(temporary.toUtf8().constData(), path.toUtf8().constData()) != 0) {
    if (error != nullptr) *error = QStringLiteral("atomic rename failed: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
    (void)unlink(temporary.toUtf8().constData());
    return false;
  }
  const int directoryFd = ::open(directory.toUtf8().constData(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (directoryFd < 0 || fsync(directoryFd) != 0) {
    if (error != nullptr) *error = QStringLiteral("directory fsync failed: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
    if (directoryFd >= 0) (void)close(directoryFd);
    return false;
  }
  (void)close(directoryFd);
  return true;
}

bool readRegularPrivateFile(const QString &path, QByteArray *data, QString *error) {
  struct stat info {};
  if (lstat(path.toUtf8().constData(), &info) != 0) {
    if (errno == ENOENT) {
      if (error != nullptr) *error = QStringLiteral("not found");
      return false;
    }
    if (error != nullptr) *error = QStringLiteral("could not inspect file: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
    return false;
  }
  if (!S_ISREG(info.st_mode) || (info.st_mode & 0077) != 0 || info.st_uid != geteuid()) {
    if (error != nullptr) *error = QStringLiteral("private file has unsafe type or permissions");
    return false;
  }
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly)) {
    if (error != nullptr) *error = file.errorString();
    return false;
  }
  *data = file.readAll();
  if (file.error() != QFileDevice::NoError) {
    if (error != nullptr) *error = file.errorString();
    return false;
  }
  return true;
}

QJsonObject settingsToJson(const Settings &settings) {
  QJsonObject object;
  object.insert(QStringLiteral("schemaVersion"), Settings::schemaVersion);
  object.insert(QStringLiteral("warmth"), settings.warmth);
  object.insert(QStringLiteral("brightness"), settings.brightness);
  object.insert(QStringLiteral("filterEnabled"), settings.filterEnabled);
  object.insert(QStringLiteral("backlightLockEnabled"), settings.backlightLockEnabled);
  object.insert(QStringLiteral("launchAtLogin"), settings.launchAtLogin);
  object.insert(QStringLiteral("sunScheduleEnabled"), settings.sunScheduleEnabled);
  object.insert(QStringLiteral("automationPaused"), settings.automationPaused);
  object.insert(QStringLiteral("primaryAction"), primaryActionName(settings.primaryAction));
  if (settings.location.has_value()) {
    QJsonObject location;
    location.insert(QStringLiteral("latitude"), settings.location->latitude);
    location.insert(QStringLiteral("longitude"), settings.location->longitude);
    object.insert(QStringLiteral("location"), location);
  }
  if (settings.overrideExpiresAtMs.has_value()) {
    object.insert(QStringLiteral("overrideExpiresAtMs"), static_cast<qint64>(*settings.overrideExpiresAtMs));
    object.insert(QStringLiteral("overrideFilterEnabled"), settings.overrideFilterEnabled);
  }
  return object;
}

bool settingsFromJson(const QJsonObject &object, Settings *settings, int *schema, QString *error) {
  *schema = object.value(QStringLiteral("schemaVersion")).toInt(0);
  if (*schema > maxSupportedSettingsSchema) {
    if (error != nullptr) *error = QStringLiteral("unsupported schema %1").arg(*schema);
    return false;
  }
  Settings value = Settings::defaults();
  double number = 0.0;
  bool boolean = false;
  if (object.contains(QStringLiteral("warmth"))) {
    if (!jsonNumber(object, "warmth", &number, error)) return false;
    value.warmth = number;
  }
  if (object.contains(QStringLiteral("brightness"))) {
    if (!jsonNumber(object, "brightness", &number, error)) return false;
    value.brightness = number;
  }
  const struct BoolField { const char *key; bool Settings::*member; } fields[] = {
      {"filterEnabled", &Settings::filterEnabled},
      {"backlightLockEnabled", &Settings::backlightLockEnabled},
      {"launchAtLogin", &Settings::launchAtLogin},
      {"sunScheduleEnabled", &Settings::sunScheduleEnabled},
      {"automationPaused", &Settings::automationPaused},
      {"overrideFilterEnabled", &Settings::overrideFilterEnabled},
  };
  for (const auto &field : fields) {
    if (!object.contains(QLatin1String(field.key))) continue;
    if (!jsonBool(object, field.key, &boolean, error)) return false;
    value.*(field.member) = boolean;
  }
  if (object.contains(QStringLiteral("primaryAction"))) {
    const auto action = primaryActionFromName(object.value(QStringLiteral("primaryAction")).toString());
    if (!action.has_value()) {
      if (error != nullptr) *error = QStringLiteral("primaryAction is invalid");
      return false;
    }
    value.primaryAction = *action;
  }
  if (object.contains(QStringLiteral("location"))) {
    const QJsonObject location = object.value(QStringLiteral("location")).toObject();
    double latitude = 0.0;
    double longitude = 0.0;
    if (!jsonNumber(location, "latitude", &latitude, error) || !jsonNumber(location, "longitude", &longitude, error)) return false;
    value.location = Coordinate{latitude, longitude};
  }
  if (object.contains(QStringLiteral("overrideExpiresAtMs"))) {
    const QJsonValue expiry = object.value(QStringLiteral("overrideExpiresAtMs"));
    if (!expiry.isDouble()) {
      if (error != nullptr) *error = QStringLiteral("overrideExpiresAtMs must be an integer");
      return false;
    }
    value.overrideExpiresAtMs = static_cast<std::int64_t>(expiry.toDouble());
  }
  value.normalize();
  QString validation;
  if (!value.validate(&validation)) {
    if (error != nullptr) *error = validation;
    return false;
  }
  *settings = value;
  return true;
}

QJsonObject recoveryToJson(const RecoveryRecord &record) {
  QJsonObject object;
  object.insert(QStringLiteral("schemaVersion"), record.schema);
  object.insert(QStringLiteral("appVersion"), record.appVersion);
  object.insert(QStringLiteral("createdAtMs"), static_cast<qint64>(record.createdAtMs));
  object.insert(QStringLiteral("safetyPaused"), record.safetyPaused);
  if (record.hardware.has_value()) {
    const HardwareRecord &hardware = *record.hardware;
    QJsonObject value;
    value.insert(QStringLiteral("deviceId"), hardware.deviceId);
    value.insert(QStringLiteral("devicePath"), hardware.devicePath);
    value.insert(QStringLiteral("bootIdHash"), hardware.bootIdHash);
    value.insert(QStringLiteral("originalBrightness"), hardware.originalBrightness);
    value.insert(QStringLiteral("lastWrittenBrightness"), hardware.lastWrittenBrightness);
    value.insert(QStringLiteral("maximumBrightness"), hardware.maximumBrightness);
    value.insert(QStringLiteral("unresolved"), hardware.unresolved);
    value.insert(QStringLiteral("error"), hardware.error);
    object.insert(QStringLiteral("hardware"), value);
  }
  return object;
}

bool recoveryFromJson(const QJsonObject &object, RecoveryRecord *record, int *schema, QString *error) {
  *schema = object.value(QStringLiteral("schemaVersion")).toInt(0);
  if (*schema > maxSupportedRecoverySchema) {
    if (error != nullptr) *error = QStringLiteral("unsupported schema %1").arg(*schema);
    return false;
  }
  RecoveryRecord value;
  value.schema = *schema == 0 ? RecoveryRecord::schemaVersion : *schema;
  value.appVersion = object.value(QStringLiteral("appVersion")).toString();
  value.createdAtMs = static_cast<std::int64_t>(object.value(QStringLiteral("createdAtMs")).toDouble());
  value.safetyPaused = object.value(QStringLiteral("safetyPaused")).toBool(false);
  if (object.contains(QStringLiteral("hardware"))) {
    const QJsonObject json = object.value(QStringLiteral("hardware")).toObject();
    HardwareRecord hardware;
    hardware.deviceId = json.value(QStringLiteral("deviceId")).toString();
    hardware.devicePath = json.value(QStringLiteral("devicePath")).toString();
    hardware.bootIdHash = json.value(QStringLiteral("bootIdHash")).toString();
    hardware.originalBrightness = json.value(QStringLiteral("originalBrightness")).toInt(-1);
    hardware.lastWrittenBrightness = json.value(QStringLiteral("lastWrittenBrightness")).toInt(-1);
    hardware.maximumBrightness = json.value(QStringLiteral("maximumBrightness")).toInt(0);
    hardware.unresolved = json.value(QStringLiteral("unresolved")).toBool(false);
    hardware.error = json.value(QStringLiteral("error")).toString();
    if (hardware.deviceId.isEmpty() || hardware.devicePath.isEmpty() || hardware.originalBrightness < 0 || hardware.maximumBrightness <= 0) {
      if (error != nullptr) *error = QStringLiteral("hardware recovery record is incomplete");
      return false;
    }
    value.hardware = hardware;
  }
  *record = value;
  return true;
}

QString hashBootId() {
  QFile file(QStringLiteral("/proc/sys/kernel/random/boot_id"));
  if (!file.open(QIODevice::ReadOnly)) return {};
  const QByteArray value = file.readAll().trimmed();
  if (value.isEmpty()) return {};
  const QByteArray digest = QCryptographicHash::hash(value, QCryptographicHash::Sha256).toHex();
  return QString::fromLatin1(digest.left(16));
}

} // namespace ember
