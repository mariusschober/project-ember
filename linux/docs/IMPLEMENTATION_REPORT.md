# Linux implementation report

Report date: 2026-09-20 UTC  
Branch: feat/linux-omarchy-native-20260920  
Candidate: 0.1.0-linux-alpha.1  
Disposition: implementation checkpoint for review; not merged, released, or deployed.

## Source provenance

- The branch started at 01d0aa79a4bfe4dcfce3bdfb68e13e9343158953.
- The first local implementation checkpoint is 637f7f8.
- The corresponding GitHub API-pushed checkpoint is 725554d16c481f4fe18d80d0859627854c2bbcb9.
- The second local implementation/operations checkpoint is ea02c95.
- The corresponding GitHub API-pushed checkpoint is 56d58a406d296f07b3c67413a3cdda62fe16de77.
- Mac reference behavior was read from commit 41973930103c5c12c5c04715f4a1943ff759628d, tree b46195b62135658ae45b54a7261a0c872a9abbef.
- The committed CTM XML is the hyprwm/hyprland-protocols blob 6cb791c1710cdedfc59b3d48fd91cca997d1eabd; attribution is in linux/protocols/NOTICE.
- No Mac source files were changed.

## Implemented scope

| Contract | Implementation/evidence | Current evidence level |
| --- | --- | --- |
| F01 tray and settings | Qt Widgets dialog, QSystemTrayIcon, native context menu, D-Bus resident | Implemented; real tray host not run |
| F02 safe defaults/off startup | Validated defaults, read-only CLI probe, no off-state CTM owner bind | Unit/CLI tested |
| F03 on/off and saved preferences | Single coordinator, generation invalidation, release before final off | Implemented; real display blocked |
| F04 presets | Neutral/Evening/Pure Red change warmth only | Unit tested |
| F05 exact warmth continuum | Mac ColorCurve coefficients, smoothstep, red tail, exact endpoint | Property/endpoint tested; independent Swift fixture generation outstanding |
| F06 software brightness | Independent diagonal matrix and 24.8 quantization | Unit tested |
| F07 all-output control | Dedicated connection and complete staged output map per commit | Wire harness compiled; socket execution blocked |
| F08 click routing | Configurable primary action and secondary native controls | Implemented; Quickshell tray semantics blocked |
| F09/F10 backlight | Built-in-only association, permission/readback gate, durable baseline, bounded drift | Fake sysfs unit tested; physical target blocked |
| F11–F13 Sun schedule | Offline coordinates, named timezone solar model, manual override and pause latch | Solar unit tested; live schedule blocked |
| F14 login | One systemd user unit and actual systemctl --user result reflected | Unit shipped; user manager blocked |
| F15 recovery | Headless restore, journal locking/durability, identity/value checks, clean-exit supervision marker | Unit/CLI marker tested; process-service test blocked |
| F16 truthful evidence | requestProcessed, effectiveFilterEnabled, pixelsVerified=false, optical readback unavailable | Unit/CLI status checked |
| F17 sleep/topology | PrepareForSleep, release-before-restore, reconnect/topology generations | Implemented; real session blocked |
| F18 diagnostics | Sanitized status, Copy/Export, Retry, emergency Restore and CLI | Unit/UI code checked; UI host blocked |
| F19 local product | No network/account/telemetry code; author credit retained | Source/code checked |
| F20 Mac visual/Apple packaging | Deliberately not ported; Arch/native Linux packaging supplied | Expected adaptation |

## Verification executed

The build used an isolated dependency extraction at /tmp/project-ember-deps
because the container's system package lock prevented installation. The
observed toolchain was Ubuntu 24.04 userspace, x86_64, GCC 13.3.0, Qt 6.4.2,
CMake 3.28.3, Ninja 1.11.1 and wayland-scanner 1.22.0.

Debug:

    cmake --fresh -S linux -B build/linux -G Ninja -DCMAKE_BUILD_TYPE=Debug -DBUILD_TESTING=ON ...
    cmake --build build/linux --parallel 2                         PASS
    ctest --test-dir build/linux --output-on-failure                PASS

Final Debug CTest result: 3/3 CTest tests passed, 0 failed. QtTest details:
11 domain test cases passed; the wire test had 2 harness cases passed and 3
blocked skips; the IPC test had 1 initialization case passed, 1 blocked skip,
and clean teardown. The skips were AF_UNIX socket unavailable: Operation not
permitted and the unavailable session D-Bus (Unable to autolaunch a
dbus-daemon without a $DISPLAY for X11).

Release:

    cmake --fresh -S linux -B build/linux-release -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON -DCMAKE_INSTALL_PREFIX=/usr ...
    cmake --build build/linux-release --parallel 2                   PASS
    ctest --test-dir build/linux-release --output-on-failure          PASS

Final Release CTest result: 3/3 CTest tests passed, 0 failed, with the same
3 wire skips and 1 IPC skip. Both configurations emitted a non-fatal Qt
configure note that XKB headers were absent from the isolated bundle; the
build itself completed. The CI workflow installs libxkbcommon-dev.

Additional checks:

- project-ember --version, --help, read-only status --json and doctor --json: PASS.
- Headless --arm-guardian, --recover-hardware, and explicit restore in
  isolated XDG directories: PASS.
- Clean-exit marker versus no-marker supervision behavior: PASS; intentional
  clean exit preserved automationPaused=false, while the no-marker path
  persisted automationPaused=true.
- git diff --check: PASS.
- bash -n linux/packaging/arch/PKGBUILD linux/scripts/*.sh: PASS.
- Staged Release install content: PASS for executable, desktop file, SVG
  icon, CTM notice and /usr/lib/systemd/user/project-ember.service.
- Local install-tree archive (not a public release):
  /tmp/project-ember-0.1.0-linux-alpha.1-x86_64-install.tar, SHA-256
  c0262215d494b551d059395d504966afa60e1ec88e6f4ea7f1f286439ff6433e,
  389120 bytes.

The container has no makepkg, so the Arch package was syntax-checked but not
built by makepkg. systemd-analyze verify parsed the generated unit but
returned a nonzero result for the staged tree because /usr/bin/project-ember
is not installed in the container root; this is not reported as service
runtime validation.

## Explicitly blocked or not run

The environment has no WAYLAND_DISPLAY, XDG_RUNTIME_DIR, active session
type, running systemd user manager, Hyprland/Omarchy compositor, sysfs
backlight device, or physical display. The sandbox denies AF_UNIX socket
creation with EPERM, so the real libwayland-server and private-D-Bus tests
could not execute their transport boundary. project-ember --system-probe
opened no Wayland connection and made no display claim.

Consequently the following remain BLOCKED_ENVIRONMENT, not PASS: actual
Omarchy tray behavior; CTM v2 registry/ownership/conflict on a compositor;
display warmth/dimming/Pure Red; multi-output/hotplug/restart; real
Backlight Lock and crash cleanup; sleep/wake; HDR/ICC/direct-scanout/cursor/
capture modes; login ordering; Sun transitions on a live session; endurance
CPU/RSS/wakeup measurements; and all H01–H13 rows in
linux/docs/HARDWARE_ACCEPTANCE.md.

The Swift toolchain is absent, so the requested independently generated Swift
numeric fixture set was not run. Existing Mac CI was not changed or claimed as
run. No AUR upload, release publication, merge, or desktop deployment was
performed.

See linux/docs/PLATFORM_PROBE.md for the environment inventory,
linux/docs/RECOVERY.md for cleanup semantics, and linux/README.md for
install, service, restore and uninstall guidance.
