#include "AppController.h"

#include <QDir>
#include <QRandomGenerator>
#include <QTemporaryDir>
#include <QtTest>

using namespace ember;

class CoordinatorTests final : public QObject {
  Q_OBJECT

private slots:
  void staleCallbacksCannotOverrideLatestIntent();
  void deterministicRandomizedSequencesPreserveInvariants();
};

void CoordinatorTests::staleCallbacksCannotOverrideLatestIntent() {
  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  qputenv("XDG_CONFIG_HOME", temporary.filePath(QStringLiteral("config")).toUtf8());
  qputenv("XDG_STATE_HOME", temporary.filePath(QStringLiteral("state")).toUtf8());
  qputenv("XDG_RUNTIME_DIR", temporary.filePath(QStringLiteral("runtime")).toUtf8());
  AppController controller(false);

  controller.setFilterEnabled(true);
  const qulonglong first = controller.status().value(QStringLiteral("requestedGeneration")).toULongLong();
  controller.setWarmth(0.4);
  const qulonglong second = controller.status().value(QStringLiteral("requestedGeneration")).toULongLong();
  QVERIFY(second > first);
  controller.setFilterEnabled(false);
  const qulonglong off = controller.status().value(QStringLiteral("requestedGeneration")).toULongLong();
  QVERIFY(off > second);
  QVERIFY(QMetaObject::invokeMethod(&controller, "onApplied", Qt::DirectConnection, Q_ARG(qulonglong, first)));
  QVERIFY(QMetaObject::invokeMethod(&controller, "onApplied", Qt::DirectConnection, Q_ARG(qulonglong, second)));
  QVariantMap status = controller.status();
  QVERIFY(!status.value(QStringLiteral("desiredFilterEnabled")).toBool());
  QVERIFY(!status.value(QStringLiteral("effectiveFilterEnabled")).toBool());

  controller.setFilterEnabled(true);
  const qulonglong latest = controller.status().value(QStringLiteral("requestedGeneration")).toULongLong();
  QVERIFY(latest > off);
  QVERIFY(QMetaObject::invokeMethod(&controller, "onReleased", Qt::DirectConnection, Q_ARG(qulonglong, off)));
  QVERIFY(QMetaObject::invokeMethod(&controller, "onBackendFailed", Qt::DirectConnection,
                                    Q_ARG(qulonglong, second), Q_ARG(QString, QStringLiteral("stale failure"))));
  status = controller.status();
  QCOMPARE(status.value(QStringLiteral("runtimeState")).toString(), QStringLiteral("enabling"));
  QVERIFY(!status.value(QStringLiteral("attentionMessage")).toString().contains(QStringLiteral("stale failure")));
  QVERIFY(QMetaObject::invokeMethod(&controller, "onApplied", Qt::DirectConnection, Q_ARG(qulonglong, latest)));
  status = controller.status();
  QVERIFY(status.value(QStringLiteral("effectiveFilterEnabled")).toBool());
  QVERIFY(status.value(QStringLiteral("requestProcessed")).toBool());
  QCOMPARE(status.value(QStringLiteral("protocolOwnership")).toString(), QStringLiteral("owned"));
  QVERIFY(!status.value(QStringLiteral("pixelsVerified")).toBool());

  controller.setWarmth(0.3);
  status = controller.status();
  QCOMPARE(status.value(QStringLiteral("runtimeState")).toString(), QStringLiteral("reconciling"));
  QCOMPARE(status.value(QStringLiteral("protocolOwnership")).toString(), QStringLiteral("owned"));
  QVERIFY(status.value(QStringLiteral("effectiveFilterEnabled")).toBool());
  QVERIFY(!status.value(QStringLiteral("requestProcessed")).toBool());
}

void CoordinatorTests::deterministicRandomizedSequencesPreserveInvariants() {
  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  qputenv("XDG_CONFIG_HOME", temporary.filePath(QStringLiteral("config")).toUtf8());
  qputenv("XDG_STATE_HOME", temporary.filePath(QStringLiteral("state")).toUtf8());
  qputenv("XDG_RUNTIME_DIR", temporary.filePath(QStringLiteral("runtime")).toUtf8());
  AppController controller(false);
  QRandomGenerator random(0xE6B3A219U);
  qulonglong previousGeneration = 0;

  for (int index = 0; index < 1000; ++index) {
    const int action = static_cast<int>(random.bounded(9U));
    const QVariantMap before = controller.status();
    const qulonglong current = before.value(QStringLiteral("requestedGeneration")).toULongLong();
    const qulonglong stale = current == 0 ? 999999ULL : current - 1;
    switch (action) {
    case 0: controller.setFilterEnabled(true); break;
    case 1: controller.setFilterEnabled(false); break;
    case 2: controller.setWarmth(static_cast<double>(random.bounded(101U)) / 100.0); break;
    case 3: controller.setBrightness(0.10 + (static_cast<double>(random.bounded(91U)) / 100.0)); break;
    case 4:
      QVERIFY(QMetaObject::invokeMethod(&controller, "onApplied", Qt::DirectConnection, Q_ARG(qulonglong, stale)));
      QCOMPARE(controller.status().value(QStringLiteral("requestedGeneration")), before.value(QStringLiteral("requestedGeneration")));
      QCOMPARE(controller.status().value(QStringLiteral("desiredFilterEnabled")), before.value(QStringLiteral("desiredFilterEnabled")));
      break;
    case 5:
      QVERIFY(QMetaObject::invokeMethod(&controller, "onBackendFailed", Qt::DirectConnection,
                                        Q_ARG(qulonglong, stale), Q_ARG(QString, QStringLiteral("stale randomized failure"))));
      QCOMPARE(controller.status().value(QStringLiteral("requestedGeneration")), before.value(QStringLiteral("requestedGeneration")));
      break;
    case 6:
      QVERIFY(QMetaObject::invokeMethod(&controller, "onReleased", Qt::DirectConnection, Q_ARG(qulonglong, stale)));
      QCOMPARE(controller.status().value(QStringLiteral("desiredFilterEnabled")), before.value(QStringLiteral("desiredFilterEnabled")));
      break;
    case 7:
      if (before.value(QStringLiteral("desiredFilterEnabled")).toBool()) {
        QVERIFY(QMetaObject::invokeMethod(&controller, "onApplied", Qt::DirectConnection, Q_ARG(qulonglong, current)));
      }
      break;
    case 8: controller.restore(); break;
    default: QFAIL("unreachable randomized action");
    }

    const QVariantMap status = controller.status();
    const qulonglong generation = status.value(QStringLiteral("requestedGeneration")).toULongLong();
    QVERIFY(generation >= previousGeneration);
    previousGeneration = generation;
    const bool desired = status.value(QStringLiteral("desiredFilterEnabled")).toBool();
    const bool effective = status.value(QStringLiteral("effectiveFilterEnabled")).toBool();
    const bool processed = status.value(QStringLiteral("requestProcessed")).toBool();
    if (effective) {
      QVERIFY(desired);
      QVERIFY(processed);
      QCOMPARE(status.value(QStringLiteral("runtimeState")).toString(), QStringLiteral("compositor_controlled"));
    }
    if (!desired) {
      QVERIFY(!effective);
      QVERIFY(!processed);
    }
    QVERIFY(!status.value(QStringLiteral("pixelsVerified")).toBool());
  }
}

QTEST_GUILESS_MAIN(CoordinatorTests)

#include "CoordinatorTests.moc"
