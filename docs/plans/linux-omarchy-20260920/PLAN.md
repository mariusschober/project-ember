# PLAN — implement native Project Ember for Omarchy

**Executor:** Luna Max. **Planning date:** 2026-09-20. **Status:** ready for implementation; this planning commit does not contain a Linux app.

Repository: `https://github.com/mariusschober/project-ember`

Work branch: `feat/linux-omarchy-native-20260920`

Reviewed Mac baseline: `41973930103c5c12c5c04715f4a1943ff759628d` (tree `b46195b62135658ae45b54a7261a0c872a9abbef`).

Read [MAC_REVIEW.md](MAC_REVIEW.md) and [PARITY_AND_TESTS.md](PARITY_AND_TESTS.md) completely. They supply source evidence, explicit platform adaptations, and acceptance criteria. Follow applicable repository instructions. This document governs the Linux implementation, not changes to the existing Mac product.

## 1. Mission and non-negotiable boundaries

Build a **small, native, reliable tray/settings application** that provides Ember's warmth continuum, Pure Red, independent software dimming, shared multi-output control, optional built-in Backlight Lock, Sun scheduling, login launch, diagnostics and safe restoration on Omarchy Linux.

The user explicitly does not require a beautiful UI. Use ordinary controls. Invest in correct state, fast access, readable errors and recovery, not a recreation of the Mac orb, motion or translucent panels. Native here means a Linux executable using a native toolkit and compositor interfaces, not a browser window wrapped in a desktop shell.

Implement, package, and verify all feasible work in this branch. Push small reviewable checkpoints. Do not merge, force-push, publish a release, submit to the AUR, modify remote production systems, or deploy to the user's desktop without a separately designated test/install context. Do not change the Mac source as a shortcut to make a Linux build pass. Do not silently narrow the functionality to a temperature slider.

Record unavailable hardware tests honestly and continue with independent implementation/testing. A cloud environment without a Wayland session is a reason to mark specific acceptance checks blocked, not a reason to fabricate success or abandon the rest of the build.

## 2. Architecture decision

### 2.1 Chosen stack

Use **C++20, CMake, Qt 6 Widgets/Core/DBus, and libwayland-client**. Generate the small CTM binding using `wayland-scanner` from a pinned, locally vendored protocol XML with its original license notice. Use Qt Test/CTest and a small libwayland-server harness for tests. Native Arch packages supply Qt, including its Wayland platform support. Do not use private Qt APIs.

Use `QSystemTrayIcon` first. Its standard StatusNotifierItem path avoids coupling the application to one particular Omarchy shell release. Current upstream Omarchy 4 uses Quickshell; older installations may use Waybar. Do not write a Quickshell plugin, replace the shell, or require a Waybar custom module. Verify actual tray activation semantics before doing any custom D-Bus work. A native context menu on right click, with a direct Settings action, is an acceptable Linux adaptation.

Port the portable domain behavior into a small testable core. Do not make Swift a runtime dependency and do not bind AppKit/CoreGraphics/private DisplayServices into Linux. Keep Swift as a reference implementation for numerical fixtures, not as the new GUI architecture.

No Electron, Tauri, webview, overlay window, global screen shader installation, XRandR/XWayland workaround, display-server plugin ABI, external DDC/CI feature, or background shell-script loop. Do not introduce networking, accounts, AI, analytics, an updater or a cross-platform application framework of our own.

A materially better implementation choice requires a short evidence-backed decision note and proof that it preserves all acceptance criteria. Avoid a speculative framework comparison once the chosen native path is working.

### 2.2 Proposed repository layout

Use this as a responsibility map, not a requirement to create one class for every filename:

