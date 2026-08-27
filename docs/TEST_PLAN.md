# Verification plan

## Deterministic core checks

- Exact neutral pass-through, clamping, warmth monotonicity, and Pure Red
- Gamma/brightness composition, resampling, and 100 zero-drift restore cycles
- Journal-before-apply and restore-before-clear state ordering
- UUID, serial, and zero-serial/unit display-identity matching
- Prevention of mismatched physical-display identity resolution
- Backward-compatible settings decoding and manual-override expiry
- Schema-v2 two-display journal round-trip and schema-v1 migration
- Equatorial sunrise/sunset, day/night state, and next-event ordering
- Local-time-zone and daylight-saving solar conversion
- Polar day and polar night without fabricated events

## Read-only system probe

`ProjectEmber --system-probe` must enumerate each active, de-duplicated display
and report ID, ColorSync UUID, built-in flag, gamma capacity/readability, and
hardware capability without writing anything.

Expected on the current setup:

- two online and gamma-compatible displays;
- 1024 readable samples on both;
- Backlight Lock and automatic-brightness control on the built-in panel;
- no DisplayServices backlight capability on the Dell HDMI display.

## Reversible system checks

`ProjectEmber --system-self-test` must:

1. capture every compatible display and optional hardware state;
2. atomically journal all entries;
3. apply and read back a mild transform on every display;
4. apply and read back Pure Red on every display;
5. verify the built-in backlight path when available;
6. restore and read back every exact baseline;
7. restore hardware and automatic-brightness state;
8. clear the journal only after successful restoration.

`--lifecycle-self-test` covers live updates, the one-second hardware guard,
display reconfiguration, sleep restoration, wake recapture, and termination.
`--prepare-crash-recovery-test` followed immediately by `--recover-only` proves
schema-v2 startup recovery across both displays.

## Manual matrix

All checks begin with no recovery journal and no other Ember process:

- Neutral, Evening, intermediate warmth, and Pure Red on MacBook plus Dell
- Apparent brightness at 100%, 50%, and 10% on both displays
- Partial behavior with an unsupported or virtual display
- External connect, disconnect, reconnect, mirroring, and clamshell operation
- Pending recovery while a journaled display is absent, then exact reconnect
- Backlight keys, Backlight Lock disable, and automatic-brightness restoration
- Menu-bar quit, system sleep/wake, crash relaunch, and manual reset
- Sun schedule permission grant, denial, revocation, and Settings deep link
- Immediate daytime/nighttime reconciliation and manual override expiry
- Clock, date, time-zone, DST, wake-after-boundary, and 24-hour location refresh
- Keyboard traversal, VoiceOver names, and one-view panel layout
- Built-in Retina SDR and HDR modes
- Screenshots contain untinted source colors
- No location prompt before the Sun switch is enabled
- No continuous location indicator and no outbound network connection

## Release checks

- 55 deterministic core checks pass
- read-only probe reports both current displays
- reversible system, lifecycle, and crash-recovery checks pass
- arm64 Mach-O with minimum deployment target macOS 14
- version 0.2.0 Info.plist and valid location purpose string
- valid privacy manifest with no collected-data or tracking declaration
- ad-hoc code signature verifies
- DMG mounts and contains the app plus Applications shortcut
- fresh first launch leaves both the filter and Sun schedule off

Developer ID signature, hardened runtime, and notarization remain blocked until
an Apple Developer Program identity is available.
