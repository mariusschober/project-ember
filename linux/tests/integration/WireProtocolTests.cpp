#include "platform/WaylandBackend.h"

#include "hyprland-ctm-control-v1-server-protocol.h"

#include <QSignalSpy>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
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
};

void destroyManagerResource(wl_resource *resource) {
  auto *server = static_cast<FakeServer *>(wl_resource_get_user_data(resource));
  if (server != nullptr) {
    server->managerOwner.store(false);
    server->managerDestroys.fetch_add(1);
  }
}

void setCtm(wl_client *client, wl_resource *resource, wl_resource *outputResource,
           wl_fixed_t mat0, wl_fixed_t mat1, wl_fixed_t mat2, wl_fixed_t mat3,
           wl_fixed_t mat4, wl_fixed_t mat5, wl_fixed_t mat6, wl_fixed_t mat7,
           wl_fixed_t mat8) {
  Q_UNUSED(client);
  auto *server = static_cast<FakeServer *>(wl_resource_get_user_data(resource));
  auto *output = static_cast<FakeOutput *>(wl_resource_get_user_data(outputResource));
  if (server == nullptr || output == nullptr) return;
  output->matrix = {mat0, mat1, mat2, mat3, mat4, mat5, mat6, mat7, mat8};
  server->setRequests.fetch_add(1);
}

void commit(wl_client *client, wl_resource *resource) {
  Q_UNUSED(client);
  auto *server = static_cast<FakeServer *>(wl_resource_get_user_data(resource));
  if (server == nullptr) return;
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
  wl_resource_post_event(resource, 0, 0, 0, 0, 0, "EmberTest", "Virtual eDP output", 0);
  wl_resource_post_event(resource, 1, 1, 1920, 1080, 60000);
  if (version >= 2) wl_resource_post_event(resource, 3, 1);
  if (version >= 4) {
    wl_resource_post_event(resource, 4, "eDP-1");
    wl_resource_post_event(resource, 5, "Ember fake built-in");
  }
  if (version >= 2) wl_resource_post_event(resource, 2);
  Q_UNUSED(server);
}

void bindManager(wl_client *client, void *data, uint32_t version, uint32_t id) {
  auto *server = static_cast<FakeServer *>(data);
  wl_resource *resource = wl_resource_create(client, &hyprland_ctm_control_manager_v1_interface,
                                             static_cast<int>(std::min(version, 2U)), id);
  wl_resource_set_implementation(resource, &managerImplementation, server, &destroyManagerResource);
  server->managerBinds.fetch_add(1);
  if (server->managerOwner.exchange(true)) {
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
  if (wl_global_create(server->display, &wl_output_interface, 4, server, &bindOutput) == nullptr ||
      wl_global_create(server->display, &hyprland_ctm_control_manager_v1_interface, 2, server, &bindManager) == nullptr) {
    if (error != nullptr) *error = QStringLiteral("could not create fake Wayland globals");
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
}

} // namespace

class WireProtocolTests final : public QObject {
  Q_OBJECT

private slots:
  void registryProbeDoesNotBindManager();
  void completeMatrixCommitAndProcessedEvidence();
};

void WireProtocolTests::registryProbeDoesNotBindManager() {
  QTemporaryDir runtime;
  QVERIFY(runtime.isValid());
  FakeServer server;
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
    backend.stop();
  }
  stopServer(&server);
}

void WireProtocolTests::completeMatrixCommitAndProcessedEvidence() {
  QTemporaryDir runtime;
  QVERIFY(runtime.isValid());
  FakeServer server;
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
    QCOMPARE(server.setRequests.load(), 1);
    QCOMPARE(server.commits.load(), 1);
    QCOMPARE(server.output.matrix[0], static_cast<wl_fixed_t>(wl_fixed_from_double(matrixFor(settings).values[0])));
    QCOMPARE(server.output.matrix[4], static_cast<wl_fixed_t>(wl_fixed_from_double(matrixFor(settings).values[4])));
    QCOMPARE(server.output.matrix[8], static_cast<wl_fixed_t>(wl_fixed_from_double(matrixFor(settings).values[8])));
    backend.release();
  }
  stopServer(&server);
}

QTEST_APPLESS_MAIN(WireProtocolTests)

#include "WireProtocolTests.moc"
