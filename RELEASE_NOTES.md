# Project Ember 0.3.0 local beta

This release extends the original built-in-display beta to every compatible
connected display, adds optional local Sun scheduling, and hardens the
existing app for continuous menu-bar operation.

Included:

- independent display identity and 1024-sample gamma support on the tested
  MacBook panel and Dell S2419H over USB-C/HDMI;
- transactional multi-display capture, journal, apply, readback, and restore;
- schema-v2 recovery with schema-v1 migration and pending disconnected-display
  restoration;
- partial compatibility reporting instead of all-or-nothing failure;
- capability-gated built-in Backlight Lock without external DDC/CI writes;
- one-shot approximate Core Location with on-device NOAA solar calculations;
- sunset activation, sunrise restoration, missed-boundary reconciliation, and
  manual overrides until the next solar event;
- a one-view Sun schedule control and per-display status copy;
- 55 deterministic core checks plus reversible two-display system, lifecycle,
  and crash-recovery tests;
- no accounts, licensing, telemetry, or network services;
- production hardening: 5 s backlight guard (80% fewer wakeups), coalesced
  slider updates, separate solar/ retry timers, robust sleep/wake and
  pending-restore handling, atomic journal with 600 permissions and no-backup
  flag, and paused orb animation while idle.

True grayscale and E-Ink simulation were evaluated and intentionally discarded:
the safe gamma-table pipeline cannot perform the required cross-channel mixing.

Known distribution limitation: this build is ad-hoc signed and not notarized.