```text
linux/
  CMakeLists.txt
  README.md
  src/
    main.cpp
    core/          # settings, gains/matrix, solar, reducer/coordinator contracts
    platform/      # Wayland CTM, backlight, systemd/login, lifecycle, persistence
    ui/            # native tray, one settings dialog, diagnostics
    ipc/           # bounded local D-Bus command/snapshot interface
  protocols/       # pinned XML plus provenance/license notice
  tests/
    unit/
    integration/   # wire-protocol server, D-Bus and process/recovery tests
    fixtures/      # reference data with generator provenance
  packaging/
    arch/PKGBUILD
    app.projectember.Ember.desktop
    project-ember.service
    icons/
  scripts/         # clean build/check, opt-in hardware checks, install helpers
  docs/
    PLATFORM_PROBE.md
    IMPLEMENTATION_REPORT.md
    HARDWARE_ACCEPTANCE.md
    RECOVERY.md
.github/workflows/linux.yml
```

Use executable/CLI name **`project-ember`** and user service **`project-ember.service`**. Application identity should be stable, such as `app.projectember.Ember`. Preserve existing root documentation; add a short Linux entry only when usable build/install instructions exist.

## 3. Core contract and state ownership

One coordinator serializes all user intentions and runtime events. Sliders, tray actions, CLI, schedule and lifecycle adapters must not write displays independently. Keep immutable desired settings separate from a runtime snapshot containing operation state, backend capability, ownership, requested/processed generation, output targets, errors, recovery state, solar boundary/override and backlight engagement.

Minimum runtime states: Off, Enabling, CompositorControlled, Reconciling, Restoring, Suspended, Blocked/Unsupported and Degraded. A desired-on flag does not mean a display is controlled. A processed Wayland request does not mean pixels were verified. Diagnostics must distinguish `request_processed` from unavailable readback/optical evidence. User-facing wording can be concise: `On — compositor-controlled`, `Blocked by another color controller`, or `Hardware restore needs attention`.

Use a monotonically increasing operation/topology generation. Every asynchronous callback and delayed task checks both generation and current desired intent before mutation or publication. Restore/Off/Quit invalidate pending enable, slider and retry work. Debounce writes during slider movement to a bounded rate (initial target 20–30 updates/second); always apply the last value. Persist settings after a short debounce and flush at orderly shutdown. No continuous animation or periodic color writes when stable.

`QCoreApplication`-only commands must be parsed before constructing any GUI or display-mutating object. Suggested interface:

```text
project-ember                    # launch managed resident app; existing instance is reused
project-ember settings
project-ember on | off | toggle
project-ember preset neutral|evening|pure-red
project-ember warmth <0..100>
project-ember brightness <10..100>
project-ember status --json
project-ember doctor --json
project-ember restore
project-ember quit
```

`run` and `recover-hardware` may be internal service subcommands. Settings/explicit launch may start the resident service. Read-only status/doctor never start the controller, enable login, bind CTM ownership, alter brightness, or repair settings. Mutating commands with no running instance should fail clearly or explicitly launch through the documented managed route; never spawn an unnoticed second controller.

Use a bounded same-user D-Bus interface with typed/validated methods and request IDs. Reject unknown or oversized requests. No arbitrary command execution, file paths or environment injection through IPC. One supported active graphical session per user is sufficient for this release; detect a conflicting session rather than accidentally controlling its compositor. Tests use private bus names/runtime directories. Neither unit tests nor UI-preview mode may fall back to the real display backend.

## 4. Display control — the highest-risk path

### 4.1 Probe before owning

Phase 0 must record actual target architecture, Omarchy/Hyprland/tray/Qt versions, available Wayland globals, compositor session, color-controller conflicts, output metadata and backlight capabilities. Do not infer architecture or GPU from the MacBook name. No display mutation belongs in this probe.

Require advertised **`hyprland_ctm_control_manager_v1` interface version >= 2** for the initially supported backend. The protocol's name and interface version are different things. Version 2 supplies the blocked event; version 1 can silently ignore a conflicting manager. Missing or older support must be explicit Unsupported, not a green success state. Do not run as root to bypass compositor policy.

