# Linux implementation and verification report

Report state: implementation complete; all verification available in the
implementation environment passed; real Omarchy and physical-display
acceptance remains blocked by the environment.

Date: 2026-09-21 UTC

Branch: `feat/linux-omarchy-native-20260920`

Candidate: `0.1.0-linux-alpha.1` / Arch package revision `2`
Disposition: review candidate only; not merged, released, published to AUR, or
deployed. It is not yet validated for daily use.

## Result

The F01-F20 Linux source scope in the governing plan is implemented. Feasible
unit, coordinator, real wire-protocol fake-server, private D-Bus, process
recovery, sanitizer, clean Arch packaging, and preserved-Mac checks pass. The
remaining work is target acceptance, not another mock backend: every H01-H13
row requires an Omarchy/Hyprland session, and most require a physical display
or real backlight device that this environment does not provide.

Wayland round-trip completion is recorded only as request processing. Status
continues to report `pixelsVerified=false`; neither this report nor the test
harness claims verified displayed color.

## Fixed provenance

| Item | Exact provenance |
|---|---|
| Governing documents | `docs/plans/linux-omarchy-20260920/PLAN.md`, `MAC_REVIEW.md`, and `PARITY_AND_TESTS.md` |
| Pinned unchanged Mac source | Commit `41973930103c5c12c5c04715f4a1943ff759628d`, tree `b46195b62135658ae45b54a7261a0c872a9abbef` |
| Warning-free immutable Linux package source | Commit `5006691980451169f4fa00f78afab4786edcfcff` |
| Final implementation/package checkpoint | Commit `ae6538873ef78e56f0692ae48c3d29b0b3ca5189` |
| CTM protocol source | `hyprwm/hyprland-protocols` blob `6cb791c1710cdedfc59b3d48fd91cca997d1eabd`; terms retained in `linux/protocols/NOTICE` |
| Numerical reference | 30 rows regenerated in Mac CI from the four pinned Swift files named in the fixture metadata |

The following command produces no output:

```bash
git diff --name-only 41973930103c5c12c5c04715f4a1943ff759628d -- \
  Sources Tests Package.swift Resources
```

The root `README.md` differs only because Linux documentation was added; the
existing Mac application, tests, package manifest, and resources were
preserved.

## Scope and evidence level

| Contract | Implemented behavior | Highest evidence here |
|---|---|---|
| F01/F08 tray and controls | Always-created `QSystemTrayIcon`, native context menu, scrollable native settings, configurable primary activation; secondary activation never toggles in application code | Built and logic-tested; actual Quickshell host is `BLOCKED_ENVIRONMENT` |
| F02/F03 safe default and on/off | Validated off defaults; registry-only off probe; one coordinator; Off restores hardware before bounded owner release; intentional preferences persist | Unit, coordinator, process, and protocol simulation |
| F04-F06 curve, presets, dimming | Exact pinned Mac coefficients, smoothstep, and red tail; independent diagonal brightness; 24.8 transport | 30 independently regenerated Swift rows plus endpoint, property, and quantization tests |
| F07 output map | Dedicated nonblocking Wayland connection; v2 gate; complete live-output staging; topology generations; blocked ownership; stale-command cancellation | Generated client messages against a real `libwayland-server` harness |
| F09/F10 Backlight Lock | Strong EDID/DRM/driver identity; requested and optional actual readback; schema-2 recovery; bounded drift; independent fields; boot/session and guardian gates | Fake sysfs, fault injection, and killed-process recovery; physical engagement blocked |
| F11-F13 solar | Offline rounded coordinates; named timezones; DST/calendar/polar handling; persisted override/rearm; health timer; automation pause/resume | Deterministic domain/coordinator tests; live transition/logout blocked |
| F14 startup | One graphical-session systemd user unit; settings starts/addresses it; actual enablement result; controller lock and D-Bus singleton; root refusal | Fake systemctl/IPC plus installed-unit validation; UWSM login blocked |
| F15/F17 recovery/lifecycle | Invocation guardian, delay inhibitor, restore-before-release, durable clean marker/latch, independent headless cleanup, explicit unreadable-state resolutions | Fault injection and a real helper process killed with `SIGKILL`; real suspend blocked |
| F16/F18 status/diagnostics | Desired state, protocol ownership, operation/request IDs, processed generation, and unavailable pixel evidence are separate; sanitized copy/export and headless restore | Unit, IPC, process, and read-only CLI evidence |
| F19 local product | No telemetry, account, updater, geocoder, webview, or background shell loop; only the user-clicked author link may open a browser | Source inspection and dependency inspection |
| F20 Linux adaptation | Plain native controls, Arch package, desktop file, icon, and user service; no Mac artwork/signing port | Clean Arch package build/install inspection |

