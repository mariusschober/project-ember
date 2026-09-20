# Recovery and cleanup

Project Ember stores settings under `$XDG_CONFIG_HOME/project-ember` and the
recovery journal and safety latch under `$XDG_STATE_HOME/project-ember`. The
runtime guardian record is under `$XDG_RUNTIME_DIR/project-ember`. Defaults are
used when the XDG variables are absent. Private directories are mode 0700 and
private files are mode 0600.

Before Backlight Lock changes a supported built-in backlight, Ember writes the
baseline through a temporary file, checked writes, file `fsync`, atomic rename,
and directory `fsync`. The journal records the boot-id hash, device identity,
original value, last Ember-written value, and maximum scale. A change made by
the user or another service is preserved as uncertain rather than overwritten.

The user service arms the guardian before starting the resident process and
runs `--recover-hardware` in `ExecStopPost`. A normal in-process Quit leaves a
private clean-exit marker so this stop hook can preserve an intentional
schedule preference; crashes, explicit service stops, unresolved journals and
failed cleanup enter the safety-paused path. Startup recovery runs before a
new session can re-engage the feature. `--recover-hardware` does not create a
GUI, bind Wayland, or seize CTM ownership; it disables the filter, writes the
safety pause, and restores only a journal entry whose identity/value evidence
is safe. An uncertain or missing device remains pending.

`Restore` is idempotent, turns the filter and Backlight Lock preference off,
and pauses Sun automation until the user explicitly resumes it. A corrupt
journal is quarantined and never treated as an empty baseline. A failed
restore is visible in status and diagnostics.

The cleanup path cannot eliminate the small interval between a compositor
reset after process death and a later hardware write. Ember makes no claim of
zero flash, flicker-free output, PWM elimination, or measured optical safety.
