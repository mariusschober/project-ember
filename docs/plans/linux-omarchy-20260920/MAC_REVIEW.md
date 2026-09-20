# Ember for Omarchy — source review and platform decisions

Reviewed: 2026-09-20. This is a source-based planning review, not a claim that the Mac application or a Linux prototype was run.

## Baseline and authority

Repository: `mariusschober/project-ember`.

- Reviewed `main` commit: `41973930103c5c12c5c04715f4a1943ff759628d`.
- Root tree: `b46195b62135658ae45b54a7261a0c872a9abbef`.
- Implementation branch: `feat/linux-omarchy-native-20260920`, created from that commit.
- Product baseline: **0.4.0**, explicitly a reliability/interaction release candidate, not a hardware-certified 1.0.
- Governing Linux requirements: [PLAN.md](PLAN.md), with [PARITY_AND_TESTS.md](PARITY_AND_TESTS.md).

The user requests the same useful functionality in a **reliable, very simple native menu-bar/settings application**, not reproduction of the custom Mac artwork. The Linux build must coexist with the Mac source without replacing it. `GOAL.md` explicitly describes historical 0.2 criteria; it is not the current authority when it conflicts with the 0.4.0 implementation.

## What the application actually does

Ember is a display controller with a tray interface, not simply a night-light settings panel. Its Mac implementation has two separate output paths: CoreGraphics display-transfer tables for color/software dimming, and an optional private DisplayServices path for the built-in hardware backlight. CoreLocation supplies approximate coordinates; ServiceManagement supplies login registration. Those APIs are platform-specific, while the color calculations, scheduling rules, user intentions, and safety principles are portable.

A fresh installation stores warmth **0.62**, software brightness **0.75**, and defaults filter, Backlight Lock, Sun schedule, and launch-at-login to **off**. Primary click defaults to opening controls. Changing a slider or selecting a preset while off changes saved settings without activating the display filter. Presets change warmth only: Neutral = 0, Evening = 0.62, Pure Red = 1. Neutral at 75% software brightness is still dimmed; it is not equivalent to turning Ember off.

`ColorCurve.gains(forWarmth:)` maps warmth 0–0.82 through a smoothstep temperature curve from 6500 to 2000 K. Above 0.82 it interpolates toward RGB gains `(1, 0, 0)`. This final interval is not a physical color-temperature scale. `GammaTable.applying` multiplies each sample of the immutable original channel table by the channel gain and software brightness. It does not repeatedly transform the current table. Exact numeric behavior belongs to the source, not to rounded UI temperature labels.

The Mac coordinator distinguishes requested state from verified display state. It captures identity-matched baselines before writes, maintains pending restores for disconnected displays, rejects ambiguous restoration targets, coalesces topology changes by generation, and tries not to restore unchanged displays when a peer is unplugged. It reads back CoreGraphics tables after applying them. That readback capability must not be invented in a Linux backend that lacks it.

Sun scheduling activates after sunset and restores at sunrise. Enabling the schedule attempts to enable launch-at-login and tells the user about that coupling. A failed login registration permits session-only scheduling with a warning. Manual on/off overrides scheduling until the next solar boundary. Disabling the schedule leaves the current filter state unchanged. The calculator handles local dates, timezone offsets, leap years, and polar conditions rather than assuming every day is 86,400 elapsed seconds.

Backlight Lock is a preference distinct from engagement. On compatible built-in displays it captures brightness and any readable automatic-brightness state, attempts full hardware brightness, and relies on software dimming for apparent brightness. Ordinary off, sunrise, sleep, and termination restore hardware but preserve the preference. An explicit Backlight Lock off or emergency reset clears the preference. There is no external-monitor DDC/CI feature to port.

The menu has configurable primary-click behavior and a secondary-click route to controls. Diagnostics expose retry, emergency restore, and local copy/export. Custom orbs, gradients, haptics, fixed Mac popover dimensions, and AppKit drawing classes are not functional requirements for Linux.

## Source manifest and review coverage

