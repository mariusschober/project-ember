# Project Ember for Omarchy Linux

This is the independent native Linux candidate for Project Ember. It is a
small Qt 6 Widgets/Core/D-Bus tray and settings utility with a dedicated
Wayland client connection and the pinned Hyprland CTM v2 protocol. It does not
modify the existing macOS app and is versioned separately as
`0.1.0-linux-alpha.1`.

The filter and schedule are off on a fresh install. Registry/status probes do
not bind a CTM manager. Enabling Ember requires
`hyprland_ctm_control_manager_v1` interface version 2; an older or missing
global is reported unsupported. Every commit stages all current Wayland
outputs. A compositor sync means only that the request was processed:
`pixelsVerified` remains false because this protocol has no pixel, gamma, or
optical readback.

## Build and test

Required build packages are CMake 3.24+, Ninja, a C++20 compiler, Qt 6.4+
Core/Widgets/D-Bus/Test, Qt Wayland, libwayland client/server development
files, `wayland-scanner`, and `pkg-config`.

```bash
cmake -S linux -B build/linux -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug -DBUILD_TESTING=ON
cmake --build build/linux --parallel
dbus-run-session -- ctest --test-dir build/linux --output-on-failure
```

`linux/scripts/build-linux.sh` and `linux/scripts/test-linux.sh` provide the
same source-build path with isolated XDG test directories. Tests use a real
generated-protocol/libwayland-server harness and fake hardware rooted in a
temporary directory; they never fall back to a real display or backlight.
Sanitizers are enabled with `-DEMBER_ENABLE_SANITIZERS=ON`.

The vendored protocol and exact upstream blob are recorded in
`linux/protocols/NOTICE`. CMake performs no network fetch. It generates the
bindings locally and applies only the documented scanner-compatibility
normalization to a build-directory copy of the XML.

## Install and start

For a source install:

```bash
cmake -S linux -B build/linux-release -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
  -DCMAKE_INSTALL_PREFIX="$HOME/.local"
cmake --build build/linux-release --parallel
cmake --install build/linux-release
```

The generated unit embeds the configured install prefix. Import only the
session variables the graphical user service needs, then start the app:

```bash
systemctl --user import-environment \
  WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_SESSION_ID \
  DBUS_SESSION_BUS_ADDRESS HYPRLAND_INSTANCE_SIGNATURE
systemctl --user daemon-reload
systemctl --user start project-ember.service
project-ember settings
```

For the Arch/Omarchy package, `PKGBUILD` fetches the exact immutable source
commit recorded in `_commit`. Build it as an ordinary user, then inspect and
install the resulting local package explicitly:

```bash
cd linux/packaging/arch
makepkg --cleanbuild --syncdeps
pacman -Qip ./project-ember-0.1.0.alpha1-1-x86_64.pkg.tar.zst
sudo pacman -U ./project-ember-0.1.0.alpha1-1-x86_64.pkg.tar.zst
```

Package installation places the binary, desktop file, icon, protocol notice,
and user unit, but does not enable or start the service and does not change any
display setting. The retained CI package is a short-lived review artifact, not
a release or an AUR publication.

The desktop launcher runs `project-ember settings`. If no controller exists,
that command starts `project-ember.service`, waits for its local D-Bus owner,
and opens the settings window. It does not launch an unsupervised second
controller. `project-ember run` is available only as a source-development
route; without the service guardian, Backlight Lock stays unavailable. The app
refuses graphical or hardware-mutating operation as root.

Sun schedule attempts to enable this same user service for graphical-session
login. A registration failure is shown as session-only and does not become a
false enabled state. The package and installer do not automatically enable the
service, filtering, scheduling, or Backlight Lock, and they never edit Omarchy,
Hyprland, Quickshell, Waybar, or night-light configuration.

## Commands

```text
project-ember settings
project-ember on | off | toggle
project-ember preset neutral|evening|pure-red
project-ember warmth 0..100
project-ember brightness 10..100
project-ember status --json
project-ember doctor --json
project-ember resume-automation
project-ember restore
project-ember resolve-recovery keep-current
project-ember resolve-recovery discard-unreadable
project-ember resolve-settings replace
project-ember quit
```

`status` and `doctor` are genuinely read-only when no resident exists: they do
not start a service, open Wayland, create lock files, repair settings, or write
hardware. `--system-probe` is the separate registry-only command used by the
opt-in hardware script; it opens Wayland but never binds the owning CTM global.
Mutating commands require the one resident, except emergency `restore`, whose
headless hardware cleanup path is intentionally available without a window.
Accepted D-Bus mutations receive monotonically increasing request IDs, and
status separates desired state, protocol ownership, processed generation, and
unavailable pixel evidence.

## Backlight Lock and recovery

Backlight Lock is optional and fail-closed. It requires a unique EDID-backed
internal DRM/backlight mapping, writable requested brightness, verified boot
and graphical-session identity, an invocation-bound guardian, and logind sleep
coordination. A baseline is durably journaled before mutation. Requested
brightness is read back exactly; when `actual_brightness` exists, the driver
value must converge within 2% of the scale (at least one unit). Hardware is
restored before ordinary CTM release.

There is no documented generic Linux automatic-brightness switch in the
backlight sysfs ABI. Production therefore reports automatic brightness as
unmanaged unless a future target-specific reversible provider is added. The
boolean adapter used by tests cannot activate for `/sys` hardware.

See `linux/docs/RECOVERY.md` before enabling Backlight Lock. In particular,
corrupt or future recovery evidence remains blocking until verified restore,
identity-verified keep-current resolution, or explicit last-resort discard.
None of these states is silently treated as a fresh install.

## Upgrade and uninstall

Build the Arch package from its pinned immutable source or reinstall the same
prefix, then restart the user service. To uninstall an Arch package:

```bash
systemctl --user disable --now project-ember.service
sudo pacman -R project-ember
```

For a prefix install, stop/disable the service and remove only the paths listed
in that build's `install_manifest.txt`. Do not delete
`$XDG_STATE_HOME/project-ember` while recovery is pending. User settings/state
are deliberately not removed by package uninstall.

## Evidence boundary

The implementation/container and real-target evidence are tracked separately
in `linux/docs/IMPLEMENTATION_REPORT.md`, `linux/docs/PLATFORM_PROBE.md`, and
`linux/docs/HARDWARE_ACCEPTANCE.md`. Until ordinary SDR control, tray behavior,
conflicts, recovery, schedule/login, and applicable Backlight checks pass on a
named Omarchy machine, this candidate is not claimed as daily-use validated.