No contract is classified as desktop-tested or hardware-accepted in this
report. F10 is intentionally capability-gated rather than fabricated, and F20
is the plan's deliberate non-port of Mac presentation/signing.

## Verification environment

Local executor:

- Ubuntu 24.04, Linux `6.18.44`, x86_64, running as uid 0;
- GCC `13.3.0`, CMake `3.28.3`, Ninja `1.11.1`;
- Qt `6.4.2`, Wayland client/server/scanner `1.22.0`;
- no Swift toolchain, `WAYLAND_DISPLAY`, or `XDG_SESSION_TYPE`;
- no Omarchy, Hyprland, Quickshell tray, graphical systemd user manager,
  DRM/backlight device, physical display, or suspend authority;
- AF_UNIX socket creation is denied by the executor; LeakSanitizer is under
  ptrace and rejects local leak detection.

GitHub verification used Ubuntu 24.04 for Linux, an `archlinux:base-devel`
container for packaging, and a GitHub-hosted macOS 15 arm64 runner for the
preserved Mac workflow.

## Local verification ledger

The dependency-root environment variables were set to the unpacked Ubuntu
24.04 development dependencies, with `QT_QPA_PLATFORM=offscreen` for Qt tests.
The final commands and results were:

| Command/procedure | Expected | Actual result | Exit |
|---|---|---|---:|
| `cmake --build build/final-debug --parallel` | Latest Debug tree builds | Built; no project compiler warning | 0 |
| `cmake --build build/final-release --parallel` | Latest Release tree builds | Built; no project compiler warning | 0 |
| `cmake --build build/final-sanitized --parallel` | Latest ASan/UBSan tree builds | Built; no project compiler warning | 0 |
| `cmake --build build/final-production --parallel` | Tests-off production tree builds | Built and linked only production targets | 0 |
| `ctest --test-dir build/final-debug --output-on-failure` | Five CTest programs pass | 5/5 passed, 0 failed, 0.32 s | 0 |
| `ctest --test-dir build/final-release --output-on-failure` | Five CTest programs pass | 5/5 passed, 0 failed, 0.20 s | 0 |
| `ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 ctest --test-dir build/final-sanitized --output-on-failure` | Five programs pass without ASan/UBSan findings | 5/5 passed, 0 failed, 0.96 s | 0 |
| Direct `-txt` execution of the five Debug QtTest programs | Expose individual passes/skips | Domain 18/0/0; coordinator 5/0/0; wire 2/0/8; IPC 2/0/1; process recovery 8/0/0 (pass/fail/skip) | 0 |
| Production `cmake --install` to a fresh `DESTDIR`; `desktop-file-validate`; staged-path `systemd-analyze verify`; `ldd`; `readelf` | Correct modes/metadata; valid unit; no missing or test/server-only libraries | Binary 0755; four data/unit files 0644; all checks passed; no `Qt6Test` or `wayland-server` production dependency | 0 |
| Isolated-XDG `project-ember status` and `doctor` | Read-only and truthful | Both returned safe defaults including `pixelsVerified=false`; no application file or lock was created | 0 |
| Root `project-ember --run` | Refuse graphical/display mutation | Refused with the documented message | 2 |
| `git diff --check`, `bash -n linux/scripts/*.sh`, PyYAML parse of both workflows, fixture verifier | Clean static inputs | All passed; 30 committed fixture rows self-consistent | 0 |

