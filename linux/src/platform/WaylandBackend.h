#pragma once

#include "core/Model.h"

#include <QObject>
#include <QTimer>

#include <cstdint>
#include <map>

struct wl_display;
struct wl_output;
struct wl_registry;
struct wl_callback;
struct hyprland_ctm_control_manager_v1;

namespace ember {

class WaylandBackend final : public QObject {
  Q_OBJECT

public:
  explicit WaylandBackend(QObject *parent = nullptr);
  ~WaylandBackend() override;

public slots:
  void probe();
  void apply(ColorMatrix matrix, qulonglong generation);
  void release();
  void stop();

signals:
  void capabilityChanged(bool waylandAvailable, int managerVersion, int outputCount, QString reason);
  void applied(qulonglong generation);
  void blocked(QString reason);
  void failed(QString reason);
  void topologyChanged();
  void released();

private slots:
  void pumpSocket();

private:
  struct OutputState {
    WaylandBackend *owner = nullptr;
    std::uint32_t globalName = 0;
    std::uint32_t boundVersion = 1;
    wl_output *object = nullptr;
    QString name;
    QString description;
    QString make;
    QString model;
    bool done = false;
  };

  struct SyncWait {
    wl_callback *callback = nullptr;
    bool done = false;
  };

  bool connectDisplay();
  bool waitForRegistry();
  bool waitForSync(int timeoutMs);
  bool pumpOnce(int timeoutMs);
  bool bindManager();
  bool submit(ColorMatrix matrix, qulonglong generation);
  void destroyManager();
  void destroyDisplay();
  void reportFailure(const QString &reason);

public:
  static void registryGlobal(void *data, wl_registry *registry, std::uint32_t name,
                             const char *interface, std::uint32_t version);
  static void registryGlobalRemove(void *data, wl_registry *registry, std::uint32_t name);
  static void outputGeometry(void *data, wl_output *output, std::int32_t x, std::int32_t y,
                             std::int32_t physicalWidth, std::int32_t physicalHeight,
                             std::int32_t subpixel, const char *make, const char *model,
                             std::int32_t transform);
  static void outputMode(void *data, wl_output *output, std::uint32_t flags,
                         std::int32_t width, std::int32_t height, std::int32_t refresh);
  static void outputDone(void *data, wl_output *output);
  static void outputScale(void *data, wl_output *output, std::int32_t factor);
  static void outputName(void *data, wl_output *output, const char *name);
  static void outputDescription(void *data, wl_output *output, const char *description);
  static void managerBlocked(void *data, hyprland_ctm_control_manager_v1 *manager);
  static void syncDone(void *data, wl_callback *callback, std::uint32_t callbackData);

private:
  wl_display *display_ = nullptr;
  wl_registry *registry_ = nullptr;
  hyprland_ctm_control_manager_v1 *manager_ = nullptr;
  QTimer *pumpTimer_ = nullptr;
  std::map<std::uint32_t, OutputState> outputs_;
  std::uint32_t managerGlobalName_ = 0;
  int managerVersion_ = 0;
  bool registryReady_ = false;
  bool managerBlocked_ = false;
  bool stopping_ = false;
  std::uint64_t connectionEpoch_ = 0;
};

} // namespace ember
