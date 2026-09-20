# Project Ember

Project Ember is a native macOS menu-bar display controller for Apple-silicon
Macs (macOS 14+, arm64). It changes display transfer tables to reduce
short-wavelength output and provide software dimming. Its optional Backlight
Lock attempts to keep a compatible built-in display's hardware backlight at
full power while dimming in software.

Current version: **0.4.0** (reliability and interaction release candidate).
Not 1.0: 1.0 waits for the HDMI/display-topology acceptance matrix on real
hardware plus Developer ID-signed, notarized public artifacts.

## What works in 0.4.0

- One shared warmth and software-brightness profile on every compatible display
- Warmth from neutral through 6500–2000 K plus a red-channel-only Pure Red endpoint
- Software brightness from 10–100% (very low values may reduce tonal precision)
- Neutral, Evening, and Pure Red presets; custom warmth clears preset highlight
- Optional Backlight Lock on verified compatible built-in displays only
- Per-display identity, immutable original baselines, schema-v2 recovery
- Generation-based topology reconciliation: no blanket restore of unchanged
  displays, verified readback drives the UI, disconnected baselines stay pending
- Post-event verification (~0.5 s, ~2 s), sparse 30 s health checks, bounded
  degraded state on repeated external overrides
- Local sunrise/sunset schedule with manual overrides until the next boundary
- Launch at login, local recovery journaling, local diagnostics
  (Copy/Export, sanitized identifiers), custom-drawn menu-bar interface
- Menu-bar click behavior: Open Controls (default) or Toggle Ember;
  right-click always opens controls
- Single-view control panel (fitted, no scrolling): click the hero orb to turn
  Ember on/off; footer credit links to the author's website

The filter and Sun schedule are off on a fresh installation. Project Ember does
not need screen recording, accessibility, camera, microphone, or network
permission. It requests approximate location only after the user enables Sun
schedule, uses one-shot location fixes, validates fix age, rounds coordinates
to 0.1°, and performs all solar calculations on-device.

## Install

Direct distribution only for 0.4.0 (Backlight Lock uses private
DisplayServices; treat Mac App Store as incompatible unless Backlight Lock is
removed or compiled out).

1. Open `Project-Ember-0.4.0.dmg` (public path) or
   `Project-Ember-0.4.0-local-beta.dmg` (ad-hoc local path).
2. Drag Project Ember into Applications.
3. Ad-hoc local builds: Control-click the app, choose **Open**, and confirm once.
   Signed/notarized builds open normally.
4. Click the menu-bar indicator.

The first display mutation happens only after the hero orb is clicked on or
after the user explicitly enables Sun schedule and the current time is after
sunset. A newly connected external display may show its own hardware output
before macOS exposes a writable target; Ember applies promptly once
controllable and never flashes unchanged displays.

Updates: replace the app bundle with the newer signed DMG contents. Settings
(0.3.0-compatible) and recovery records migrate forward.

## Sun schedule

Turning on **Sun schedule** also enables Launch at login so transitions are
not missed; the UI states this explicitly. Ember immediately matches the local
solar state, activates with the current warmth/software brightness after
sunset, and restores at sunrise. A manual on/off action remains in force until
the next solar boundary. Turning the schedule off leaves display state
unchanged. Transient location failures retain the scheduling preference with
an unavailable state and retry; only definitive denied/restricted permission
turns the preference off with an explanation.

If permission is denied, use **Open Location Settings…** in the control panel.
No place name, coordinate, or schedule data leaves the Mac.

## Safe recovery

Choose **Restore Display Now** (Diagnostics) before quitting when practical.
Quit also restores automatically. Each physical display has its own
identity-matched baseline; a baseline is never sent to a different monitor.
If a saved display is disconnected during recovery, Ember keeps the entry
pending and completes the restore when that exact display returns. Journal
entries are removed only after verified restoration. Corrupt journals are
quarantined, never silently treated as empty.

If a display ever looks wrong:

1. Open Project Ember.
2. Choose **Diagnostics…**.
3. Select **Restore Display Now** (or **Retry** for verification).

On launch after an unclean exit, Project Ember restores every available
journaled baseline before staying off or following an enabled Sun schedule.

## About the light model (scientific limits)

- Reduces short-wavelength display output for evening use.
- Pure Red is a red-channel-only transfer-table mode, not proof of zero
  short-wavelength physical radiance on every panel.
- Lower melanopic output can be less disruptive at night, but sensitivity and
  display spectra vary.
- Software dimming with an optional compatible built-in backlight mode; very
  low gamma output may band on some displays.
- Backlight Lock may reduce brightness-related flicker on some displays; Ember
  does not measure or guarantee PWM behavior.

## Deliberate boundaries

- Hardware Backlight Lock is not external DDC/CI brightness control. It is
  built-in-only and reversible; automatic brightness changes only when its
  prior state was captured.
- True grayscale and E-Ink modes are not included.
- No external-display DDC/CI brightness control in this release.

## Linux / Omarchy candidate

The repository also contains an independent native Linux candidate in
[`linux/README.md`](linux/README.md). It uses Qt 6, a dedicated Wayland CTM v2
connection, and a supervised user service; it does not replace or modify the
existing macOS app. The candidate is not claimed as daily-use validated until
the named Omarchy hardware and real-session rows in
[`linux/docs/HARDWARE_ACCEPTANCE.md`](linux/docs/HARDWARE_ACCEPTANCE.md) pass.

## Build locally

Run `scripts/build-local-beta.sh` from the ProjectEmber folder. The script
discovers the active SDK via `xcrun`, targets macOS 14 on arm64
(Apple-Silicon-only product decision), runs unit tests plus deterministic core
checks, builds the bundle, ad-hoc signs it, verifies the signature, and
creates the DMG.

Public release: `scripts/build-production-release.sh` (Developer ID
Application, Hardened Runtime, secure timestamp, notarytool submit/staple,
codesign/spctl/stapler validation, DMG smoke-check, SHA-256).

## Privacy

Project Ember contains no analytics SDK, updater, account system, license
service, or network client. Approximate location and settings stay on-device;
no analytics/networking. Diagnostics remain local; exports label display
identifiers and exclude screenshots, window titles, filenames, and browsing
data. See `SECURITY.md`.

## Known limitations

- Private DisplayServices use (Backlight Lock); App Store incompatible.
- External-display timing: new displays apply once controllable; no promise of
  pre-OS output control.
- Display spectral variability; software-dimming banding at very low levels.
- No PWM measurement.
- No explicit license yet — owner must choose proprietary
  (copyright/all-rights-reserved, consider private repo) or approve an
  open-source license before public 1.0.

## License decision (owner action required)

No explicit license is present. See `SECURITY.md`.
