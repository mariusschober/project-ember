# Ember for Omarchy — parity contract and acceptance tests

Status at planning commit: **NOT IMPLEMENTED; NO LINUX TESTS EXECUTED**. This file defines future acceptance, not completed work. Read with [PLAN.md](PLAN.md) and [MAC_REVIEW.md](MAC_REVIEW.md).

## 1. Feature contract

"Required" means implement and test. "Capability-gated" means implement the adapter and honest unavailable states; do not remove the feature merely because the development container lacks hardware. A feature that cannot be verified on a target remains unverified, not passed. Platform adaptations below are deliberate and must be documented in the shipped Linux README.

| ID | Mac behavior | Linux contract | Level |
|---|---|---|---|
| F01 | Menu-bar resident, no ordinary main application window | Native StatusNotifierItem tray presence; small native settings window only when requested. Closing it does not quit. Works with current Omarchy Quickshell without replacing/configuring the shell. | Required |
| F02 | Fresh install is off | Warmth 0.62, software brightness 0.75; filter, schedule, backlight and login all off. Initial launch and read-only diagnostics perform no display/backlight writes and do not bind an owning CTM manager. | Required |
| F03 | Master on/off, saved preferences | On/off preserves warmth and brightness. Ordinary Off restores hardware and releases Ember's color control. Relaunch preserves intentional settings after safe recovery. | Required |
| F04 | Neutral, Evening, Pure Red | Warmth 0, 0.62, 1 respectively; preset selection changes warmth only. Does not silently switch on. Custom warmth removes preset highlight. | Required |
| F05 | Full warmth continuum | Port exact color-function coefficients and smoothstep behavior. Neutral exact `(1,1,1)`; endpoint exact `(1,0,0)`. Clearly distinguish intermediate red tail from the endpoint. | Required |
| F06 | 10–100% software dimming | Independent brightness multiplies each gain. Neutral plus 75% remains dimmed. No compounding and no hidden hardware brightness changes. Account for CTM fixed-point quantization. | Required |
| F07 | Shared profile on compatible monitors | Stage all current intended outputs in every CTM commit. Hotplug/reconfiguration does not intentionally reset survivors to neutral. Unsupported/unknown targets are not misreported as verified. | Required |
| F08 | Left click opens controls or toggles; right click opens controls | Default primary click opens settings; optional primary toggle. Secondary click must never toggle: expose the native control menu with Settings, Off/On, Restore, and Quit. Directly opening the settings window on secondary activation is welcome where supported, not a reason to replace the host. | Required, native menu adaptation |
| F09 | Backlight Lock on compatible built-in display | Real optional built-in LCD brightness hold at maximum, only with unambiguous mapping, captured baseline, permission, verification, and independent crash cleanup. External monitors/keyboard lights/OLED without a controllable backlight are excluded. | Required adapter, capability-gated engagement |
| F10 | Capture/restore automatic brightness when supported | Only manage a known provider whose prior state can be read, journaled and restored. Do not fabricate a generic Linux auto-brightness switch. Unknown competing control is reported; suspend hold on repeated drift. | Capability-gated |
| F11 | Local sunrise/sunset | Fully offline schedule from explicitly entered approximate coordinates, rounded to 0.1°. Expose next boundary, active override, and missing-location state. Optional system location discovery may be added behind consent; it is not required for the offline path. | Required schedule; location acquisition adapted |
| F12 | Schedule also enables login | Explain before/with enabling. Reconcile to current solar state once coordinates are valid. Login failure means session-only warning, not a fake enabled switch. Turning schedule off leaves filter unchanged. | Required |
| F13 | Manual solar override | Explicit on/off lasts until next boundary. Resume, clock changes, and application restart cannot lose a still-valid override or preserve an expired one indefinitely. | Required |
| F14 | Launch at login | One tested graphical-session startup path, actual registered state reflected in UI, no duplicate instances. Never start a graphical app as root. | Required |
| F15 | Safe restore/recovery | CTM ownership is released, not a fabricated Mac gamma restore. Hardware baselines are independently restored and verified. Pending, corrupt and failed recovery remain visible; future schemas fail closed. | Required, backend-specific semantics |
| F16 | Readback-driven Mac status | Separate desired state, protocol ownership/request processing, and unavailable optical/readback evidence. Never claim that Wayland sync verified displayed color. | Required, explicit evidence limitation |
| F17 | Sleep/wake/topology resilience | Restore hardware before releasing software dim on ordinary suspension; bounded sleep handling; resume with current topology/time. Screen lock is not automatically treated as sleep. | Required |
| F18 | Local diagnostics, retry, export, restore | Bounded logs, sanitized Copy and Export, read-only doctor, manual retry, emergency restore with automation pause. Emergency path works without a visible settings window. | Required |
| F19 | Simple local product with no accounts/network | No telemetry, cloud, updater, network geocoder, browser engine or account. Preserve version and author credit. A user-clicked author link may open the system browser. | Required |
| F20 | Mac visual style, Apple signing | Do not reproduce artwork, haptics, fixed 390pt layout or Apple packaging on Linux. Deliver Arch packaging and native controls. No public release/AUR publication or license decision during implementation. | Deliberately not ported |

