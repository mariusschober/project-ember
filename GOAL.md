# Project Ember goal (historical: 0.2 beta)

> Retained for history. The 0.2 criteria below are superseded by the 0.4.0
> scope; see `CHANGELOG.md` and `RELEASE_NOTES.md` for the current release.

Build a private, native Apple-silicon macOS 14+ menu-bar application that gives
the owner reversible control over every compatible connected display: warmth,
software dimming, optional verified built-in backlight control, and an optional
local sunrise/sunset schedule.

The 0.2 beta is successful when:

1. Every active, non-duplicated display with a readable CoreGraphics gamma
   table is identified independently and captured before mutation.
2. A schema-v2 recovery journal containing every physical display baseline is
   atomically saved before the first color or backlight write.
3. Neutral, Evening, intermediate warmth, Pure Red, and 10–100% apparent
   brightness apply and read back on both the MacBook panel and the connected
   Dell HDMI display.
4. A failure on one display restores and excludes that display without blocking
   compatible displays or ever redirecting its baseline to another monitor.
5. Disable, sunrise, quit, sleep, wake, hot-plug, crash relaunch, and manual
   reset leave every available display restored or retain an explicit pending
   recovery for a disconnected physical display.
6. Backlight Lock remains capability-gated, saves and restores hardware
   brightness plus automatic brightness, and never attempts DDC/CI control on
   an unsupported external monitor.
7. When enabled by the user, Sun schedule obtains approximate location only
   through one-shot Core Location requests, calculates locally, activates at
   sunset, restores at sunrise, and honors manual overrides until the next
   solar boundary.
8. Enabling Sun schedule also enables Launch at login; missed transitions are
   reconciled after wake, clock changes, time-zone changes, or relaunch.
9. The interface remains keyboard-accessible, understandable in one view, and
   reports controlled, unsupported, and pending displays honestly.
10. The app performs no account, licensing, telemetry, tracking, analytics, or
    network activity. Approximate coordinates stay local and are removed when
    location permission is revoked.
11. The arm64 application and DMG pass deterministic core checks, live
    two-display apply/readback/restore checks, bundle validation, and ad-hoc
    signature verification.

True grayscale and E-Ink simulation are intentionally excluded because the
safe per-channel gamma pipeline cannot perform cross-channel color mixing.
Developer ID signing and Apple notarization remain a later distribution gate.
