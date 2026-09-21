# Linux platform probe

Probe record updated: 2026-09-21 UTC
Branch: `feat/linux-omarchy-native-20260920`  
Candidate: `0.1.0-linux-alpha.1`

## Source and protocol provenance

- Governing plan: `docs/plans/linux-omarchy-20260920/PLAN.md` plus its linked
  Mac review and parity/test matrix.
- Pinned Mac behavior baseline: commit
  `41973930103c5c12c5c04715f4a1943ff759628d`, tree
  `b46195b62135658ae45b54a7261a0c872a9abbef`.
- Vendored Hyprland CTM XML: `hyprwm/hyprland-protocols` blob
  `6cb791c1710cdedfc59b3d48fd91cca997d1eabd`; source attribution and terms are
  in `linux/protocols/NOTICE`.
- The committed XML is unchanged. A build-directory-only CMake transform
  removes the event `version="2"` spelling and supplies the summary required by
  older Wayland 1.22 scanners; generated bindings are not committed.

## Implementation-container inventory

The available environment is an x86_64 Linux container with Ubuntu 24.04
userspace, GCC 13.3, Qt 6.4.2, CMake 3.28.3, Ninja 1.11.1 and
wayland-scanner/libwayland 1.22 from an isolated dependency extraction under
`/tmp/project-ember-deps`. It has no `WAYLAND_DISPLAY`, Omarchy/Hyprland
desktop, graphical systemd user session, physical output, DRM connector, or
backlight device. No host display setting or package installation was changed.

Those absences block real compositor, tray, login, sleep and hardware
acceptance. They do not block compilation, deterministic domain tests,
generated-protocol tests on a private fake server when local sockets are
available, private D-Bus tests, fake-hardware process recovery, install staging,
or source-package construction.

## Read-only target probe contract

Run only on the designated non-root graphical session:

```bash
EMBER_HARDWARE_ACCEPT=1 linux/scripts/hardware-check.sh
```

The script invokes `project-ember --system-probe --json`. This command reads
validated local settings/recovery state, probes the Linux backlight class, and
opens a dedicated Wayland connection only long enough to enumerate registry
globals and `wl_output` metadata. It does not bind
`hyprland_ctm_control_manager_v1`, send a matrix, enable the service, repair
files, or write hardware.

The target record must establish actual Omarchy, Hyprland, Quickshell/tray,
Qt, kernel, GPU/driver and CPU-architecture versions; graphical session and
systemd/UWSM environment; CTM interface version; output topology/modes;
competing color owner; DRM/backlight identity and permissions; and relevant
HDR/ICC/direct-scanout/cursor/capture modes. None can be inferred from this
container or from the source Mac's model name.

## Current capability conclusions

- Display control requires advertised CTM interface version 2. Missing/v1 is
  explicitly Unsupported. Off-state probing never owns the manager.
- `requestProcessed` means a compositor sync completed for the current
  operation generation. It never means pixels or physical output were read
  back; `pixelsVerified` is always false.
- Backlight Lock cannot engage until the target supplies one unambiguous,
  writable, EDID-associated built-in backlight plus service/logind/session
  recovery prerequisites.
- The standard Linux backlight ABI has no generic automatic-brightness toggle,
  so production reports that sub-capability unmanaged. The isolated boolean
  fake is test-only and rejected for `/sys`.
- All H01–H13 rows remain `BLOCKED_ENVIRONMENT` until recorded on the named
  target. Simulated protocol or fake-hardware results will remain labeled as
  such in the implementation report.