Merely enumerate the registry during an off-state probe. Do not bind a CTM manager just to discover capability: an owning manager's destruction can reset output matrices. On explicit activation, bind version 2, process initial events with a bounded asynchronous barrier, and handle `blocked` before claiming control or increasing hardware brightness.

### 4.2 Matrix construction and transport

Reimplement `ColorCurve.swift` faithfully, including its neutral special case, temperature coefficients, normalization, smoothstep at 0.82 and red tail. Compute gains from current settings, then construct:

```text
[ brightness * redGain,   0,                       0 ]
[ 0,                      brightness * greenGain,  0 ]
[ 0,                      0,                       brightness * blueGain ]
```

All components must be finite and nonnegative; brightness is 0.10–1.00. Keep the unquantized values for numerical parity tests, then convert using the real Wayland fixed-point API. Inspect/test the quantization near low brightness and the red tail. Do not change the color curve to an easier approximate hyprsunset temperature mapping.

The Mac multiplies transfer-table samples; Linux applies CTM in the compositor pipeline. This is functional, not bit-identical photometric parity. Do not claim retained arbitrary ICC/gamma baselines or identical physical brightness across platforms.

### 4.3 Connection, output and commit lifecycle

Own a **dedicated Wayland connection** separate from the Qt GUI connection. A backend protocol error must not unnecessarily destroy the settings/recovery interface. Integrate dispatch nonblockingly, using correct read/flush/cancel semantics or a tightly contained worker with queued messages. No unbounded `wl_display_roundtrip` on the UI thread. Bound timeouts and reconnect attempts, release resources deterministically, and propagate failures to the coordinator.

Track output objects by connection epoch and registry lifetime. Use names/descriptions for human-readable diagnostics, not persistent proof of physical identity. Do not use a removed proxy after reconnection. Persistent hardware recovery identity has a separate, stronger contract.

**Every CTM commit must include a complete staged map of all current intended live outputs.** The protocol resets unspecified outputs to identity. During hotplug, keep survivor matrices in that map; never do an intermediate global-neutral commit. Coalesce event storms without leaving a new controllable display unprocessed indefinitely. Do not rebuild the owning manager for every slider movement or topology event.

After a commit, an asynchronous sync may advance the processed generation. It does not prove rendered output or completion of CTM animation. Sparse health checks can examine connection/ownership/registry health; they cannot manufacture the Mac's gamma readback. Never "repair" invisible drift by continuously rewriting matrices. Backend failure moves to a truthful state and triggers appropriate hardware cleanup.

### 4.4 Conflict and release policy

When blocked, destroy only Ember's blocked manager, retain saved preferences, show a useful explanation, and offer Retry. Do not kill hyprsunset, disable another user's service, mask units, alter Omarchy's night-light configuration or overwrite color-management settings. Explain that the user must release the competing controller. Detecting a process name is a hint; the protocol result governs ownership.

Ordinary Off/Quit destroys/releases Ember's owner after attempting hardware restoration. The compositor resets the CTM layer to identity. Do not send a guessed baseline or globally reset another program's state after Ember has lost ownership. A disconnected process cannot retroactively prove restored pixels.

HDR, ICC handling, direct scanout, cursor filtering and capture behavior must be tested and documented. If the backend demonstrably fails in a mode, clearly mark that mode unsupported/limited, and do not silently switch it off. If the ordinary SDR target cannot deliver warmth, dimming and Pure Red reliably, record the failed feasibility gate before expanding UI work; continue isolated core/tests rather than disguising a different backend as equivalent.

## 5. Persistence, restoration and optional Backlight Lock

### 5.1 Separate Linux records

Use XDG directories: settings under `$XDG_CONFIG_HOME/project-ember`, recovery and bounded diagnostic state under `$XDG_STATE_HOME/project-ember`, runtime coordination under `$XDG_RUNTIME_DIR`. Respect defaults when the XDG variables are absent. Directories containing private state should be 0700, files 0600. Do not migrate Mac display-recovery records or interpret Mac IDs as Linux identities.

