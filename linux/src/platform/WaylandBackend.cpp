#include "platform/WaylandBackend.h"

#include "hyprland-ctm-control-v1-client-protocol.h"

#include <QElapsedTimer>

#include <poll.h>
#include <wayland-client-core.h>
#include <wayland-client-protocol.h>

#include <algorithm>
#include <cstring>

namespace ember {

namespace {

const wl_registry_listener registryListener = {
    &WaylandBackend::registryGlobal,
    &WaylandBackend::registryGlobalRemove,
};

const wl_output_listener outputListener = {
    &WaylandBackend::outputGeometry,
    &WaylandBackend::outputMode,
    &WaylandBackend::outputDone,
    &WaylandBackend::outputScale,
    &WaylandBackend::outputName,
    &WaylandBackend::outputDescription,
};

const hyprland_ctm_control_manager_v1_listener managerListener = {
    &WaylandBackend::managerBlocked,
};

const wl_callback_listener syncListener = {
    &WaylandBackend::syncDone,
};

} // namespace

WaylandBackend::WaylandBackend(QObject *parent) : QObject(parent) {}

WaylandBackend::~WaylandBackend() { stop(); }

void WaylandBackend::probe() {
  if (display_ == nullptr && !connectDisplay()) return;
  emit capabilityChanged(true, managerVersion_, static_cast<int>(outputs_.size()),
                         managerVersion_ >= 2 ? QString() : QStringLiteral("Hyprland CTM protocol v2 is not advertised"));
}

void WaylandBackend::apply(ColorMatrix matrix, qulonglong generation) {
  if (!finiteNonNegativeMatrix(matrix)) {
    reportFailure(QStringLiteral("refusing non-finite or negative color matrix"));
    return;
  }
  if (display_ == nullptr && !connectDisplay()) return;
  if (managerVersion_ < 2) {
    emit failed(QStringLiteral("Hyprland CTM manager v2 is unavailable; no display was changed"));
    return;
  }
  if (outputs_.empty()) {
    emit failed(QStringLiteral("No live Wayland outputs are available"));
    return;
  }
  if (!bindManager()) return;
  if (managerBlocked_) {
    destroyManager();
    emit blocked(QStringLiteral("Another CTM controller owns the compositor"));
    return;
  }
  (void)submit(matrix, generation);
}

void WaylandBackend::release() {
  destroyManager();
  emit released();
}

void WaylandBackend::stop() {
  if (stopping_) return;
  stopping_ = true;
  if (pumpTimer_ != nullptr) pumpTimer_->stop();
  destroyManager();
  destroyDisplay();
  stopping_ = false;
}

void WaylandBackend::pumpSocket() {
  if (display_ == nullptr) return;
  if (!pumpOnce(0)) {
    reportFailure(QStringLiteral("Wayland connection failed while dispatching events"));
  }
}

bool WaylandBackend::connectDisplay() {
  if (display_ != nullptr) return true;
  display_ = wl_display_connect(nullptr);
  if (display_ == nullptr) {
    emit capabilityChanged(false, 0, 0, QStringLiteral("No active Wayland session is available"));
    return false;
  }
  ++connectionEpoch_;
  stopping_ = false;
  registry_ = wl_display_get_registry(display_);
  if (registry_ == nullptr || wl_registry_add_listener(registry_, &registryListener, this) != 0) {
    reportFailure(QStringLiteral("Could not initialize the Wayland registry"));
    return false;
  }
  if (!waitForRegistry()) {
    reportFailure(QStringLiteral("Wayland registry did not become ready within 500 ms"));
    return false;
  }
  if (pumpTimer_ == nullptr) {
    pumpTimer_ = new QTimer(this);
    pumpTimer_->setInterval(25);
    connect(pumpTimer_, &QTimer::timeout, this, &WaylandBackend::pumpSocket);
  }
  pumpTimer_->start();
  emit capabilityChanged(true, managerVersion_, static_cast<int>(outputs_.size()),
                         managerVersion_ >= 2 ? QString() : QStringLiteral("Hyprland CTM protocol v2 is not advertised"));
  return true;
}

bool WaylandBackend::waitForRegistry() {
  registryReady_ = false;
  if (!waitForSync(500)) return false;
  registryReady_ = true;
  return true;
}

bool WaylandBackend::waitForSync(int timeoutMs) {
  if (display_ == nullptr) return false;
  SyncWait wait;
  wait.callback = wl_display_sync(display_);
  if (wait.callback == nullptr || wl_callback_add_listener(wait.callback, &syncListener, &wait) != 0) {
    if (wait.callback != nullptr) wl_callback_destroy(wait.callback);
    return false;
  }
  QElapsedTimer timer;
  timer.start();
  while (!wait.done && timer.elapsed() < timeoutMs) {
    if (!pumpOnce(std::min(20, timeoutMs - static_cast<int>(timer.elapsed())))) break;
  }
  if (!wait.done && wait.callback != nullptr) {
    wl_callback_destroy(wait.callback);
    wait.callback = nullptr;
  }
  return wait.done && wl_display_get_error(display_) == 0;
}

bool WaylandBackend::pumpOnce(int timeoutMs) {
  if (display_ == nullptr) return false;
  if (wl_display_get_error(display_) != 0) return false;
  if (wl_display_dispatch_pending(display_) < 0) return false;
  if (wl_display_prepare_read(display_) != 0) {
    return wl_display_dispatch_pending(display_) >= 0;
  }
  (void)wl_display_flush(display_);
  struct pollfd descriptor {wl_display_get_fd(display_), POLLIN, 0};
  const int polled = ::poll(&descriptor, 1, std::max(timeoutMs, 0));
  if (polled < 0) {
    if (errno == EINTR) {
      wl_display_cancel_read(display_);
      return true;
    }
    wl_display_cancel_read(display_);
    return false;
  }
  if (polled > 0 && (descriptor.revents & (POLLIN | POLLERR | POLLHUP))) {
    if (wl_display_read_events(display_) < 0) return false;
  } else {
    wl_display_cancel_read(display_);
  }
  return wl_display_dispatch_pending(display_) >= 0 && wl_display_get_error(display_) == 0;
}

bool WaylandBackend::bindManager() {
  if (manager_ != nullptr) return true;
  if (registry_ == nullptr || managerGlobalName_ == 0 || managerVersion_ < 2) return false;
  managerBlocked_ = false;
  manager_ = static_cast<hyprland_ctm_control_manager_v1 *>(
      wl_registry_bind(registry_, managerGlobalName_, &hyprland_ctm_control_manager_v1_interface, 2));
  if (manager_ == nullptr || hyprland_ctm_control_manager_v1_add_listener(manager_, &managerListener, this) != 0) {
    destroyManager();
    emit failed(QStringLiteral("Could not bind the Hyprland CTM manager"));
    return false;
  }
  // The barrier is deliberately bounded and runs on this dedicated Wayland
  // worker, never on Qt's settings/UI thread. No CTM request is sent before
  // the v2 blocked event has had a chance to arrive.
  if (!waitForSync(250)) {
    destroyManager();
    emit failed(QStringLiteral("CTM ownership barrier timed out; no display was changed"));
    return false;
  }
  if (managerBlocked_) {
    destroyManager();
    emit blocked(QStringLiteral("Another CTM controller owns the compositor"));
    return false;
  }
  return true;
}

bool WaylandBackend::submit(ColorMatrix matrix, qulonglong generation) {
  // The staged map is complete: every currently live wl_output is included in
  // every commit because the protocol resets omitted outputs to identity.
  for (auto &[globalName, output] : outputs_) {
    Q_UNUSED(globalName);
    if (output.object == nullptr) continue;
    hyprland_ctm_control_manager_v1_set_ctm_for_output(
        manager_, output.object,
        wl_fixed_from_double(matrix.values[0]), wl_fixed_from_double(matrix.values[1]), wl_fixed_from_double(matrix.values[2]),
        wl_fixed_from_double(matrix.values[3]), wl_fixed_from_double(matrix.values[4]), wl_fixed_from_double(matrix.values[5]),
        wl_fixed_from_double(matrix.values[6]), wl_fixed_from_double(matrix.values[7]), wl_fixed_from_double(matrix.values[8]));
  }
  hyprland_ctm_control_manager_v1_commit(manager_);
  if (wl_display_flush(display_) < 0 && errno != EAGAIN) {
    reportFailure(QStringLiteral("Wayland CTM commit could not be flushed"));
    return false;
  }
  if (!waitForSync(500)) {
    reportFailure(QStringLiteral("Wayland CTM request was not processed within 500 ms"));
    return false;
  }
  emit applied(generation);
  return true;
}

void WaylandBackend::destroyManager() {
  if (manager_ != nullptr) {
    hyprland_ctm_control_manager_v1_destroy(manager_);
    manager_ = nullptr;
    if (display_ != nullptr) (void)wl_display_flush(display_);
  }
  managerBlocked_ = false;
}

void WaylandBackend::destroyDisplay() {
  for (auto &[globalName, output] : outputs_) {
    Q_UNUSED(globalName);
    if (output.object == nullptr) continue;
    if (output.boundVersion >= 3) wl_output_release(output.object);
    else wl_output_destroy(output.object);
  }
  outputs_.clear();
  if (registry_ != nullptr) {
    wl_registry_destroy(registry_);
    registry_ = nullptr;
  }
  if (display_ != nullptr) {
    wl_display_disconnect(display_);
    display_ = nullptr;
  }
  managerGlobalName_ = 0;
  managerVersion_ = 0;
  registryReady_ = false;
}

void WaylandBackend::reportFailure(const QString &reason) {
  emit failed(reason);
  destroyManager();
  destroyDisplay();
}

void WaylandBackend::registryGlobal(void *data, wl_registry *registry, std::uint32_t name,
                                    const char *interface, std::uint32_t version) {
  auto *self = static_cast<WaylandBackend *>(data);
  if (std::strcmp(interface, "hyprland_ctm_control_manager_v1") == 0) {
    self->managerGlobalName_ = name;
    self->managerVersion_ = static_cast<int>(version);
    return;
  }
  if (std::strcmp(interface, "wl_output") != 0) return;
  const std::uint32_t boundVersion = std::min(version, 4U);
  auto [iterator, inserted] = self->outputs_.emplace(name, OutputState{});
  if (!inserted) return;
  iterator->second.owner = self;
  iterator->second.globalName = name;
  iterator->second.boundVersion = boundVersion;
  iterator->second.object = static_cast<wl_output *>(wl_registry_bind(registry, name, &wl_output_interface, boundVersion));
  if (iterator->second.object == nullptr || wl_output_add_listener(iterator->second.object, &outputListener, &iterator->second) != 0) {
    if (iterator->second.object != nullptr) {
      if (boundVersion >= 3) wl_output_release(iterator->second.object);
      else wl_output_destroy(iterator->second.object);
    }
    self->outputs_.erase(iterator);
  }
}

void WaylandBackend::registryGlobalRemove(void *data, wl_registry *registry, std::uint32_t name) {
  Q_UNUSED(registry);
  auto *self = static_cast<WaylandBackend *>(data);
  if (name == self->managerGlobalName_) {
    self->managerGlobalName_ = 0;
    self->managerVersion_ = 0;
    self->destroyManager();
    emit self->capabilityChanged(true, 0, static_cast<int>(self->outputs_.size()),
                                 QStringLiteral("Hyprland CTM manager disappeared from the Wayland registry"));
  }
  const auto iterator = self->outputs_.find(name);
  if (iterator == self->outputs_.end()) return;
  if (iterator->second.object != nullptr) {
    if (iterator->second.boundVersion >= 3) wl_output_release(iterator->second.object);
    else wl_output_destroy(iterator->second.object);
  }
  self->outputs_.erase(iterator);
  emit self->topologyChanged();
}

void WaylandBackend::outputGeometry(void *data, wl_output *output, std::int32_t x, std::int32_t y,
                                    std::int32_t physicalWidth, std::int32_t physicalHeight,
                                    std::int32_t subpixel, const char *make, const char *model,
                                    std::int32_t transform) {
  Q_UNUSED(output); Q_UNUSED(x); Q_UNUSED(y); Q_UNUSED(physicalWidth); Q_UNUSED(physicalHeight); Q_UNUSED(subpixel); Q_UNUSED(transform);
  auto *state = static_cast<OutputState *>(data);
  state->make = QString::fromUtf8(make == nullptr ? "" : make);
  state->model = QString::fromUtf8(model == nullptr ? "" : model);
}

void WaylandBackend::outputMode(void *data, wl_output *output, std::uint32_t flags,
                                std::int32_t width, std::int32_t height, std::int32_t refresh) {
  Q_UNUSED(data); Q_UNUSED(output); Q_UNUSED(flags); Q_UNUSED(width); Q_UNUSED(height); Q_UNUSED(refresh);
}

void WaylandBackend::outputDone(void *data, wl_output *output) {
  Q_UNUSED(output);
  auto *state = static_cast<OutputState *>(data);
  const bool wasDone = state->done;
  state->done = true;
  if (!wasDone && state->owner != nullptr) emit state->owner->topologyChanged();
}

void WaylandBackend::outputScale(void *data, wl_output *output, std::int32_t factor) {
  Q_UNUSED(data); Q_UNUSED(output); Q_UNUSED(factor);
}

void WaylandBackend::outputName(void *data, wl_output *output, const char *name) {
  Q_UNUSED(output);
  auto *state = static_cast<OutputState *>(data);
  state->name = QString::fromUtf8(name == nullptr ? "" : name);
}

void WaylandBackend::outputDescription(void *data, wl_output *output, const char *description) {
  Q_UNUSED(output);
  auto *state = static_cast<OutputState *>(data);
  state->description = QString::fromUtf8(description == nullptr ? "" : description);
}

void WaylandBackend::managerBlocked(void *data, hyprland_ctm_control_manager_v1 *manager) {
  Q_UNUSED(manager);
  auto *self = static_cast<WaylandBackend *>(data);
  self->managerBlocked_ = true;
}

void WaylandBackend::syncDone(void *data, wl_callback *callback, std::uint32_t callbackData) {
  Q_UNUSED(callbackData);
  auto *wait = static_cast<SyncWait *>(data);
  wait->done = true;
  wait->callback = nullptr;
  wl_callback_destroy(callback);
}

} // namespace ember
