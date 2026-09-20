# Project Ember for Omarchy Linux

This is the native Linux candidate for Project Ember. It is a small Qt 6
Widgets/Core/D-Bus tray and settings utility using a dedicated Wayland client
connection and the pinned Hyprland CTM v2 protocol. The existing macOS app is
unchanged; the Linux candidate is versioned independently as
`0.1.0-linux-alpha.1`.

## Build and test

Required packages are CMake 3.24+, Ninja, a C++20 compiler, Qt 6 Core/Widgets/
D-Bus/Test and Qt's Wayland platform support, `wayland-client`,
`wayland-server`, `wayland-scanner`, and `pkg-config`.

From the repository root:

```bash
cmake -S linux -B build/linux -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug -DBUILD_TESTING=ON
cmake --build build/linux
ctest --test-dir build/linux --output-on-failure
```

The helper scripts are `linux/scripts/build-linux.sh` and
`linux/scripts/test-linux.sh`. They create isolated test configuration and
runtime directories. The wire test uses a real libwayland-server socket; a
host that denies AF_UNIX sockets reports those cases as blocked skips.

The protocol XML is vendored from the exact blob recorded in
`linux/protocols/NOTICE`. CMake generates client/server bindings locally; it
does not fetch code or protocols from the network. The compatibility transform
only adapts the XML parser spelling required by older `wayland-scanner`
versions and never changes the committed source XML.

## Run locally

```bash
cmake -S linux -B build/linux-release -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
  -DCMAKE_INSTALL_PREFIX="$HOME/.local"
cmake --build build/linux-release
cmake --install build/linux-release
```

For a local prefix, the generated user service points at the installed
`$HOME/.local/bin/project-ember`. Import only the session variables needed by
the user service, then enable it when the graphical session is ready:

```bash
systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS HYPRLAND_INSTANCE_SIGNATURE
systemctl --user daemon-reload
systemctl --user enable --now project-ember.service
```

The service is intentionally tied to `graphical-session.target`; it is not an
XDG autostart entry and it does not edit Omarchy or Hyprland configuration.
`project-ember settings` addresses the resident D-Bus instance. It does not
silently start a second controller. `status --json` and `doctor --json` are
read-only when no resident instance is available.

For an Arch install, enable the unit only after the graphical session exports
its Wayland/D-Bus environment. Remove it with
`systemctl --user disable --now project-ember.service` followed by
`pacman -R project-ember`; this leaves
`$XDG_CONFIG_HOME/project-ember` and `$XDG_STATE_HOME/project-ember` intact so
an unresolved recovery record is not discarded. A local-prefix install can be
removed using the exact paths listed by
`build/linux-release/install_manifest.txt` after stopping the user service.

Backlight Lock is unavailable unless the exact built-in backlight is writable,
unambiguous, and the independent guardian has been armed by the supervised
service. Software filtering remains usable without it. `project-ember restore`
and the service's headless `--recover-hardware` path are the recovery routes.

## Scope and evidence

This candidate requires a live Hyprland-compatible `hyprland_ctm_control_manager_v1`
version 2 global for display control. A Wayland sync proves only that the
compositor processed the request; it is not pixel or optical verification.
Diagnostics therefore report `requestProcessed` separately from
`pixelsVerified`, which remains false because this backend has no pixel
readback.

The current environment probe and acceptance rows are recorded in
`linux/docs/PLATFORM_PROBE.md`, `linux/docs/HARDWARE_ACCEPTANCE.md`, and
`linux/docs/IMPLEMENTATION_REPORT.md`.
