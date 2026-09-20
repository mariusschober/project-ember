# Hardware and real-session acceptance

These rows require a named Omarchy/Hyprland target. They were not run in the
current container, which has no Wayland session, no active systemd user
manager, and denies AF_UNIX sockets. `linux/scripts/hardware-check.sh` performs
only a read-only platform probe after the explicit `EMBER_HARDWARE_ACCEPT=1`
guard; it does not automate display mutation.

| Row | Required evidence | Status here |
| --- | --- | --- |
| H01 | Normal SDR output warms and dims on all live outputs | `BLOCKED_ENVIRONMENT` |
| H02 | Pure Red is red-channel-only at endpoint | `BLOCKED_ENVIRONMENT` |
| H03 | Off/release leaves compositor ownership and display normal | `BLOCKED_ENVIRONMENT` |
| H04 | Backlight Lock capability and permission gate | `BLOCKED_ENVIRONMENT` |
| H05 | Backlight restore on Off/Restore/Quit | `BLOCKED_ENVIRONMENT` |
| H06 | Crash/kill followed by supervised headless recovery | `BLOCKED_ENVIRONMENT` |
| H07 | Sleep/wake restoration and re-enumeration | `BLOCKED_ENVIRONMENT` |
| H08 | Hotplug keeps a complete survivor matrix map | `BLOCKED_ENVIRONMENT` |
| H09 | Hyprsunset/other CTM conflict shows Blocked and does not seize ownership | `BLOCKED_ENVIRONMENT` |
| H10 | Tray primary click, right-click menu, hidden-tray Restore route | `BLOCKED_ENVIRONMENT` |
| H11 | Sun schedule, manual override, location removal, polar case | `BLOCKED_ENVIRONMENT` |
| H12 | Login launch ordering and session environment | `BLOCKED_ENVIRONMENT` |
| H13 | HDR/ICC/direct-scanout/cursor/capture behavior documented from target | `BLOCKED_ENVIRONMENT` |

Do not convert a Wayland fake-server message, sync callback, compilation
result, or status JSON into evidence of rendered pixels. The target operator
should record compositor version, output names/descriptions, manager version,
other color owners, backlight provider/device association, exact command,
observed UI/state, and any restore artifact for each row.
