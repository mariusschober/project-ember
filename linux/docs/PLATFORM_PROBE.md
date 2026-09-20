# Linux platform probe

Probe date: 2026-09-20 UTC  
Branch: `feat/linux-omarchy-native-20260920`  
Target candidate: `0.1.0-linux-alpha.1`

## Source and protocol provenance

- Governing plan: `docs/plans/linux-omarchy-20260920/PLAN.md`.
- Mac behavior baseline: commit `41973930103c5c12c5c04715f4a1943ff759628d`, tree `b46195b62135658ae45b54a7261a0c872a9abbef`.
- Vendored Hyprland CTM XML: `hyprwm/hyprland-protocols` blob `6cb791c1710cdedfc59b3d48fd91cca997d1eabd`, recorded in `linux/protocols/NOTICE`.
- The committed XML is unchanged from that blob. The build generates bindings with `wayland-scanner`; the CMake compatibility step removes only the event `version="2"` attribute and adds the summary required by the local scanner, because Wayland 1.22 rejects that source spelling.

## Environment observed here

The available build container is Linux `x86_64` on Ubuntu 24.04 userspace
(kernel reported `6.18.44`), with GCC 13.3.0, Qt 6.4.2, CMake 3.28.3 from
the isolated dependency bundle, Ninja 1.11.1, and `wayland-scanner 1.22.0`.
The container has no `WAYLAND_DISPLAY`, no `XDG_RUNTIME_DIR`, no active
`XDG_SESSION_TYPE`, and no running systemd user manager. The dependencies were
used from an isolated extraction under `/tmp/project-ember-deps`; no host
packages or display settings were changed.

The container also denies `AF_UNIX` socket creation with `EPERM`. Consequently
the libwayland-server integration tests are compiled and registered, but their
real-socket cases are reported as `SKIP`/blocked by environment here. A normal
Linux session/CI runner should execute those cases rather than skip them.

## Probe result

`project-ember --system-probe --json` is read-only and reports that no active
Wayland session is available. No CTM manager was bound, no matrix was sent,
and no display output was claimed. The real Omarchy/Hyprland registry,
`hyprland_ctm_control_manager_v1` version, tray host, output topology, color
controller conflicts, backlight permissions, HDR/ICC/direct-scanout behavior,
and compositor restart behavior remain target-machine acceptance rows.

The application therefore requires an actual Hyprland CTM v2 session for
ordinary display control. It fails closed when that global is missing or older
than v2. The status field `requestProcessed` means only that the Wayland
compositor processed the CTM request; `pixelsVerified` remains false because
there is no pixel/color readback path.
