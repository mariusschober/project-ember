# Project Ember

Project Ember is a native macOS menu-bar display controller for Apple-silicon
Macs. It is an independent product with original naming and interface.

## What works in 0.2

- One shared warmth and apparent-brightness profile on every compatible display
- Verified support for the built-in Liquid Retina XDR panel and a Dell S2419H
  connected through USB-C/HDMI
- Warmth from neutral through a physically modelled 6500–2000 K range
- A deliberately named Pure Red endpoint beyond the temperature range
- Software brightness from 10–100%
- Neutral, Evening, and Pure Red presets
- Optional Backlight Lock on capability-verified built-in displays
- Per-display identity, exact gamma-baseline capture, and schema-v2 recovery
- Partial support that leaves an incompatible display untouched
- Hot-plug, mirror, sleep/wake, termination, and crash-recovery handling
- Optional local sunset activation and sunrise restoration
- Manual schedule overrides until the next solar boundary
- Manual Restore Display Now control and local diagnostics
- Launch at login through the macOS service manager

The filter and Sun schedule are off on a fresh installation. Project Ember does
not need screen recording, accessibility, camera, microphone, or network
permission. It requests approximate location only after the user enables Sun
schedule, uses one-shot location fixes, rounds coordinates to 0.1°, and performs
all solar calculations on-device.

## Install the local beta

1. Open `Project-Ember-0.2.0-local-beta.dmg`.
2. Drag Project Ember into Applications.
3. Because this local beta is not notarized, Control-click the app, choose
   **Open**, and confirm once.
4. Click the sun-at-horizon icon in the menu bar.

The first display mutation happens only after **Turn Ember On** is clicked or
after the user explicitly enables Sun schedule and the current time is after
sunset.

## Sun schedule

Turning on **Sun schedule** enables Launch at login and asks macOS for location
permission. Ember immediately matches the local solar state, activates with the
currently selected warmth and apparent brightness after sunset, and restores at
sunrise. A manual on/off action remains in force until the next solar boundary.
Turning the schedule itself off leaves the current display state unchanged.

If permission is denied, use **Open Location Settings…** in the control panel.
No place name, coordinate, or schedule data leaves the Mac.

## Safe recovery

Choose **Restore Original Display** before quitting when practical. Quit also
restores automatically. Each physical display has its own identity-matched
baseline; a baseline is never sent to a different monitor. If a saved display
is disconnected during recovery, Ember keeps the entry pending and completes
the restore when that display returns.

If a display ever looks wrong:

1. Open Project Ember.
2. Choose **Diagnostics…**.
3. Select **Restore Display Now**.

On launch after an unclean exit, Project Ember restores every available
journaled baseline before staying off or following an enabled Sun schedule.

## Deliberate boundaries

- Hardware Backlight Lock is not external DDC/CI brightness control. It remains
  available only where macOS exposes verified hardware read/write support.
- True grayscale and E-Ink modes are not included. Independent RGB gamma tables
  cannot safely mix color channels into monochrome across every display.

## Build locally

Run `scripts/build-local-beta.sh` from the ProjectEmber folder. The script uses
the installed macOS 15.5 SDK, targets macOS 14 on arm64, runs deterministic core
checks, builds the application bundle, ad-hoc signs it, verifies the signature,
and creates the DMG.

## Distribution boundary

The local beta is intentionally ad-hoc signed. Sending a normal double-clickable
build to other Macs requires an Apple Developer Program account, a Developer ID
Application certificate, hardened-runtime signing, and notarization.

## Privacy

Project Ember contains no analytics SDK, updater, account system, license
service, or network client. Diagnostics remain in memory. The only persisted
location value is a locally stored, rounded coordinate plus timestamp used to
calculate the next sunrise and sunset.
