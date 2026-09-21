# Recovery and cleanup

Project Ember keeps three independent private areas:

- settings: `$XDG_CONFIG_HOME/project-ember/settings.json`;
- recovery evidence and the automation pause latch:
  `$XDG_STATE_HOME/project-ember`;
- same-user controller ownership, guardian and clean-exit markers:
  `$XDG_RUNTIME_DIR/project-ember`.

Defaults are user-specific when an XDG variable is absent. Directories are
restricted to mode 0700 and files to 0600. Reads reject symlinks, unsafe
owners/modes, non-regular files and files over 1 MiB. Durable writes use a
checked temporary file, file `fsync`, atomic rename and directory `fsync`.
Journal mutation is serialized, while status/doctor reads create no lock file
or other state.

## Backlight engagement gate

Backlight Lock remains unavailable unless all of the following are true:

- exactly one connected internal eDP/LVDS connector has readable EDID;
- exactly one writable Linux backlight provider maps to that DRM device;
- driver, type, maximum and requested brightness are valid;
- boot and `XDG_SESSION_ID` hashes are available;
- the systemd invocation-specific guardian is armed;
- logind sleep notification and a bounded delay inhibitor are available.

The recovery identity is derived from the EDID hash, driver, provider type and
maximum scale, not a mutable class path. The schema-2 journal records hardware
brightness and automatic-brightness state as independent fields. Each field is
removed only after its own identity/value decision and verified restoration.
Device-path changes do not defeat the stronger fingerprint; a changed boot,
session, device identity, or value not last written by Ember is preserved as
uncertain instead of overwritten.

Linux's documented backlight class has no generic automatic-brightness toggle.
Accordingly, the production build does not fabricate one. Automatic brightness
is reported unmanaged until a target-specific provider with documented
read/capture/disable/restore semantics is implemented. The boolean provider in
the tests is accepted only for a non-`/sys` fake tree behind an explicit test
environment variable.

Before any supported hardware mutation, Ember durably records the immutable
baseline. It then disables a supported automatic provider, writes maximum
brightness, verifies requested brightness, and—where exposed—requires
`actual_brightness` within 2% of the device scale (at least one unit). Drift is
checked every five seconds. At most three corrections are attempted in 60
seconds; repeated interference stops the hold and independently attempts each
restore.

## Supervision and exit behavior

`project-ember.service` is the sole graphical startup authority. Its sequence
is:

1. `--arm-guardian` writes a boot- and systemd-invocation-bound marker;
2. `--run` starts the resident controller;
3. `quit` waits for bounded in-process hardware restoration and CTM release;
4. `--recover-hardware` runs in `ExecStopPost`, without GUI or Wayland ownership.

The resident and recovery helper share a same-user runtime lock, so cleanup
cannot race a live controller. A normal Quit writes and durably consumes a
clean-exit marker, preserving intentional filter/backlight preferences after
successful cleanup. Crash, SIGKILL, failed startup, unresolved recovery,
unreadable settings, or emergency Restore writes the persistent safety latch,
keeps filtering off, and pauses Sun automation until explicit Resume. The
service restart limit prevents an uncontrolled full-brightness crash loop.

Sleep handling restores hardware before Ember intentionally releases its CTM
owner. If hardware restoration cannot be verified, Ember releases the bounded
logind inhibitor but does not deliberately remove software dimming; compositor
loss during sleep remains outside the process's control and must be checked on
the real target.

## Explicit recovery choices

- `project-ember restore` is idempotent, turns filter and Backlight Lock
  preference off, and safety-pauses automation. It works headlessly when no
  resident exists.
- `project-ember resolve-recovery keep-current` accepts only currently readable
  values whose strong device/provider identity matches the journal. It changes
  no hardware and preserves every field it cannot verify.
- `project-ember resolve-recovery discard-unreadable` is the last-resort path
  for corrupt/future/unreadable evidence. It requires explicit confirmation in
  the UI or exact CLI spelling, changes no hardware, disables Backlight Lock,
  and leaves automation paused. Use it only after independently checking the
  current hardware state.
- `project-ember resolve-settings replace` explicitly replaces a preserved
  corrupt/future settings file with the current safe in-memory settings.

The cleanup path cannot eliminate the interval between compositor loss after
process death and the supervised hardware restore. Ember makes no claim of
zero flash, flicker-free output, PWM elimination, pixel readback, or measured
optical safety.