The eight local wire cases and one private-D-Bus case are explicitly skipped,
not passed, because AF_UNIX returns `Operation not permitted` and no session bus
can be launched. GitHub's `dbus-run-session` jobs execute those suites in a
socket-capable environment.

Two executor-specific diagnostics are retained rather than hidden:

- The first final sanitizer CTest attempt reported 4/5 with
  `ember-ipc-tests` `BAD_COMMAND` because that just-linked file transiently had
  mode 0644. Relinking that exact target restored mode 0755 and the complete
  rerun above passed. This did not reproduce in either GitHub build or the Arch
  package, whose executable was verified as executable.
- LeakSanitizer locally reports that it cannot operate under ptrace, so the
  local sanitizer command disabled leak detection. The GitHub sanitizer run
  below used `detect_leaks=1` and passed.

A raw `systemd-analyze verify` of the uninstalled staged unit initially exited
1 solely because its production `/usr/bin/project-ember` path did not exist on
the host. Verification with that path mapped to the staged executable passed;
the package job then installed the package and verified the unmodified unit at
its production path.

## GitHub verification ledger

All jobs below tested final implementation/package checkpoint
`ae6538873ef78e56f0692ae48c3d29b0b3ca5189`.

| Workflow | Exact result | Evidence |
|---|---|---|
| Linux `build-test` | Debug 5/5 in 1.00 s; Release 5/5 in 0.60 s; install staging, desktop validation, and whitespace check passed | [Linux run 35578944920](https://github.com/mariusschober/project-ember/actions/runs/35578944920), job `106267080787` |
| Linux `sanitizers` | ASan/UBSan with `detect_leaks=1:halt_on_error=1`: 5/5 in 2.36 s; no sanitizer failure | Same run, job `106267081008` |
| Linux `arch-package` | Clean non-root `makepkg`, source-pin check, package inspection/install, original unit validation, dynamic-link check, and Qt Wayland plugin check passed | Same run, job `106267081053` |
| Preserved Mac `CI` | Debug and Release builds passed; 36 Swift tests passed; 59 core checks passed; 30 fixture rows matched pinned Swift; both plist/privacy files linted OK | [Mac run 35578944795](https://github.com/mariusschober/project-ember/actions/runs/35578944795), job `106267080185` |

## Package and artifact provenance

| Field | Value |
|---|---|
| Immutable source commit | `5006691980451169f4fa00f78afab4786edcfcff` |
| Package-building checkpoint | `ae6538873ef78e56f0692ae48c3d29b0b3ca5189` |
| Package | `project-ember-0.1.0.alpha1-2-x86_64.pkg.tar.zst` |
| Package SHA-256 | `93051d9d0e65eaf0e460cf4214acd0cfcb560a0e7870ac1e0d25999410b9111b` |
| Actions artifact | ID `10629710671`, name `project-ember-0.1.0.alpha1-x86_64`, 181,809 bytes |
| Artifact ZIP digest | `sha256:f927f3aac594a9d82f6cd0f87d186d3729e2070bf79dc1271ec054a3083c4493` |
| Retention | Created 2026-09-21 08:39:20 UTC; expires 2026-09-28 08:39:20 UTC |

The package payload includes the executable, protocol notice, desktop entry,
SVG icon, and user unit at their documented `/usr` paths. It has no install
script or auto-enable symlink. CI installed it with `pacman`, verified the unit,
found no missing dynamic library, and found a Qt Wayland platform plugin. This
is a short-lived review artifact, not a release or AUR publication.

## Deliberate deviations and limitations

- Hyprland CTM is functional parity, not photometric identity with the Mac
  transfer-table backend. ICC/gamma baseline preservation and physical
  spectral equivalence are not claimed.
- Wayland sync proves only that a request was processed. There is no pixel,
  gamma, or optical readback, so protocol tests cannot pass H02/H03.
- Linux backlight sysfs has no documented generic automatic-brightness switch.
  Production leaves it unmanaged until a target-specific reversible provider
  exists; only a non-`/sys` boolean test adapter exists.
- Backlight engagement requires boot/session identity, unique physical
  association, durable journaling, write/readback, a service guardian, and
  logind sleep coordination. Unsupported machines retain software color and
  dimming only.
- At an exact pole, the first local noon whose polar day/night state differs is
  used as a bounded synthetic scheduling boundary; ordinary latitudes use
  calculated sunrise/sunset.
- The review package is x86_64 only. No aarch64 package claim is made.
- The repository has no explicit upstream license; the package deliberately
  does not invent one.

No unresolved source defect is known after the feasible suite. The unclosed
acceptance work is the real desktop/hardware matrix below.

## Remaining real-target acceptance

| Row | Status | Missing evidence |
|---|---|---|
| H01 Fresh launch | `BLOCKED_ENVIRONMENT` | Omarchy/Hyprland graphical session, Quickshell tray, clean-user launch and duplicate-instance observation |
| H02 Basic profile | `BLOCKED_ENVIRONMENT` | Supported physical display and direct visual observation at required warmth/brightness points |
| H03 Multiple outputs | `BLOCKED_ENVIRONMENT` | Built-in plus HDMI/USB-C/DP topology and observed output behavior |
| H04 Hotplug | `BLOCKED_ENVIRONMENT` | Twenty physical connector cycles and flash/timing observation |
| H05 Output modes | `BLOCKED_ENVIRONMENT` | Real resolution, refresh, scale, rotation, mirror, and clamshell changes |
| H06 Conflicts | `BLOCKED_ENVIRONMENT` | Live competing Hyprland CTM owner and handoff observation |
| H07 Recovery | `BLOCKED_ENVIRONMENT` | Hardware values and visible output across quit, SIGTERM, and SIGKILL on a designated target |
| H08 Sleep/resume | `BLOCKED_ENVIRONMENT` | Ten real suspend cycles, including a solar boundary |
| H09 Backlight | `BLOCKED_ENVIRONMENT` | Unambiguously mapped internal backlight, permissions, keys/desktop controls, and before/during/after readings |
| H10 Scheduling | `BLOCKED_ENVIRONMENT` | Live solar boundary, service enablement, and full logout/login |
| H11 UI | `BLOCKED_ENVIRONMENT` | Mouse/keyboard, theme, scaling, bar-edge, tray churn, and 1366x768 checks |
| H12 Rendering modes | `BLOCKED_ENVIRONMENT` | HDR, ICC/color management, direct scanout, cursor, screenshot, and recording modes |
| H13 Endurance | `BLOCKED_ENVIRONMENT` | Eight-hour target run with CPU/RSS/wakeup and growth measurements |

The exact procedures and recording fields are in
`linux/docs/HARDWARE_ACCEPTANCE.md`. At least the ordinary SDR path must pass on
one named supported Omarchy target before this candidate can be described as
validated for daily use.

## Review install, restore, and uninstall

Install the retained review artifact only after verifying its SHA-256:

```bash
sha256sum project-ember-0.1.0.alpha1-2-x86_64.pkg.tar.zst
sudo pacman -U ./project-ember-0.1.0.alpha1-2-x86_64.pkg.tar.zst
project-ember settings
```

Emergency restore is idempotent and available without a visible window:

```bash
project-ember restore
project-ember status --json
```

Uninstall without deleting unresolved recovery evidence:

```bash
systemctl --user disable --now project-ember.service
sudo pacman -R project-ember
```

Do not remove `$XDG_STATE_HOME/project-ember` while recovery is pending. See
`linux/docs/RECOVERY.md` for the explicit keep-current, unreadable-evidence,
and unreadable-settings resolution paths.