Version Linux settings and hardware journals explicitly. Validate data before use. Distinguish absent, valid, corrupt, unknown-future-schema and I/O failure. A corrupt journal is quarantined without losing the warning/blocked-hardware state; do not silently replace it with an empty record and permit new brightness mutations. Backups must not resurrect obsolete baselines after a verified restore.

Before a hardware mutation, durably write the immutable baseline using temp file, checked writes, file fsync, atomic rename and directory fsync. Handle failures rather than claiming that rename alone proves power-loss durability. Prevent unsafe file/symlink substitution in private state operations. Test truncated records, bad ownership, resource exhaustion and concurrent cleanup. Do not rewrite a hardware baseline on each slider movement.

Record recoverable fields independently. Remove a field only after its own restoration verification or a specifically recorded, safe supersession resolution. If a device is absent or identity is ambiguous, preserve the record and expose the pending state. A successful CTM reset says nothing about hardware brightness recovery.

### 5.2 Capability-gated hardware path

Implement Backlight Lock, but engage only when a real built-in LCD backlight can be unambiguously associated with the target, read and written with existing user permissions. Probe Linux backlight class/driver information and physical device association. Never select the first `brightnessctl` device, a keyboard LED, an external DDC device or an unrelated GPU backlight provider. Preserve identity/fingerprint, boot ID, original and last-written values, max scale and recovery ownership information. A sysfs path or output connector name alone is not durable physical identity.

Prefer a bounded `brightnessctl` adapter using an exact enumerated backlight device and argv, without a shell, or an equally restricted direct sysfs/logind adapter justified by the target. Read requested and actual brightness where supported; document driver-specific verification tolerances rather than interpreting raw sysfs values as luminance. Missing permission makes the option unavailable. Do not install world-writable udev rules, create a privileged daemon, add groups, run sudo from the app or prompt for elevation during each adjustment.

Capture before changing. Apply the intended software dim first, establish compositor control, and only then raise the hardware level. On orderly disable/restore/sleep/quit, restore the hardware level before releasing CTM to reduce a bright flash. If either operation fails, attempt the independent safe recovery path and retain its evidence.

Automatic brightness has no assumed universal Linux interface. Only change a provider that can be safely captured/restored. Otherwise disclose that automatic brightness is unmanaged. Read-only guard checks can occur around every five seconds while engaged; write only on drift, bound correction attempts, and suspend the hold with attention after repeated interference (initial limit three corrections in sixty seconds). Do not fight brightness keys or the Omarchy display panel forever. Software filtering should remain usable when the hardware feature fails.

### 5.3 Independent cleanup is required

Hardware brightness can outlive the app; CTM ownership normally cannot. A destructor in the GUI process is not sufficient crash recovery. Ship a supervised user service with a **headless independent `recover-hardware` cleanup command**, normally through `ExecStopPost`, plus startup recovery. The helper must work without Qt GUI initialization, an active tray or CTM ownership.

Prove that cleanup is armed before permitting Backlight Lock. An unmanaged development process may use color controls but must refuse hardware engagement unless an equivalent independent guardian is installed and tested. Use interprocess synchronization for the journal. Recovery helpers must not race a live controller or a newer legitimate session.

On abnormal termination, restore what can be safely restored and restart in a safety-paused state with a clear message rather than automatically reengaging maximum brightness. Ordinary intentional Quit preserves preferences for a later intentional launch. Rate-limit automatic restarts. Across reboot or a legitimate subsequent user brightness change, do not blindly replay an old journal: inspect ownership/boot/value evidence, preserve uncertain records, and require a safe explicit resolution.

A SIGKILL can reset CTM before the cleanup process lowers hardware brightness. Acknowledge that interval. Do not promise zero flash, flicker-free output, PWM elimination or measured optical safety. If independent cleanup cannot be proven on a target, Backlight Lock remains unavailable there; the software-only app still works.