An architecture that only wraps hyprsunset's temperature setting does not satisfy F05/F06. A tinted overlay is not an acceptable substitute for output color control. A functioning settings window with a mocked display backend does not satisfy F03/F07.

## 2. Evidence taxonomy

Every reported test must include its **environment, command/procedure, expected outcome, actual outcome, exit status where applicable, and evidence path**. Use these statuses consistently:

- `PASS`: the specified check was actually executed and met its assertions.
- `FAIL`: it was executed and violated an assertion.
- `NOT_RUN`: the check has not been executed.
- `BLOCKED_ENVIRONMENT`: a named dependency/device/session/permission is absent.
- `NOT_APPLICABLE`: a deliberate supported-scope condition excludes the case; state why.

Do not convert `NOT_RUN` or `BLOCKED_ENVIRONMENT` to PASS because related mocks passed. Separate **unit**, **simulated protocol**, **nested compositor**, **real Omarchy desktop**, and **physical hardware** evidence. A screenshot may show UI or captured content but does not prove hardware backlight restoration or physical spectral output. The last is outside product claims altogether.

## 3. Deterministic test groups

### U1 — Settings, presets and numerical parity

Cover all defaults and missing optional keys, migration of the Linux schema, invalid JSON, unknown future schema, out-of-range values, NaN/infinity, malformed IPC values, and very large inputs. Distinguish rejection at the input boundary from clamping a finite slider value. Recovery corruption must not be processed as fresh-install state.

Create reference fixtures for warmth `0, 0.01, 0.2, 0.62, 0.819999, 0.82, 0.820001, 0.9, 0.99, 1`, each at brightness `0.1, 0.75, 1`. Preserve reference-generation provenance. Prefer fixtures generated by the unchanged Swift core in a temporary test harness; do not derive both expected and actual values from the same new C++ function. If Swift cannot be run, mark independent parity generation outstanding and use analytical endpoint/property tests meanwhile.

For unquantized channel gains, target absolute difference at most `1e-5` against the Swift Float outputs, or document a tighter/looser justified tolerance before changing it. For transport, test the actual `wl_fixed` conversion and reconstruction; error must be bounded by one fixed-point step (`1/256`), not Mac gamma-readback tolerance. The exact zero and identity endpoints must remain exact. Test all off-diagonal elements equal zero, finite matrix entries, no negative values, and repeated slider updates derived from settings rather than the previously applied matrix.

### U2 — Coordinator and concurrency

Use an injected clock, scheduler, output registry, color backend, hardware backend, journal, login adapter, and diagnostic sink. Test latest-intent-wins when Off, Restore or Quit arrives during acquisition, commit, delayed sync, slider coalescing or retry. A stale callback must not re-enable, raise brightness, resurrect a removed output, clear a newer error, or publish an old success.

Test duplicate launch, a second client commanding the same instance, absence of outputs, output removal during commit, repeated identical events, application shutdown mid-write, and a crash-recovery safety latch. Simulate 1,000 deterministic randomized event sequences with a recorded seed and invariants checked after every event. This is not a replacement for targeted regression tests.

### U3 — Solar behavior

Use fixed dates and named timezones, not the developer machine's local defaults. Include equinox/solstice, leap year, Europe/Berlin spring-forward and fall-back days, Atlantic/Canary, a negative UTC offset, a fractional-hour offset, dates near the international date line, polar day/night and latitude endpoints. Assert finite results, ordering, day/night transitions, and bounded forward search. Treat source edge-case failures as bugs to explain, not behavior to replicate unquestioningly.

