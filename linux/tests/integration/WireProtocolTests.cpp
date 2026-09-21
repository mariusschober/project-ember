#include "platform/WaylandBackend.h"

#include "hyprland-ctm-control-v1-server-protocol.h"

#include <QSignalSpy>
#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QScopeGuard>
#include <QTemporaryDir>
#include <QtTest>

#include <atomic>
#include <cerrno>
#include <cstring>
#include <thread>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

#include <wayland-server-core.h>
#include <wayland-server-protocol.h>

using namespace ember;

namespace {

struct FakeOutput {
  int commits = 0;
  std::array<wl_fixed_t, 9> matrix{};
};

struct FakeServer {
  wl_display *display = nullptr;
  std::thread thread;
  QString socketName;
  FakeOutput output;
  std::atomic<int> managerBinds{0};
  std::atomic<int> managerDestroys{0};
  std::atomic<int> setRequests{0};
  std::atomic<int> commits{0};
  std::atomic<bool> managerOwner{false};
  bool advertiseManager = true;
  uint32_t managerVersion = 2;
  int outputGlobalCount = 1;
};

struct FakeManagerResource {
  FakeServer *server = nullptr;
  bool ownsManager = false;
};

void destroyManagerResource(wl_resource *resource) {
  auto *state = static_cast<FakeManagerResource *>(wl_resource_get_user_data(resource));
  if (state != nullptr) {
    if (state->ownsManager) state->server->managerOwner.store(false);
    state->server->managerDestroys.fetch_add(1);
    delete state;
  }
}

void setCtm(wl_client *client, wl_resource *resource, wl_resource *outputResource,
           wl_fixed_t mat0, wl_fixed_t mat1, wl_fixed_t mat2, wl_fixed_t mat3,
           wl_fixed_t mat4, wl_fixed_t mat5, wl_fixed_t mat6, wl_fixed_t mat7,
           wl_fixed_t mat8) {
  Q_UNUSED(client);
  auto *state = static_cast<FakeManagerResource *>(wl_resource_get_user_data(resource));
  auto *server = state == nullptr ? nullptr : state->server;
  auto *output = static_cast<FakeOutput *>(wl_resource_get_user_data(outputResource));
  if (server == nullptr || output == nullptr || !state->ownsManager) return;
  output->matrix = {mat0, mat1, mat2, mat3, mat4, mat5, mat6, mat7, mat8};
  server->setRequests.fetch_add(1);
}

void commit(wl_client *client, wl_resource *resource) {
  Q_UNUSED(client);
  auto *state = static_cast<FakeManagerResource *>(wl_resource_get_user_data(resource));
  auto *server = state == nullptr ? nullptr : state->server;
  if (server == nullptr || !state->ownsManager) return;
  server->output.commits += 1;
  server->commits.fetch_add(1);
}

void destroyManager(wl_client *client, wl_resource *resource) {
  Q_UNUSED(client);
  wl_resource_destroy(resource);
}

const struct hyprland_ctm_control_manager_v1_interface managerImplementation = {
    &setCtm,
    &commit,
    &destroyManager,
};

void destroyOutput(wl_resource *resource) { Q_UNUSED(resource); }

void releaseOutput(wl_client *client, wl_resource *resource) {
  Q_UNUSED(client);
  wl_resource_destroy(resource);
}

const struct wl_output_interface outputImplementation = {&releaseOutput};

void bindOutput(wl_client *client, void *data, uint32_t version, uint32_t id) {
  auto *server = static_cast<FakeServer *>(data);
  wl_resource *resource = wl_resource_create(client, &wl_output_interface, static_cast<int>(std::min(version, 4U)), id);
  wl_resource_set_implementation(resource, &outputImplementation, &server->output, &destroyOutput);
  wl_output_send_geometry(resource, 0, 0, 309, 174, WL_OUTPUT_SUBPIXEL_UNKNOWN,
                          "EmberTest", "Virtual eDP output", WL_OUTPUT_TRANSFORM_NORMAL);
  wl_output_send_mode(resource, WL_OUTPUT_MODE_CURRENT, 1920, 1080, 60000);
  if (version >= WL_OUTPUT_SCALE_SINCE_VERSION) wl_output_send_scale(resource, 1);
  if (version >= WL_OUTPUT_NAME_SINCE_VERSION) {
    wl_output_send_name(resource, "eDP-1");
    wl_output_send_description(resource, "Ember fake built-in");
  }
  if (version >= WL_OUTPUT_DONE_SINCE_VERSION) wl_output_send_done(resource);
  Q_UNUSED(server);
}

void bindManager(wl_client *client, void *data, uint32_t version, uint32_t id) {
  auto *server = static_cast<FakeServer *>(data);
  wl_resource *resource = wl_resource_create(client, &hyprland_ctm_control_manager_v1_interface,
                                             static_cast<int>(std::min(version, server->managerVersion)), id);
  const bool ownsManager = !server->managerOwner.exchange(true);
  auto *state = new FakeManagerResource{server, ownsManager};
  wl_resource_set_implementation(resource, &managerImplementation, state, &destroyManagerResource);
  server->managerBinds.fetch_add(1);
  if (!ownsManager && server->managerVersion >= 2) {
    // The real v2 protocol reports the conflict before client CTM requests are
    // accepted. The generated client listener is exercised by this event.
    hyprland_ctm_control_manager_v1_send_blocked(resource);
  }
}

bool startServer(FakeServer *server, const QTemporaryDir &runtime, QString *error) {
  const QString runtimePath = QDir(runtime.path()).filePath(QStringLiteral("runtime"));
  if (!QDir().mkpath(runtimePath)) {
    if (error != nullptr) *error = QStringLiteral("could not create XDG_RUNTIME_DIR");
    return false;
  }
  QFile::setPermissions(runtimePath, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
  qputenv("XDG_RUNTIME_DIR", runtimePath.toUtf8());
  server->display = wl_display_create();
  if (server->display == nullptr) {
    if (error != nullptr) *error = QStringLiteral("wl_display_create failed");
    return false;
  }
  server->socketName = QStringLiteral("project-ember-test-%1").arg(static_cast<qint64>(QCoreApplication::applicationPid()));
  const QString socketPath = QDir(runtimePath).filePath(server->socketName);
  const int socketFd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (socketFd < 0) {
    if (error != nullptr) {
      *error = QStringLiteral("AF_UNIX socket unavailable: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
    }
    wl_display_destroy(server->display);
    server->display = nullptr;
    return false;
  }
  struct sockaddr_un address {};
  address.sun_family = AF_UNIX;
  const QByteArray encodedPath = socketPath.toUtf8();
  if (encodedPath.size() >= static_cast<int>(sizeof(address.sun_path))) {
    if (error != nullptr) *error = QStringLiteral("test socket path is too long");
    ::close(socketFd);
    wl_display_destroy(server->display);
    server->display = nullptr;
    return false;
  }
  std::memcpy(address.sun_path, encodedPath.constData(), static_cast<size_t>(encodedPath.size()) + 1U);
  (void)::unlink(address.sun_path);
  if (::bind(socketFd, reinterpret_cast<const struct sockaddr *>(&address), sizeof(address)) != 0) {
    if (error != nullptr) {
      *error = QStringLiteral("bind test socket failed: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
    }
    ::close(socketFd);
    wl_display_destroy(server->display);
    server->display = nullptr;
    return false;
  }
  if (::listen(socketFd, 16) != 0) {
    if (error != nullptr) {
      *error = QStringLiteral("listen test socket failed: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
    }
    ::close(socketFd);
    (void)::unlink(address.sun_path);
    wl_display_destroy(server->display);
    server->display = nullptr;
    return false;
  }
  if (wl_display_add_socket_fd(server->display, socketFd) != 0) {
    if (error != nullptr) *error = QStringLiteral("wl_display_add_socket_fd failed");
    ::close(socketFd);
    (void)::unlink(address.sun_path);
    wl_display_destroy(server->display);
    server->display = nullptr;
    return false;
  }
  for (int index = 0; index < server->outputGlobalCount; ++index) {
    if (wl_global_create(server->display, &wl_output_interface, 4, server, &bindOutput) == nullptr) {
      if (error != nullptr) *error = QStringLiteral("could not create fake Wayland output global");
      (void)::unlink(address.sun_path);
      wl_display_destroy(server->display);
      server->display = nullptr;
      return false;
    }
  }
  if (server->advertiseManager
      && wl_global_create(server->display, &hyprland_ctm_control_manager_v1_interface,
                          static_cast<int>(server->managerVersion), server, &bindManager) == nullptr) {
    if (error != nullptr) *error = QStringLiteral("could not create fake Wayland manager global");
    (void)::unlink(address.sun_path);
    wl_display_destroy(server->display);
    server->display = nullptr;
    return false;
  }
  server->thread = std::thread([server] { wl_display_run(server->display); });
  qputenv("WAYLAND_DISPLAY", server->socketName.toUtf8());
  return true;
}

void stopServer(FakeServer *server) {
  if (server->display == nullptr) return;
  wl_display_terminate(server->display);
  if (server->thread.joinable()) server->thread.join();
  wl_display_destroy_clients(server->display);
  wl_display_destroy(server->display);
  server->display = nullptr;
}

} // namespace

class WireProtocolTests final : public QObject {
  Q_OBJECT

private slots:
  void registryProbeDoesNotBindManager();
  void missingAndOldManagerAreRejected();
  void completeMatrixCommitAndProcessedEvidence();
  void blockedManagerDoesNotReportApplied();
  void secondOwnerCannotResetFirstOwner();
  void staleGenerationIsCancelledBeforeOwnership();
  void reconnectCreatesANewConnectionEpoch();
  void stalledCompositorIsBounded();
};

void WireProtocolTests::registryProbeDoesNotBindManager() {
  QTemporaryDir runtime;
  QVERIFY(runtime.isValid());
  FakeServer server;
  const auto cleanup = qScopeGuard([&server] { stopServer(&server); });
  QString startError;
  if (!startServer(&server, runtime, &startError)) {
    const QByteArray skipMessage = startError.toLocal8Bit();
    QSKIP(skipMessage.constData());
  }
  {
    WaylandBackend backend;
    QSignalSpy capability(&backend, &WaylandBackend::capabilityChanged);
    backend.probe();
    QVERIFY(!capability.isEmpty());
    QCOMPARE(capability.last().at(0).toBool(), true);
    QCOMPARE(capability.last().at(1).toInt(), 2);
    QCOMPARE(capability.last().at(2).toInt(), 1);
    QCOMPARE(server.managerBinds.load(), 0);
    const QVariantMap snapshot = backend.readOnlyProbeSnapshot();
    QCOMPARE(snapshot.value(QStringLiteral("probeEvidence")).toString(),
             QStringLiteral("registry-only; no CTM manager bind or color request"));
    QCOMPARE(snapshot.value(QStringLiteral("managerSupported")).toBool(), true);
    QCOMPARE(snapshot.value(QStringLiteral("outputs")).toList().size(), 1);
    QCOMPARE(snapshot.value(QStringLiteral("advertisedGlobals")).toMap()
                 .value(QStringLiteral("hyprland_ctm_control_manager_v1")).toInt(), 2);
    backend.stop();
  }
}

void WireProtocolTests::missingAndOldManagerAreRejected() {
  for (const uint32_t version : {0U, 1U}) {
    QTemporaryDir runtime;
    QVERIFY(runtime.isValid());
    FakeServer server;
    server.advertiseManager = version != 0U;
    server.managerVersion = version;
    const auto cleanup = qScopeGuard([&server] { stopServer(&server); });
    QString startError;
    if (!startServer(&server, runtime, &startError)) {
      const QByteArray skipMessage = startError.toLocal8Bit();
      QSKIP(skipMessage.constData());
    }
    WaylandBackend backend;
    QSignalSpy capability(&backend, &WaylandBackend::capabilityChanged);
    QSignalSpy failed(&backend, &WaylandBackend::failed);
    backend.probe();
    QVERIFY(!capability.isEmpty());
    QCOMPARE(capability.last().at(1).toInt(), static_cast<int>(version));
    backend.apply(matrixFor(Settings::defaults()), 3);
    QVERIFY(!failed.isEmpty());
    QCOMPARE(server.managerBinds.load(), 0);
    QCOMPARE(server.setRequests.load(), 0);
    backend.stop();
  }
}

void WireProtocolTests::completeMatrixCommitAndProcessedEvidence() {
  QTemporaryDir runtime;
  QVERIFY(runtime.isValid());
  FakeServer server;
  server.outputGlobalCount = 2;
  const auto cleanup = qScopeGuard([&server] { stopServer(&server); });
  QString startError;
  if (!startServer(&server, runtime, &startError)) {
    const QByteArray skipMessage = startError.toLocal8Bit();
    QSKIP(skipMessage.constData());
  }
  {
    WaylandBackend backend;
    QSignalSpy applied(&backend, &WaylandBackend::applied);
    Settings settings;
    settings.warmth = 0.62;
    settings.brightness = 0.75;
    backend.apply(matrixFor(settings), 42);
    QVERIFY(!applied.isEmpty());
    QCOMPARE(applied.last().at(0).toULongLong(), 42ULL);
    QCOMPARE(server.managerBinds.load(), 1);
    QCOMPARE(server.setRequests.load(), 2);
    QCOMPARE(server.commits.load(), 1);
    QCOMPARE(server.output.matrix[0], static_cast<wl_fixed_t>(wl_fixed_from_double(matrixFor(settings).values[0])));
    QCOMPARE(server.output.matrix[4], static_cast<wl_fixed_t>(wl_fixed_from_double(matrixFor(settings).values[4])));
    QCOMPARE(server.output.matrix[8], static_cast<wl_fixed_t>(wl_fixed_from_double(matrixFor(settings).values[8])));
    backend.release(42);
  }
}

void WireProtocolTests::blockedManagerDoesNotReportApplied() {
  QTemporaryDir runtime;
  QVERIFY(runtime.isValid());
  FakeServer server;
  const auto cleanup = qScopeGuard([&server] { stopServer(&server); });
  QString startError;
  if (!startServer(&server, runtime, &startError)) {
    const QByteArray skipMessage = startError.toLocal8Bit();
    QSKIP(skipMessage.constData());
  }
  server.managerOwner.store(true);
  {
    WaylandBackend backend;
    QSignalSpy blocked(&backend, &WaylandBackend::blocked);
    QSignalSpy applied(&backend, &WaylandBackend::applied);
    backend.apply(matrixFor(Settings::defaults()), 7);
    QVERIFY(!blocked.isEmpty());
    QVERIFY(applied.isEmpty());
    QCOMPARE(server.setRequests.load(), 0);
    QCOMPARE(server.commits.load(), 0);
    backend.release(7);
    QVERIFY(server.managerOwner.load());
  }
}

void WireProtocolTests::secondOwnerCannotResetFirstOwner() {
  QTemporaryDir runtime;
  QVERIFY(runtime.isValid());
  FakeServer server;
  const auto cleanup = qScopeGuard([&server] { stopServer(&server); });
  QString startError;
  if (!startServer(&server, runtime, &startError)) {
    const QByteArray skipMessage = startError.toLocal8Bit();
    QSKIP(skipMessage.constData());
  }
  WaylandBackend first;
  WaylandBackend second;
  QSignalSpy firstApplied(&first, &WaylandBackend::applied);
  QSignalSpy secondBlocked(&second, &WaylandBackend::blocked);
  first.apply(matrixFor(Settings::defaults()), 1);
  QCOMPARE(firstApplied.size(), 1);
  second.apply(matrixFor(Settings::defaults()), 2);
  QCOMPARE(secondBlocked.size(), 1);
  second.release(2);
  QVERIFY(server.managerOwner.load());
  first.apply(matrixFor(Settings::defaults()), 3);
  QCOMPARE(firstApplied.size(), 2);
  first.release(3);
  QVERIFY(!server.managerOwner.load());
}

void WireProtocolTests::staleGenerationIsCancelledBeforeOwnership() {
  QTemporaryDir runtime;
  QVERIFY(runtime.isValid());
  FakeServer server;
  const auto cleanup = qScopeGuard([&server] { stopServer(&server); });
  QString startError;
  if (!startServer(&server, runtime, &startError)) {
    const QByteArray skipMessage = startError.toLocal8Bit();
    QSKIP(skipMessage.constData());
  }
  WaylandBackend backend;
  QSignalSpy applied(&backend, &WaylandBackend::applied);
  backend.invalidateBefore(9);
  backend.apply(matrixFor(Settings::defaults()), 8);
  QCOMPARE(server.managerBinds.load(), 0);
  QCOMPARE(server.setRequests.load(), 0);
  backend.apply(matrixFor(Settings::defaults()), 9);
  QCOMPARE(applied.size(), 1);
  QCOMPARE(applied.constFirst().at(0).toULongLong(), 9ULL);
  backend.release(10);
}

void WireProtocolTests::reconnectCreatesANewConnectionEpoch() {
  QTemporaryDir firstRuntime;
  QTemporaryDir secondRuntime;
  QVERIFY(firstRuntime.isValid());
  QVERIFY(secondRuntime.isValid());
  FakeServer firstServer;
  FakeServer secondServer;
  const auto cleanup = qScopeGuard([&] {
    stopServer(&firstServer);
    stopServer(&secondServer);
  });
  QString startError;
  if (!startServer(&firstServer, firstRuntime, &startError)) {
    const QByteArray skipMessage = startError.toLocal8Bit();
    QSKIP(skipMessage.constData());
  }
  WaylandBackend backend;
  QSignalSpy applied(&backend, &WaylandBackend::applied);
  QSignalSpy failed(&backend, &WaylandBackend::failed);
  backend.apply(matrixFor(Settings::defaults()), 1);
  QCOMPARE(applied.size(), 1);
  const qulonglong firstEpoch = backend.readOnlyProbeSnapshot()
      .value(QStringLiteral("connectionEpoch")).toULongLong();
  QVERIFY(firstEpoch > 0);

  stopServer(&firstServer);
  if (!startServer(&secondServer, secondRuntime, &startError)) {
    const QByteArray skipMessage = startError.toLocal8Bit();
    QSKIP(skipMessage.constData());
  }
  backend.apply(matrixFor(Settings::defaults()), 2);
  QVERIFY(!failed.isEmpty());
  backend.apply(matrixFor(Settings::defaults()), 3);
  QCOMPARE(applied.size(), 2);
  QCOMPARE(applied.last().at(0).toULongLong(), 3ULL);
  const qulonglong secondEpoch = backend.readOnlyProbeSnapshot()
      .value(QStringLiteral("connectionEpoch")).toULongLong();
  QVERIFY(secondEpoch > firstEpoch);
  backend.release(4);
}

void WireProtocolTests::stalledCompositorIsBounded() {
  QTemporaryDir runtime;
  QVERIFY(runtime.isValid());
  FakeServer server;
  const auto cleanup = qScopeGuard([&server] { stopServer(&server); });
  QString startError;
  if (!startServer(&server, runtime, &startError)) {
    const QByteArray skipMessage = startError.toLocal8Bit();
    QSKIP(skipMessage.constData());
  }
  WaylandBackend backend;
  backend.probe();
  wl_display_terminate(server.display);
  if (server.thread.joinable()) server.thread.join();
  QSignalSpy failed(&backend, &WaylandBackend::failed);
  QElapsedTimer timer;
  timer.start();
  backend.apply(matrixFor(Settings::defaults()), 11);
  QVERIFY(!failed.isEmpty());
  QVERIFY2(timer.elapsed() < 1500, "a stalled compositor blocked longer than the backend's bounded barrier");
  backend.stop();
}

QTEST_GUILESS_MAIN(WireProtocolTests)

#include "WireProtocolTests.moc"
