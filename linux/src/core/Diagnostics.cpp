#include "core/Diagnostics.h"

#include <QDir>

namespace {

QVariant sanitize(const QVariant &value) {
  if (value.metaType().id() == QMetaType::QString) {
    QString text = value.toString();
    const QString home = QDir::homePath();
    if (!home.isEmpty() && home != QStringLiteral("/")) text.replace(home, QStringLiteral("$HOME"));
    return text;
  }
  if (value.metaType().id() == QMetaType::QVariantMap) {
    QVariantMap result;
    const QVariantMap source = value.toMap();
    for (auto iterator = source.cbegin(); iterator != source.cend(); ++iterator) {
      const QString key = iterator.key().toLower();
      if (key == QStringLiteral("location") || key == QStringLiteral("coordinates")
          || key == QStringLiteral("home") || key == QStringLiteral("environment")
          || key == QStringLiteral("rawserials")) continue;
      result.insert(iterator.key(), sanitize(iterator.value()));
    }
    return result;
  }
  if (value.metaType().id() == QMetaType::QVariantList) {
    QVariantList result;
    for (const QVariant &item : value.toList()) result.append(sanitize(item));
    return result;
  }
  return value;
}

} // namespace

namespace ember {

QVariantMap sanitizedDiagnostics(const QVariantMap &status) {
  QVariantMap result = sanitize(status).toMap();
  result.insert(QStringLiteral("pixelsVerified"), false);
  result.insert(QStringLiteral("opticalReadback"), QStringLiteral("unavailable on Wayland CTM backend"));
  return result;
}

} // namespace ember