Test enable during day/night, no coordinates, `(0,0)` as a valid location, invalid coordinates, coordinate rounding including negative half steps, scheduled boundary while a panel is closed, sleep across multiple boundaries, timezone/clock jumps, valid and expired overrides across restart, schedule disable leaving state unchanged, and a periodic re-evaluation during polar periods with no imminent event.

Emergency Restore pauses automation persistently until explicit user action. Normal Off creates only the usual next-boundary override. Changing location explicitly clears/reconciles an old-location override with a visible explanation; timezone-only display changes must not arbitrarily extend a persisted absolute expiry.

### U4 — Recovery and backlight fault injection

Simulate failure at each boundary: baseline read, journal directory creation, temp creation, write, fsync, rename, directory fsync, hardware write, readback, restore, journal update, clear, and cleanup start. No maximum-brightness mutation may precede durable baseline save. No failed hardware restore may be deleted because a color operation succeeded.

Test ambiguous device mapping, device path changes, conflicting identical devices, no backlight, keyboard LED only, max value zero, permission denied, provider disappearance, stale boot/session journal, user-changed brightness after the process died, future schema and corrupted primary/backup records. Recovery must not commandeer an unrelated device or blindly overwrite a legitimate later user change.

Verify ordinary restore order, independent attempts after partial failures, preference versus engagement, bounded drift correction, and safe suspension of the hold on repeated interference. Test cleanup idempotence and that a standalone recovery process does not instantiate a GUI or acquire CTM ownership.

### U5 — Presentation and privacy

Off, enabling, compositor-controlled, blocked, unsupported, disconnected, degraded, pending hardware recovery, paused automation and session-only schedule must render truthful labels/actions. Test a desired-on state with blocked ownership never shows ordinary success. No raw display serial, coordinate, home path, environment dump or user content appears in default copied/exported diagnostics.

### U6 — Login and installation state

Use fake systemd/config roots. Enabling twice is idempotent, disabling preserves user settings and does not terminate the currently running app, startup never duplicates an instance, and an API failure is visible. Uninstall never removes user-owned shell configuration or deletes unresolved hardware recovery without warning. Read-only commands must not enable services or write config.

## 4. Protocol and desktop integration tests

### I1 — Real wire-protocol fake server

Use a minimal `libwayland-server` test compositor implementation of the inspected CTM XML, or an equivalently inspectable harness that exercises the real generated client messages. A fake C++ backend alone is insufficient here.

Assert registry-only probe performs no CTM bind, off startup performs no color writes, missing manager/version 1 is rejected, version-2 blocked is handled before success, complete output maps precede each commit, and 24.8 values match numerical fixtures. Model reset-on-destruction, omission-reset semantics, delayed sync, removed globals, abrupt disconnect, unavailable output objects, second-owner attempts and protocol error. A blocked client's destruction must not reset the real owner's state.

Confirm a sync result is stored as `request_processed`, never `pixels_verified`. Confirm reconnection creates new object/generation identities and does not reuse stale proxies. Verify input/output processing remains responsive when the compositor stops responding.

### I2 — Tray/IPC integration

Test on a private D-Bus session: one controller owner, command routing, invalid arguments, service unavailable, snapshot updates, watcher absence and later appearance. On the actual Omarchy host, test primary open, primary toggle, secondary controls without toggling, duplicate launch, window close-to-tray, and hidden tray drawer behavior. Native context menus must not open two panels or double-toggle.

A missing tray must not make recovery inaccessible: `project-ember settings`, `status`, `restore`, and `quit` remain usable. Do not restart Omarchy's entire shell just to simulate a tray outage; test watcher churn in isolation.

### I3 — Supervision and failure cleanup

In an isolated user-service test environment, run the real service with fake hardware. Exercise successful exit, SIGTERM, SIGKILL, failed startup, watchdog failure if implemented, restart limits, explicit Quit, and unresolved recovery. Show that `ExecStopPost` or the documented independent equivalent performs cleanup even when the GUI process cannot.

Use real filesystem durability and process boundaries in this group. A same-process mocked destructor does not demonstrate crash recovery. Normal Quit must not be interpreted as a crash that immediately relaunches. A genuine crash should recover hardware, restart in safe/paused state with an explanation, and require explicit reactivation; do not resume full-backlight output in an uncontrolled crash loop.

### I4 — Packaging

