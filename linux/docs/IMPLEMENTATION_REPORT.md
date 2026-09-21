# Linux implementation report

Report state: pre-verification source checkpoint, 2026-09-21 UTC
Branch: `feat/linux-omarchy-native-20260920`
Candidate: `0.1.0-linux-alpha.1`
Disposition: review candidate only; not merged, released, published, or deployed.

This file deliberately contains no inherited test or artifact claims. The
implementation and test sources are complete, but the post-gap-closure test
matrix, sanitizer run, Arch package SHA and final GitHub checkpoint will be
inserted only after those exact commands execute.

## Fixed provenance

- Governing plan and acceptance matrix:
  `docs/plans/linux-omarchy-20260920/`.
- Pinned unchanged Mac source: commit
  `41973930103c5c12c5c04715f4a1943ff759628d`, tree
  `b46195b62135658ae45b54a7261a0c872a9abbef`.
- CTM protocol: `hyprwm/hyprland-protocols` blob
  `6cb791c1710cdedfc59b3d48fd91cca997d1eabd`, with terms in
  `linux/protocols/NOTICE`.
- Immutable Linux package source checkpoint:
  `41579cc8b866626070c9048991907f3fb7cfb56f`; final branch commit and built
  package hash remain pending verification.
- Existing Mac application source changes: none.

## Implemented scope and evidence layer

| Contract | Implementation | Evidence available after execution |
|---|---|---|
| F01/F08 tray and controls | `QSystemTrayIcon`, native context menu, scrollable Qt settings, configurable primary activation; secondary activation never toggles in app code | Source + private IPC; actual Quickshell host remains desktop-only |
| F02/F03 safe default and on/off | Validated off defaults; registry-only off probe; one coordinator; Off restores hardware before queued owner release; intentional preferences persist | Unit/coordinator/protocol simulation; rendered output remains hardware-only |
| F04–F06 curve, presets, dimming | Exact pinned Mac coefficients/smoothstep/red tail; diagonal independent brightness; 24.8 transport | 30-row pinned Swift fixture, endpoint/property and quantization tests |
| F07 output map | Dedicated nonblocking Wayland connection; v2 gate; complete live-output staging; topology generations; blocked manager destruction; stale-command cancellation | Generated real wire protocol against libwayland-server |
| F09/F10 Backlight Lock | EDID/DRM/driver identity; requested plus optional actual readback; durable independent schema-2 fields; bounded drift; no fabricated generic automatic provider | Fake sysfs and killed-process recovery; physical gate remains separate |
| F11–F13 solar | Offline rounded coordinates; named-timezone calculations; DST/calendar/polar boundaries; persisted override; sparse clock/timezone reconciliation; explicit safety resume | Deterministic domain/coordinator tests; live transition/logout remains desktop-only |
| F14 startup | One graphical-session systemd user unit; desktop command starts/addresses it; actual `systemctl --user` result; controller lock + D-Bus singleton; root refusal | Fake systemctl/IPC and package validation; UWSM login ordering remains target-only |
| F15/F17 recovery/lifecycle | Invocation guardian, delay inhibitor, restore-before-release, durable clean marker/latch, independent headless cleanup, readable and unreadable explicit resolutions | Fault injection and real helper process killed with SIGKILL; real suspend remains target-only |
| F16/F18 status/diagnostics | Desired state, protocol ownership, operation/request IDs and processed generation are separate; `pixelsVerified=false`; sanitized copy/export and headless emergency routes | Unit/IPC/process evidence; no display-output claim |
| F19 local product | No telemetry, account, updater, geocoder, webview or background shell loop; only user-clicked author link can open a browser | Source inspection |
| F20 Linux adaptation | Plain native controls, Arch package, desktop file, icon, user service; no Mac artwork/signing port | Package/install inspection |

## Safety decisions and deliberate deviations

- Hyprland CTM is functional parity, not photometric identity with the Mac
  transfer-table backend. ICC/gamma baseline preservation and physical spectral
  equivalence are not claimed.
- Wayland sync is request-processing evidence only. There is no pixel, gamma,
  or optical readback, so protocol simulation can never pass H02/H03.
- The documented Linux backlight ABI does not expose generic automatic
  brightness. Production leaves it unmanaged until a target-specific reversible
  provider exists; only a non-`/sys` boolean test adapter is present.
- Backlight engagement requires boot and graphical-session identity, unique
  physical association, write/readback, service guardian and logind sleep
  coordination. Unsupported machines retain software color/dimming only.
- Exact-pole state changes use the first local noon whose polar day/night state
  differs as a bounded synthetic scheduling boundary; ordinary latitudes use
  calculated sunrise/sunset.
- x86_64 is the only package architecture planned for this candidate. No
  aarch64 or universal-build claim is made.

## Verification ledger

Not yet executed after the final implementation-gap closure. The final report
will replace this section with exact commands, compiler warnings, per-suite
pass/fail/skip totals, sanitizer outcome, Mac CI result, install manifest,
source SHA, package filename and SHA-256. Compilation during implementation is
not counted as test acceptance.

## Environment and hardware blockers

The implementation container has no Wayland compositor, Omarchy/Hyprland,
tray host, graphical systemd user manager, DRM/backlight hardware, physical
display, suspend authority, or alternate connectors/modes. Therefore nested or
real compositor rendering, tray churn on Quickshell, UWSM login/logout,
sleep/wake, physical Backlight Lock, HDR/ICC/direct scanout/cursor/capture,
endurance measurements, and every H01–H13 row remain
`BLOCKED_ENVIRONMENT` here regardless of future simulated-test results.

See `PLATFORM_PROBE.md`, `RECOVERY.md`, and `HARDWARE_ACCEPTANCE.md` for the
probe, cleanup contract and exact target procedures.
