#include "core/Diagnostics.h"

namespace ember {

QVariantMap sanitizedDiagnostics(const QVariantMap &status) {
  QVariantMap result = status;
  result.remove(QStringLiteral("location"));
  result.remove(QStringLiteral("coordinates"));
  result.remove(QStringLiteral("home"));
  result.remove(QStringLiteral("environment"));
  result.remove(QStringLiteral("rawSerials"));
  result.insert(QStringLiteral("pixelsVerified"), false);
  result.insert(QStringLiteral("opticalReadback"), QStringLiteral("unavailable on Wayland CTM backend"));
  return result;
}

} // namespace ember