All repository entries below refer to the pinned baseline above. [Browse that immutable tree](https://github.com/mariusschober/project-ember/tree/41973930103c5c12c5c04715f4a1943ff759628d). The implementation agent must read complete relevant files before coding; a planning review of selected coordinator ranges is not a complete application audit.

| Source | Reviewed scope / importance |
|---|---|
| `README.md` | Entire file: 0.4.0 behavior, defaults, privacy, recovery, limitations, license decision. |
| `GOAL.md` | Entire file: historical scope and explicitly superseded status. |
| `docs/SYSTEM_DESIGN.md` | Entire file: architecture and intended safety invariants. |
| `docs/TEST_PLAN.md` | Entire file: reported previous tests versus outstanding hardware acceptance. |
| `Package.swift` | Entire file: Swift 6, Mac target/frameworks, core/check/test targets. |
| `.github/workflows/ci.yml` | Entire file: macOS-15 build/tests; pushes currently only target main. |
| `Sources/EmberCore/Models.swift` | Entire file: defaults, preset values, override expiry, identity, journal models, errors. |
| `Sources/EmberCore/ColorCurve.swift` | Entire file: temperature conversion, normalization, red endpoint. |
| `Sources/EmberCore/GammaTable.swift` | Entire file: baseline multiplication, interpolation, verification delta. |
| `Sources/EmberCore/SolarCalculator.swift` | Entire file: solar model, date handling, polar forward search. |
| `Sources/EmberCore/Persistence.swift` | Entire file: settings persistence, typed journal load outcomes, backup/quarantine. |
| `Sources/ProjectEmber/AppDelegate.swift` | Entire file: status item, click routing, lifecycle observers, visual-QA wiring. |
| `Sources/ProjectEmber/SolarScheduleController.swift` | Entire file: opt-in location, cache, timestamp validation, boundary/retry timers. |
| `Sources/ProjectEmber/DisplayCoordinator.swift` | Source lines 1–1100: snapshots, user intents, schedule/login coupling, sleep/wake, reset, activation, restoration, and main reconciliation paths. Remaining coordinator helpers require implementation-agent review. |
| `Sources/ProjectEmber/SystemControllers.swift` | Source lines 1–240 and 270–end: enumeration, capture/readback/identity resolution and built-in backlight controller. Review intervening gamma-write implementation before deriving additional claims. |
| `Sources/ProjectEmber/ControlPanelViewController.swift` | Source lines 1–240: user-facing controls and layout/action wiring. Remaining rendering/action helpers require review. |
| `Tests/EmberCoreTests/EmberCoreTests.swift` | Retrieved test excerpt, not the entire file: topology, recovery, backlight and presentation tests. Several are pure-model rather than coordinator integration tests. |

Also read before implementation: `Sources/EmberCore/{DisplayProtocols,DisplayStateMachine,DisplayTopology,PolicyHelpers,Presentation,RecoverySafety,DiagnosticLog,AppVersion}.swift`, the complete `EmberCoreChecks.swift`, `ProjectEmberMain.swift` test entry points, `DiagnosticsWindowController.swift`, `LaunchAtLoginController.swift`, `AUDIT_FIXES.md`, `CHANGELOG.md`, `RELEASE_NOTES.md`, `SECURITY.md`, applicable repository instructions, and build/release scripts. These were discovered in the tree but are not represented here as fully reviewed source.

Useful immutable anchors:

- [Color curve](https://github.com/mariusschober/project-ember/blob/41973930103c5c12c5c04715f4a1943ff759628d/Sources/EmberCore/ColorCurve.swift), blob `01d97e534414ad78239a1432c1347d6426de7c48`.
- [Settings and identity models](https://github.com/mariusschober/project-ember/blob/41973930103c5c12c5c04715f4a1943ff759628d/Sources/EmberCore/Models.swift), blob `c1acc948e129ad5ddec72e2a891460cffaa6479b`.
- [Coordinator](https://github.com/mariusschober/project-ember/blob/41973930103c5c12c5c04715f4a1943ff759628d/Sources/ProjectEmber/DisplayCoordinator.swift), blob `5cc07ad4ec793064b50fa8456b6eaecad387b9ab`.
- [Mac system controllers](https://github.com/mariusschober/project-ember/blob/41973930103c5c12c5c04715f4a1943ff759628d/Sources/ProjectEmber/SystemControllers.swift), blob `baf50bb835930b44d625bec7239e5e1c26dd178c`.

## Do not reproduce these risks blindly

These are source-level observations and test requirements, not newly reproduced Mac failures.

**Recovery outcomes are not interchangeable.** In `resetDisplayNow`, a failed restoration can trigger ColorSync fallback and pruning through `isBaselinePresent`. That predicate checks gamma, not saved hardware brightness/automatic-brightness restoration. A hardware-failed entry whose gamma matches could therefore be discarded. Linux must track each recoverable field independently and never delete hardware evidence merely because color reset succeeded.

**Restoration order matters.** `restoreEntriesVerified` restores gamma before hardware and reaches hardware restoration only after gamma succeeds. Linux should attempt hardware restoration independently and, on ordinary shutdown, lower the hardware brightness before removing software dimming. Otherwise a full-backlight screen can become suddenly bright. A process crash can still create a short reset-to-cleanup interval; documentation must not promise zero flash.

**Emergency reset must beat automation.** The reviewed reset method clears enabled/backlight state but does not explicitly create a manual solar override or disarm the schedule. The Linux emergency action must set a persistent automation-paused safety latch until the user explicitly resumes. Ordinary Off retains the existing next-boundary override semantics.

**Tests need to cross the integration boundary.** Some retrieved tests assert a planner generation or manipulate a local array rather than exercising failed writes and recovery deletion in the real coordinator. Port their intended invariant, then add fault-injected coordinator/protocol/persistence tests. The Mac test plan records past hardware checks; that historical report is not Linux evidence and was not rerun during this review.

**A settings label is not optical evidence.** The Mac temperature description calls the entire final warmth tail Pure Red, although green reaches zero only at the endpoint. Linux should label the intermediate tail as progression toward Pure Red, reserving the endpoint claim for the actual intended endpoint. Fixed-point transport can further quantize very small gains.

## Current Omarchy findings

The upstream repository formerly at `basecamp/omarchy` now resolves to **`omacom/omarchy`**, with default branch `quattro`. The latest release returned by GitHub during this review was **v4.0.4, published 2026-09-15**. This does not establish the version installed on the user's machine.

Its [versioned top-bar manual](https://github.com/omacom/omarchy/blob/v4.0.4/manual/05-the-top-bar.md) describes a **Quickshell** shell with a system tray, not the older Waybar default. Quickshell also owns notifications and the lock screen. Do not kill or replace it as a casual tray workaround. Its `~/.config/omarchy/shell.json` becomes user-owned canonical configuration after customization; do not overwrite it to install Ember. A hidden tray drawer is not evidence that Ember failed to register.

The inspected `config/hypr` uses **Lua configuration**, including `autostart.lua` and `hyprland.lua`. The [hyprsunset configuration](https://github.com/omacom/omarchy/blob/quattro/config/hypr/hyprsunset.conf) includes an identity profile and documents optional `o.launch_on_start("hyprsunset")`. A neutral-looking night-light process may still own the color-control protocol. Do not infer availability from the absence of a visible tint. Older Omarchy installations can differ; the target probe, not a hardcoded version assumption, chooses startup integration.

## Display backend decision and its limits

Use the compositor's **Hyprland CTM protocol**, directly, as the primary backend. Do not approximate Ember by repeatedly invoking a temperature-only command. Preserve the Ember gain function, then submit a diagonal color matrix multiplied by software brightness. This expresses the same control intent, including a red-channel-only endpoint, without a colored overlay window or a compositor-plugin ABI dependency.

Primary references inspected:

- [Protocol XML](https://github.com/hyprwm/hyprland-protocols/blob/main/protocols/hyprland-ctm-control-v1.xml), reviewed blob `6cb791c1710cdedfc59b3d48fd91cca997d1eabd`; [exact blob API](https://api.github.com/repos/hyprwm/hyprland-protocols/git/blobs/6cb791c1710cdedfc59b3d48fd91cca997d1eabd).
- [Compositor implementation](https://github.com/hyprwm/Hyprland/blob/main/src/protocols/CTMControl.cpp), reviewed blob `b8d8488f106a01a4dedfa5b3e66838154236ee41`; [exact blob API](https://api.github.com/repos/hyprwm/Hyprland/git/blobs/b8d8488f106a01a4dedfa5b3e66838154236ee41).
- [Official hyprsunset documentation](https://wiki.hypr.land/Hypr-Ecosystem/hyprsunset/).

The protocol name contains `v1`, but the inspected manager interface is **version 2**. Version 2 provides `blocked` when another manager owns control. The initial supported backend must require that interface version; version-1 silent conflict handling is not equivalent.

A commit applies the staged matrix map, with unspecified outputs reset to identity. Therefore every commit must stage the complete current live-output map, preserving all survivor matrices. Destroying an owning manager resets CTMs to identity. Destroying a blocked manager is ignored by the inspected compositor implementation. Merely binding an otherwise unused owning manager and destroying it is consequently not a read-only capability probe.

There is **no matrix/pixel readback** or per-output applied acknowledgement in this protocol. A Wayland sync confirms request processing, not displayed pixels, HDR behavior, calibration preservation, or the end of a compositor animation. The inspected compositor can animate CTM changes. The UI and diagnostics must disclose the evidence level and avoid fake verified-display counts.

CTM reset-to-identity is not restoration of arbitrary pre-existing custom CTMs. Exclusive ownership/conflict handling is essential; do not synthesize a Mac gamma baseline or replay its recovery files. The same RGB coefficients at different stages of a display pipeline do not guarantee identical physical output. HDR, ICC/color-management behavior, direct scanout, cursor treatment, and capture behavior are acceptance questions on the actual target.

## Other implementation references

- [Qt QSystemTrayIcon](https://doc.qt.io/qt-6/qsystemtrayicon.html): Linux StatusNotifierItem support, activation reasons, tray availability, and delayed host registration. Actual secondary-click delivery must be tested with the Omarchy host.
- [Linux backlight documentation](https://docs.kernel.org/gpu/backlight.html): requested brightness, maximum, actual brightness, device/driver semantics. Writable sysfs alone does not prove a correctly identified built-in LCD or reliable restoration.
- [systemd service manual](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html): supervision and cleanup lifecycle; verify exact unit behavior on the target.
- [systemd inhibitor locks](https://systemd.io/INHIBITOR_LOCKS/): bounded delay inhibition and PrepareForSleep handling. Never block sleep indefinitely.

The core application requires no account, network service, external geocoding, or AI. Manual approximate coordinates provide a dependable offline Sun schedule. Optional automatic location is a capability-dependent enhancement, not an excuse to block scheduling. The repository has **no explicit license**; preserve that fact and third-party notices, and do not choose a public distribution license on the owner's behalf.