### 5.4 Emergency behavior

Expose Restore in both settings/control menu and CLI. It cancels pending work, persists filter off, clears Backlight Lock preference, and pauses Sun automation until the user explicitly resumes it. Restore is idempotent and does not attempt to seize another program's CTM manager. With the app down, the CLI can set the safety latch and perform headless hardware recovery. Never report full restoration when recovery remains pending or unverified.

## 6. Sun scheduling and lifecycle

Provide an offline Location section with latitude/longitude, a concise explanation of why they are needed, a next-boundary preview, and a clear control to remove them. Validate finite latitude/longitude and round to 0.1° consistently with the reference. `(0,0)` is valid, not an absent-data sentinel. No IP lookup, online map, geocoding API or network permission is needed.

An optional system-location adapter may offer one-shot approximate acquisition behind explicit consent. Probe the actual portal/GeoClue availability; do not make it mandatory. Its provider may have its own network behavior, so do not describe it as guaranteed offline merely because Ember makes only a D-Bus request. Manual coordinates must remain available when system permission is denied. Keep coordinates out of default diagnostic exports.

Port the solar model and manual-override rules; test independently generated reference cases and boundary conditions. Use absolute instants for persisted expiries and named local timezones for display/calendar calculations. Do not add 86,400 elapsed seconds to construct every next local day. Maintain a boundary timer plus a sparse clock/timezone/resume re-evaluation mechanism; polar/no-next-event conditions still need periodic re-evaluation. Timer and retry cancellation must not interfere with each other.

Enabling Sun schedule also attempts launch-at-login and explains the change. With no valid coordinates, show a waiting-for-location state rather than guessing. With valid coordinates, immediately reconcile day/night. A login failure allows session-only scheduling with a warning. Disabling the schedule cancels its timers and leaves current display state intact. Manual on/off overrides until the next valid boundary; Restore uses the stronger safety pause. Explicit location changes reconcile old-location overrides with a visible explanation.

Use logind `PrepareForSleep` and a bounded delay inhibitor only when needed for an engaged hardware restore. Never inhibit sleep indefinitely or assume a signal alone guarantees time to finish. On wake, re-enumerate, expire/reconcile overrides, and apply current intent after safe recovery. A screen lock should not automatically return an evening display to neutral. Compositor restart invalidates all backend objects and requires a new connection/ownership decision.

## 7. Native UI and integration details

One compact settings dialog is sufficient. Use standard labeled controls: master state/action; Neutral/Evening/Pure Red buttons; warmth slider with numeric description; software brightness slider with percentage; Backlight Lock with capability reason; Sun schedule with location and next event/override; launch-at-login; primary-click preference; Diagnostics, Restore and Quit. Fold location/diagnostics into small secondary sections or dialogs rather than an oversized dashboard.

No permanent large window, welcome wizard, onboarding carousel, visualizer, marketing homepage, waveform, custom widget toolkit or animation loop. Native layout should fit a small desktop; permit scrolling/resizing when accessibility scale requires it rather than copying the Mac's fixed 810pt panel. Use system theme, keyboard focus, accessible names and real disabled/error states. Show enough text to distinguish software brightness from physical backlight brightness.

Primary open-settings and primary-toggle must be selectable. Secondary activation always exposes controls and never toggles the filter. Avoid double handling Trigger/DoubleClick/Context. Do not rely on global popup coordinates on Wayland; a normal small settings window is acceptable. Restore must be accessible even if the tray icon is hidden in Omarchy's drawer. When the host disappears, keep the resident state safe and register again when it returns. Never hide the last recovery UI and leave the user with no accessible route.

Preserve the author credit `Designed by Marius Schober for circadian-aware evenings.` in About or a small footer, with the existing author link; no automatic network request. Version the Linux candidate independently (for example `0.1.0-linux-alpha.1`, referencing Mac behavior baseline 0.4.0) without changing Mac version constants or claiming 1.0 acceptance.

