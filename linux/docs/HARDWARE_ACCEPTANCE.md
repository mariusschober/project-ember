# Hardware and real-session acceptance

These are the governing H01–H13 procedures from
`docs/plans/linux-omarchy-20260920/PARITY_AND_TESTS.md`. They require a named
Omarchy/Hyprland target and physical observation. The implementation container
has no Wayland desktop, systemd graphical user session, backlight device, or
physical display, so every row remains `BLOCKED_ENVIRONMENT` here.

`linux/scripts/hardware-check.sh` performs only an explicitly opted-in,
read-only registry/platform probe. It never binds the CTM manager and never
changes color or backlight state. A fake-server request, Wayland sync, status
snapshot, screenshot, compilation result, or package build is not evidence of
rendered pixels or physical hardware restoration.

| Test | Procedure and required outcome | Current status |
|---|---|---|
| H01 Fresh launch | On clean application config, settings visible and everything off; no color change or hardware write. Close/reopen settings and launch a second instance. | `BLOCKED_ENVIRONMENT` |
| H02 Basic profile | Built-in only and external only: Neutral, Evening, intermediate warmth, Pure Red, brightness 10/75/100%; ordinary Off restores Ember-free control. Distinguish visible confirmation from protocol-only evidence. | `BLOCKED_ENVIRONMENT` |
| H03 Multiple outputs | Built-in plus HDMI and, when available, USB-C/DisplayPort. Change settings; all intended outputs follow, no fabricated verified count. | `BLOCKED_ENVIRONMENT` |
| H04 Hotplug | 20 disconnect/reconnect cycles on each available connector type while enabled; include dragging a slider. Survivors do not undergo an Ember-initiated neutral reset. Record any visible flash and its timing; do not dismiss it as OS behavior without evidence. | `BLOCKED_ENVIRONMENT` |
| H05 Output modes | Power-cycle an external display, change resolution/refresh/scale/rotation, test mirrors and clamshell if supported. No stale object use or incorrect hardware mapping. | `BLOCKED_ENVIRONMENT` |
| H06 Conflicts | Start with Omarchy night light/hyprsunset owning CTM, including a neutral profile. Ember shows conflict, changes nothing, and succeeds after explicit user release and Retry. Also test a competitor launched while Ember owns control. | `BLOCKED_ENVIRONMENT` |
| H07 Recovery | Normal off, explicit restore, quit, SIGTERM and deliberate SIGKILL on a designated test session. Show hardware values before/during/after where applicable; journal cleared only after appropriate evidence. | `BLOCKED_ENVIRONMENT` |
| H08 Sleep and resume | Ten suspend/resume cycles, at least one crossing a scheduled boundary or simulated equivalent; no indefinite sleep inhibition or permanently stuck brightness. Ordinary screen lock retains intended evening filtering. | `BLOCKED_ENVIRONMENT` |
| H09 Backlight | When capability is real: capture original brightness, activate hold, adjust software dim, operate brightness keys/Omarchy brightness controls, disable hold, quit and crash. No external/keyboard-light mutation. Unsupported target reports unavailable. | `BLOCKED_ENVIRONMENT` |
| H10 Scheduling | Manual approximate location, sunrise/sunset behavior, manual override, schedule off, explicit emergency pause, login toggle, full logout/login. No network access needed. | `BLOCKED_ENVIRONMENT` |
| H11 UI | Mouse, keyboard, dark/light theme, fractional scaling, different bar edges, 1366×768 usable area. All controls/recovery reachable; do not sacrifice usability to enforce a fixed-size no-scroll layout. | `BLOCKED_ENVIRONMENT` |
| H12 Rendering modes | Separately test HDR, ICC/color management, fullscreen/direct scanout, hardware/software cursor, screenshots and screen recording. Report supported, limited or unverified cases. Do not silently turn off system color features to obtain a pass. | `BLOCKED_ENVIRONMENT` |
| H13 Endurance | Eight-hour active/idle run with settings closed, schedule and topology activity as available. No unbounded log/journal growth, descriptor leak, busy polling, repeated writes, or incorrect status. Measure CPU/RSS/wakeups and disclose the measurement interval. | `BLOCKED_ENVIRONMENT` |

For each target run, record sanitized Omarchy, Hyprland, tray host, Qt, kernel,
GPU/driver and architecture versions; connector topology and modes; advertised
CTM interface version; competing controller state; backlight driver,
permissions and association evidence; exact commands; protocol status; direct
visual observations; and hardware values before/during/after recovery. Mark
unavailable connectors or modes `NOT_APPLICABLE` with a reason, not `PASS`.
