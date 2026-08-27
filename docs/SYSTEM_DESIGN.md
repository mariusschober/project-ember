# System design

## Multi-display safety boundary

Project Ember enumerates active online displays through CoreGraphics and
de-duplicates mirror followers. A target is compatible only when its gamma-table
capacity is at least two samples and its complete table can be read.

Every target carries:

- its current `CGDirectDisplayID`;
- a ColorSync display UUID;
- vendor, model, serial, unit, and built-in markers as identity fallbacks;
- gamma capacity and the exact captured table.

A current display ID is never trusted on its own. Writes first resolve the saved
physical identity, then verify that the resolved target still matches. Legacy
schema-v1 recovery may fall back to its captured ID or the built-in display only
for the one-time migration path.

Activation order:

1. Attempt any older pending recovery that has become available.
2. Enumerate and de-duplicate all active displays.
3. Capture each compatible display independently.
4. Capture verified hardware state for the Backlight Lock target, if selected.
5. Atomically save one schema-v2 recovery record containing every baseline.
6. Apply and read back the transformed gamma table on each target.
7. Immediately restore and exclude any target that rejects verification.
8. Apply and verify Backlight Lock only on its capability-approved target.

At least one verified display is required for activation. A failure on one
target does not block successful targets. Unsupported displays remain untouched
and are reported in the control panel and diagnostics.

## Color pipeline

Warmth 0–82% maps through a CIE daylight approximation from 6500 K to 2000 K,
converted from xyY to linear sRGB channel gains. The final 18% smoothly
interpolates to red. That endpoint is called Pure Red because it is not a
physically meaningful color temperature.

Software brightness multiplies all three transformed gamma channels. Each
display's original table remains immutable, so slider changes never compound
and repeated restoration has zero mathematical drift.

CoreGraphics gamma tables map red, green, and blue independently. They cannot
mix RGB luminance into true grayscale, which is why monochrome and E-Ink
simulation are outside the safe 0.2 architecture.

## Backlight Lock

The app runtime-loads the macOS DisplayServices private framework and requires
successful readback plus write symbols before enabling hardware control. On the
tested setup this succeeds for the built-in panel and fails cleanly for the Dell
HDMI display. Ember does not send external DDC/CI commands.

For a supported display it saves hardware brightness and automatic-brightness
state, disables automatic brightness, writes full panel brightness, verifies
readback, and checks again once per second. Three consecutive failures stop the
guard and trigger restoration. Sunrise can restore hardware while preserving
the user's Backlight Lock preference for the next sunset.

## Recovery and lifecycle

The state machine models off, activating, active, restoring, suspended, and
degraded states. The journal remains at:

    ~/Library/Application Support/Project Ember/display-recovery-v1.json

The filename is retained for in-place compatibility; its current payload is
schema v2 with an array of identity-matched display entries. The decoder accepts
the original schema-v1 single-display shape.

Disable, sleep, quit, and manual reset restore every available entry. An entry
whose physical display is absent stays in the atomic journal and is retried
before that display can receive another transform. Display reconfiguration
restores the old configuration, waits for the CoreGraphics change to settle,
then captures and reapplies to the new set. Exact per-display restoration is
always attempted before the manual-reset ColorSync fallback.

The journal contains no screen pixels. It stores only gamma samples, optional
hardware values, display identity, desired settings, timestamps, and app
version.

## Sun schedule

`SolarScheduleController` creates `CLLocationManager` on the main run loop and
uses `requestLocation()` only. It never starts continuous or background
tracking. A successful fix is rounded to 0.1° and stored locally with its
timestamp. Permission revocation deletes that cache.

Solar calculations implement the NOAA equation-of-time and declination model
with the apparent-rise zenith of 90.833°. They use the autoupdating local time
zone, including daylight-saving transitions. The calculator returns the current
day/night state and searches forward for the next real event, so polar day and
night do not receive invented boundaries.

Enabling the schedule also requests Launch at login and immediately reconciles
the filter to the Sun. A manual on/off action stores the requested state plus the
next event time. The override survives relaunch and expires at that boundary.
One-shot timers are rebuilt after location refresh, wake, system-clock changes,
time-zone changes, and each solar event. A stale location is refreshed after 24
hours; a cached coordinate remains usable during a transient Core Location
failure.

## Privacy and permissions

The location purpose string is the only new protected-resource declaration.
Project Ember has no networking code, background location mode, telemetry,
analytics, account, or license service. Approximate coordinates never leave the
Mac and are not classified as transmitted collected data in the privacy
manifest.