## 8. Startup, packaging and operating constraints

The primary lifecycle is an ordinary **systemd user service associated with the graphical session**, with a desktop launcher that starts or addresses that service. Verify the installed Omarchy/UWSM graphical-session target and Wayland environment behavior in Phase 0; do not assume a user service launched at default.target has a usable compositor.

Specify and test startup ordering, environment readiness, `PartOf`/target relationship, restart limits, stop timeout, headless pre/post recovery and intentional Quit semantics. Reflect actual registration success in the login toggle. Enabling/disabling login should not unexpectedly quit the current session's app. Never import the entire shell environment into persistent service configuration; validate only needed session variables.

Use one startup authority. Do not simultaneously enable a systemd unit, add XDG autostart and append a Hyprland exec-once line. If the actual target requires a startup bridge, choose one documented minimal method, preserve user-owned configuration and make it idempotent/reversible. Current Omarchy uses Lua autostart; an old `.conf` recipe must not be applied blindly. Do not edit `shell.json`, stock Omarchy files or the user's night-light configuration during installation.

Ship a working `PKGBUILD`, desktop file, icon assets, service, clear clean-build instructions, and user-level install/upgrade/uninstall guidance. Build with system packages and no implicit network fetch in CMake. Minimum compiler/Qt requirements must be based on APIs actually used. Include dynamic Qt/Wayland runtime dependencies and protocol attribution. A source-only local build route should work without packaging too, but must honor the hardware-supervision restriction.

The initial artifact targets the real machine's architecture, with x86_64 expected as the primary Arch target but not assumed from the source Mac. aarch64 is optional until actually built and checked. Do not label an untested build universal. Do not select a license for the owner's code; document the existing absence of one and preserve third-party notices. No public release or AUR upload is authorized.

Aim for idle CPU below 0.5% of one core and RSS below 100 MiB on the target after warm-up, as **measurement targets, not claims**. Prefer eliminating polling/leaks over polishing a benchmark. Logs and backups need size/retention bounds. Standard diagnostic copy/export is sanitized; troubleshooting must not expose whole environments, raw serials, precise location or unrelated user content.

## 9. Execution phases and checkpoints

### P0 — Establish source and prove the platform contract

Check the branch and clean working tree; fetch complete objects and confirm the baseline is an ancestor. Read all relevant source/instructions listed in MAC_REVIEW. Do not use incomplete-tree workarounds or discard unrelated work. Write `linux/docs/PLATFORM_PROBE.md` with actual environment, exact upstream protocol/source versions, and deviations from this plan.

Build a minimal native tray/settings shell and a CTM transport spike behind explicit test activation. Prove registry-only off behavior, v2 ownership/conflict handling, one complete matrix commit, and safe release. Prove these on the fake wire server in a cloud environment and additionally on a designated real session when available. Establish the startup/supervision route. This is a feasibility gate, not a reason to spend time on art.

Checkpoint: `feat(linux): establish native shell and CTM capability gate` with commands/results and outstanding hardware rows.

### P1 — Domain logic and reference tests

Implement validated settings, presets, color/matrix conversion, solar calculations, reducer/state contracts and reference fixtures. Add U1/U2/U3 tests before wiring real hardware. Explicitly test numerical quantization and generation cancellation. Preserve source provenance for expected results.

Checkpoint: `feat(linux): add Ember domain behavior and parity fixtures`.

### P2 — Production color backend and reconciliation

Complete dedicated connection ownership, asynchronous transport, complete-output staging, hotplug, disconnect/reconnect, blocked state, release semantics and truthful evidence reporting. Add I1 tests that exercise real messages, not only mock method calls. Test no off-state manager bind, survivor preservation and stale callback suppression.

Checkpoint: `feat(linux): implement compositor control and topology recovery`.

### P3 — Usable tray, settings and commands

