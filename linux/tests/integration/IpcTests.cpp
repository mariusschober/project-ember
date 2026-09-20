#include "AppController.h"
#include "Ipc.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
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
  QVERIFY(QDir().mkpath(QString::fromUtf8(qgetenv("XDG_RUNTIME_DIR"))));
  QFile::setPermissions(QString::fromUtf8(qgetenv("XDG_RUNTIME_DIR")),
                        QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);

  AppController controller(false);
  QString error;
  if (!controller.start(&error)) {
    const QByteArray message = QStringLiteral("private session D-Bus unavailable: %1").arg(error).toLocal8Bit();
    QSKIP(message.constData());
  }

  QVERIFY(ipcServiceAvailable());
  QVariant reply;
  QVERIFY(ipcCall(QStringLiteral("GetStatus"), {}, &reply, &error));
  const QVariantMap initial = reply.toMap();
  QCOMPARE(initial.value(QStringLiteral("filterEnabled")).toBool(), false);
  QCOMPARE(initial.value(QStringLiteral("pixelsVerified")).toBool(), false);
  QVERIFY(!initial.value(QStringLiteral("requestProcessed")).toBool());

  QVERIFY(ipcCall(QStringLiteral("SetWarmth"), {QVariant(0.2)}, nullptr, &error));
  QVERIFY(ipcCall(QStringLiteral("SetBrightness"), {QVariant(0.5)}, nullptr, &error));
  QVERIFY(ipcCall(QStringLiteral("SetPreset"), {QVariant(QStringLiteral("pure-red"))}, nullptr, &error));
  QVERIFY(ipcCall(QStringLiteral("Restore"), {}, nullptr, &error));
  QCoreApplication::processEvents();
  QVERIFY(ipcCall(QStringLiteral("GetStatus"), {}, &reply, &error));
  const QVariantMap final = reply.toMap();
  QCOMPARE(final.value(QStringLiteral("filterEnabled")).toBool(), false);
  QCOMPARE(final.value(QStringLiteral("automationPaused")).toBool(), true);
  QCOMPARE(final.value(QStringLiteral("pixelsVerified")).toBool(), false);
  unregisterIpc();
}

QTEST_APPLESS_MAIN(IpcTests)

#include "IpcTests.moc"
