#pragma once

#include "core/Model.h"

#include <QJsonObject>
#include <QString>

#include <sys/types.h>

namespace ember {

struct Paths {
  QString configDir;
  QString stateDir;
  QString runtimeDir;
  QString settingsFile;
  QString recoveryFile;
  QString safetyLatchFile;
  QString guardianFile;

  static Paths fromEnvironment();
};

enum class LoadKind { NoFile, Loaded, Corrupt, FutureSchema, IoFailure };

struct SettingsLoadResult {
  LoadKind kind = LoadKind::NoFile;
  Settings settings = Settings::defaults();
  QString detail;
  int schema = 0;
};

struct RecoveryLoadResult {
  LoadKind kind = LoadKind::NoFile;
  RecoveryRecord record;
  QString detail;
  int schema = 0;
};

class SettingsStore {
public:
  explicit SettingsStore(Paths paths);

  SettingsLoadResult load() const;
  bool save(const Settings &settings, QString *error = nullptr) const;

private:
  Paths paths_;
};

class RecoveryJournal {
public:
  explicit RecoveryJournal(Paths paths);

  RecoveryLoadResult load() const;
  bool save(const RecoveryRecord &record, QString *error = nullptr) const;
  bool clear(QString *error = nullptr) const;
  bool quarantine(QString *quarantinedPath = nullptr, QString *error = nullptr) const;
  bool exists() const;

private:
  Paths paths_;
};

bool ensurePrivateDirectory(const QString &path, QString *error = nullptr);
bool writeDurableFile(const QString &path, const QByteArray &data, mode_t mode, QString *error = nullptr);
bool readRegularPrivateFile(const QString &path, QByteArray *data, QString *error = nullptr);

QJsonObject settingsToJson(const Settings &settings);
bool settingsFromJson(const QJsonObject &object, Settings *settings, int *schema, QString *error);
QJsonObject recoveryToJson(const RecoveryRecord &record);
bool recoveryFromJson(const QJsonObject &object, RecoveryRecord *record, int *schema, QString *error);

QString hashBootId();

} // namespace ember
