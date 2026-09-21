#include "AppController.h"
#include "Ipc.h"

#include <QApplication>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QScopeGuard>
#include <QTemporaryDir>
#include <QtTest>

using namespace ember;

class IpcTests final : public QObject {
  Q_OBJECT

private slots:
  void routesTypedCommandsThroughOneResident();
};

void IpcTests::routesTypedCommandsThroughOneResident() {
  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  qputenv("QT_QPA_PLATFORM", "offscreen");
  qputenv("XDG_CONFIG_HOME", QDir(temporary.path()).filePath(QStringLiteral("config")).toUtf8());
  qputenv("XDG_STATE_HOME", QDir(temporary.path()).filePath(QStringLiteral("state")).toUtf8());
  qputenv("XDG_RUNTIME_DIR", QDir(temporary.path()).filePath(QStringLiteral("runtime")).toUtf8());
  qputenv("EMBER_BACKLIGHT_ROOT", QDir(temporary.path()).filePath(QStringLiteral("backlight")).toUtf8());
  qputenv("EMBER_DRM_ROOT", QDir(temporary.path()).filePath(QStringLiteral("drm")).toUtf8());
  qputenv("EMBER_TEST_ALLOW_ROOT", "1");
  QVERIFY(QDir().mkpath(QString::fromUtf8(qgetenv("XDG_RUNTIME_DIR"))));
  QFile::setPermissions(QString::fromUtf8(qgetenv("XDG_RUNTIME_DIR")),
                        QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
  const QString systemctl = temporary.filePath(QStringLiteral("fake-systemctl"));
  const QString systemctlState = temporary.filePath(QStringLiteral("systemctl-enabled"));
  QFile systemctlFile(systemctl);
  QVERIFY(systemctlFile.open(QIODevice::WriteOnly | QIODevice::Truncate));
  systemctlFile.write(
      "#!/bin/sh\n"
      "case \"$2\" in\n"
      "  is-enabled) test -f \"$EMBER_SYSTEMCTL_STATE\" ;;\n"
      "  enable) : > \"$EMBER_SYSTEMCTL_STATE\" ;;\n"
      "  disable) rm -f \"$EMBER_SYSTEMCTL_STATE\" ;;\n"
      "  *) exit 2 ;;\n"
      "esac\n");
  systemctlFile.close();
  QVERIFY(QFile::setPermissions(systemctl, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner));
  qputenv("EMBER_SYSTEMCTL", systemctl.toUtf8());
  qputenv("EMBER_SYSTEMCTL_STATE", systemctlState.toUtf8());

  AppController controller(false);
  QString error;
  if (!controller.start(&error)) {
    const QByteArray message = QStringLiteral("private session D-Bus unavailable: %1").arg(error).toLocal8Bit();
    QSKIP(message.constData());
  }
  const auto unregister = qScopeGuard([] { unregisterIpc(); });

  QVERIFY(ipcServiceAvailable());
  AppController duplicate(false);
  QString duplicateError;
  QVERIFY(!duplicate.start(&duplicateError));
  QVERIFY(!duplicateError.isEmpty());
  QVariant reply;
  QVERIFY(ipcCall(QStringLiteral("GetStatus"), {}, &reply, &error));
  const QVariantMap initial = reply.toMap();
  QCOMPARE(initial.value(QStringLiteral("filterEnabled")).toBool(), false);
  QCOMPARE(initial.value(QStringLiteral("pixelsVerified")).toBool(), false);
  QVERIFY(!initial.value(QStringLiteral("requestProcessed")).toBool());
  QCOMPARE(initial.value(QStringLiteral("statusTitle")).toString(), QStringLiteral("Ember is off"));
  QVERIFY(!initial.value(QStringLiteral("loginRegistered")).toBool());

  controller.setLaunchAtLogin(true);
  QVERIFY(controller.status().value(QStringLiteral("loginRegistered")).toBool());
  QVERIFY(QFileInfo::exists(systemctlState));
  controller.setLaunchAtLogin(true);
  QVERIFY(controller.status().value(QStringLiteral("loginRegistered")).toBool());
  controller.setLaunchAtLogin(false);
  QVERIFY(!controller.status().value(QStringLiteral("loginRegistered")).toBool());
  QVERIFY(!QFileInfo::exists(systemctlState));

  QVERIFY(!ipcCall(QStringLiteral("SetWarmth"), {QVariant(1.1)}, nullptr, &error));
  QVERIFY(!ipcCall(QStringLiteral("SetBrightness"), {QVariant(0.09)}, nullptr, &error));
  QVERIFY(!ipcCall(QStringLiteral("SetPreset"), {QVariant(QString(10000, QLatin1Char('x')))}, nullptr, &error));
  QVERIFY(!ipcCall(QStringLiteral("SetWarmth"), {QVariant(QStringLiteral("not-a-number"))}, nullptr, &error));
  QVERIFY(!ipcCall(QStringLiteral("NoSuchMethod"), {}, nullptr, &error));

  QVariant requestReply;
  QVERIFY(ipcCall(QStringLiteral("SetWarmth"), {QVariant(0.2)}, &requestReply, &error));
  const qulonglong firstRequest = requestReply.toULongLong();
  QVERIFY(firstRequest > 0);
  QVERIFY(ipcCall(QStringLiteral("SetBrightness"), {QVariant(0.5)}, &requestReply, &error));
  QVERIFY(requestReply.toULongLong() > firstRequest);
  QVERIFY(ipcCall(QStringLiteral("SetPreset"), {QVariant(QStringLiteral("pure-red"))}, &requestReply, &error));
  const qulonglong presetRequest = requestReply.toULongLong();
  QVERIFY(presetRequest > firstRequest);
  QVERIFY(ipcCall(QStringLiteral("SetFilterEnabled"), {QVariant(true)}, &requestReply, &error));
  const qulonglong enableRequest = requestReply.toULongLong();
  QVERIFY(enableRequest > presetRequest);
  QTRY_VERIFY_WITH_TIMEOUT([&] {
    if (!ipcCall(QStringLiteral("GetStatus"), {}, &reply, &error)) return false;
    return reply.toMap().value(QStringLiteral("runtimeState")).toString() == QStringLiteral("unsupported");
  }(), 2000);
  const QVariantMap unsupported = reply.toMap();
  QVERIFY(!unsupported.value(QStringLiteral("effectiveFilterEnabled")).toBool());
  QCOMPARE(unsupported.value(QStringLiteral("protocolOwnership")).toString(), QStringLiteral("none"));
  QVERIFY(!unsupported.value(QStringLiteral("pixelsVerified")).toBool());
  QVERIFY(unsupported.value(QStringLiteral("statusTitle")).toString() != QStringLiteral("Ember is on"));
  QCOMPARE(unsupported.value(QStringLiteral("lastAcceptedRequestId")).toULongLong(), enableRequest);
  QVERIFY(ipcCall(QStringLiteral("Restore"), {}, nullptr, &error));
  QVariantMap final;
  QTRY_VERIFY_WITH_TIMEOUT([&] {
    if (!ipcCall(QStringLiteral("GetStatus"), {}, &reply, &error)) return false;
    final = reply.toMap();
    return final.value(QStringLiteral("automationPaused")).toBool();
  }(), 1000);
  QCOMPARE(final.value(QStringLiteral("filterEnabled")).toBool(), false);
  QCOMPARE(final.value(QStringLiteral("automationPaused")).toBool(), true);
  QCOMPARE(final.value(QStringLiteral("pixelsVerified")).toBool(), false);
  QVERIFY(ipcCall(QStringLiteral("ResumeAutomation"), {}, nullptr, &error));
  QTRY_VERIFY_WITH_TIMEOUT([&] {
    if (!ipcCall(QStringLiteral("GetStatus"), {}, &reply, &error)) return false;
    return !reply.toMap().value(QStringLiteral("automationPaused")).toBool();
  }(), 1000);
  unregisterIpc();
  QVERIFY(!ipcServiceAvailable());
  QVERIFY(!ipcCall(QStringLiteral("GetStatus"), {}, &reply, &error));
}

int main(int argc, char **argv) {
  qputenv("QT_QPA_PLATFORM", "offscreen");
  QApplication application(argc, argv);
  IpcTests tests;
  return QTest::qExec(&tests, argc, argv);
}

#include "IpcTests.moc"