Build from a clean checkout in an Arch build environment as a non-root build user. Verify dependencies, bundled protocol notices, installed paths, desktop file, icons, Qt Wayland platform plugin, user service syntax and uninstall instructions. Installation must not automatically enable filtering or Backlight Lock. Add a Linux CI workflow without weakening the Mac workflow. Capture artifact hashes and exact source commit. A package built for x86_64 is not evidence of a tested aarch64 artifact.

## 5. Real-target acceptance

Record the actual Omarchy, Hyprland, Quickshell/tray, Qt, kernel and GPU driver versions; CPU architecture; connection topology; relevant color/HDR modes; backlight driver and permission state. Sanitize shared evidence. Do not infer Apple Silicon from the word MacBook or infer the installed version from the newest upstream release.

| Test | Procedure and required outcome |
|---|---|
| H01 Fresh launch | On clean application config, settings visible and everything off; no color change or hardware write. Close/reopen settings and launch a second instance. |
| H02 Basic profile | Built-in only and external only: Neutral, Evening, intermediate warmth, Pure Red, brightness 10/75/100%; ordinary Off restores Ember-free control. Distinguish visible confirmation from protocol-only evidence. |
| H03 Multiple outputs | Built-in plus HDMI and, when available, USB-C/DisplayPort. Change settings; all intended outputs follow, no fabricated verified count. |
| H04 Hotplug | 20 disconnect/reconnect cycles on each available connector type while enabled; include dragging a slider. Survivors do not undergo an Ember-initiated neutral reset. Record any visible flash and its timing; do not dismiss it as OS behavior without evidence. |
| H05 Output modes | Power-cycle an external display, change resolution/refresh/scale/rotation, test mirrors and clamshell if supported. No stale object use or incorrect hardware mapping. |
| H06 Conflicts | Start with Omarchy night light/hyprsunset owning CTM, including a neutral profile. Ember shows conflict, changes nothing, and succeeds after explicit user release and Retry. Also test a competitor launched while Ember owns control. |
| H07 Recovery | Normal off, explicit restore, quit, SIGTERM and deliberate SIGKILL on a designated test session. Show hardware values before/during/after where applicable; journal cleared only after appropriate evidence. |
| H08 Sleep and resume | Ten suspend/resume cycles, at least one crossing a scheduled boundary or simulated equivalent; no indefinite sleep inhibition or permanently stuck brightness. Ordinary screen lock retains intended evening filtering. |
| H09 Backlight | When capability is real: capture original brightness, activate hold, adjust software dim, operate brightness keys/Omarchy brightness controls, disable hold, quit and crash. No external/keyboard-light mutation. Unsupported target reports unavailable. |
| H10 Scheduling | Manual approximate location, sunrise/sunset behavior, manual override, schedule off, explicit emergency pause, login toggle, full logout/login. No network access needed. |
| H11 UI | Mouse, keyboard, dark/light theme, fractional scaling, different bar edges, 1366×768 usable area. All controls/recovery reachable; do not sacrifice usability to enforce a fixed-size no-scroll layout. |
| H12 Rendering modes | Separately test HDR, ICC/color management, fullscreen/direct scanout, hardware/software cursor, screenshots and screen recording. Report supported, limited or unverified cases. Do not silently turn off system color features to obtain a pass. |
| H13 Endurance | Eight-hour active/idle run with settings closed, schedule and topology activity as available. No unbounded log/journal growth, descriptor leak, busy polling, repeated writes, or incorrect status. Measure CPU/RSS/wakeups and disclose the measurement interval. |

Unavailable extra displays or modes do not block writing/testing the implementation, but they do block claiming the corresponding hardware acceptance. The ordinary SDR color-control path must pass on at least one real supported Omarchy target before calling the application validated for daily use.

## 6. Final implementation report

Create `linux/docs/IMPLEMENTATION_REPORT.md` with: source and final commit; environment inventory; completed feature IDs with implementation/test pointers; exact commands and results; packages and hashes; known deviations; unresolved defects; unexecuted hardware rows; and concise install/restore/uninstall commands. Distinguish **implemented**, **simulated-tested**, **desktop-tested**, and **hardware-accepted**.

The planning branch contains no executable Linux application. Luna Max must not declare completion merely by adding another plan, an empty adapter, a disabled permanently-unsupported feature, a successful compilation, or screenshots of mocked success. After implementation and all feasible verification, push reviewable checkpoints to this same branch and stop for human review. Do not merge or deploy.