Wire all normal controls to the coordinator, implement single-instance IPC, native click behavior, settings persistence, local diagnostics and accessible emergency actions. Add UI/IPC tests. Do not show fake active status in production. Keep the interface plain.

Checkpoint: `feat(linux): wire native controls and local command interface`.

### P4 — Schedule, session and login lifecycle

Wire offline location, next boundary/override, solar timers, sleep/wake/clock changes and the selected login/service adapter. Add session-only failure reporting and emergency automation pause. Verify normal logout/login where available; otherwise retain that explicit blocked row.

Checkpoint: `feat(linux): add offline solar schedule and session lifecycle`.

### P5 — Safe hardware option and independent cleanup

Implement real backlight discovery/association, safe permission handling, durable journal, verification, bounded drift and headless cleanup under service supervision. Add U4/I3 fault injection and process-kill tests with fake hardware first. Keep hardware engagement unavailable until the target gate is proven. Do not leave a permanently mocked adapter and call the feature implemented.

Checkpoint: `feat(linux): add guarded backlight hold and crash cleanup`.

### P6 — Packaging, CI and operational documentation

Complete Arch package and clean build/test scripts, service/desktop validation, runtime dependencies, recovery/uninstall documentation and `linux.yml`. Keep existing Mac CI intact. Include a Mac-regression job or an explicitly documented verification path for the unchanged Swift reference; do not report Mac tests as run when only Linux tests ran. Build a real candidate package, record source SHA and hash, and verify installed contents in an isolated environment.

Checkpoint: `build(linux): package and verify native Omarchy candidate`.

### P7 — Adversarial acceptance and handoff

Run the acceptance groups in PARITY_AND_TESTS. Review the actual implementation diff for partial failure paths, teardown order, stale async work, hidden config writes, identity ambiguity, false status and IPC validation. Fix discovered defects with focused regressions. Run available real-desktop/hardware rows and mark unavailable rows explicitly.

Produce `IMPLEMENTATION_REPORT.md` and `HARDWARE_ACCEPTANCE.md` with exact evidence. Push final reviewable commit, report the branch/commit/package/tests/blockers, then **stop for human review and refinement**. Do not merge or deploy. Do not silently omit unfinished features from the final report.

## 10. Build/test interface to deliver

Make the following commands work once the implementation exists; these are target commands, not a claim they currently run:

```bash
cmake -S linux -B build/linux -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug -DBUILD_TESTING=ON
cmake --build build/linux
ctest --test-dir build/linux --output-on-failure

cmake -S linux -B build/linux-release -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
cmake --build build/linux-release
ctest --test-dir build/linux-release --output-on-failure
```

Add a script for isolated D-Bus/wire-protocol/process tests and a separate **explicitly opt-in** hardware script. Ordinary build, CTest, CI and screenshots of test UI must never mutate the developer's real displays or launch a conflicting controller. Use an isolated test runtime/config directory and explicit backend injection with a fail-closed test mode.

Record compiler warnings, sanitizer results where supported, exact passed/failed/skipped totals and artifact provenance. Run `git diff --check`, confirm the final branch, inspect changed paths, and keep package/build outputs out of source control. Do not equate syntax validation, compilation, mock results or a Wayland sync with end-to-end hardware acceptance.

## 11. Definition of done

The implementation is review-ready when a real native executable and installable local package exist; required feature adapters are implemented rather than stubbed; deterministic and simulated integration tests pass; the full parity matrix is accounted for; limitations and unavailable physical tests are explicit; and recovery/install/uninstall instructions are executable and safe.

It is **validated for daily use on a named Omarchy target** only after that target passes ordinary color control, tray interaction, conflict handling, restoration, scheduling/login and relevant hardware acceptance. Backlight Lock has its own stronger engagement gate. Broad HDR/multi-GPU/architecture support cannot be claimed from a single machine.

The intended outcome is a dependable small settings utility, not a larger product redesign. When a choice does not improve correctness, recovery, accessibility or maintainability, choose the simpler implementation.
