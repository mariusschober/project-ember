# AUDIT_FIXES — 0.4.0 prompt → code → test → manual → limitation

Branch: `release/0.4.0`. Version truth: `Sources/EmberCore/AppVersion.swift`.

## Workstream 1 — Topology reconciliation

| Requirement | Code change | Automated test | Manual verification | Limitation |
|---|---|---|---|---|
| 1. Preserve event info (ID, flags, begin/end, generation, timestamp); log readable flags; event stream | `AppDelegate.swift`: new `DisplayReconfigurationObserver` + `DisplayObserverEvent` + callback preserving all fields; `DisplayCoordinator.handleDisplayEvent(displayID:flags:isBegin:)`; `EmberCore.DisplayReconfigurationEvent.flagNames`; `NSApplication.didChangeScreenParametersNotification` complementary | `TopologyTests.duplicatesCoalesce`, `transientIDsIgnored` (stream coalescing) | Hot-plug with Diagnostics open; verify gen/flag lines | Physical timing varies by dock/cable |
| 2. Testable topology model + I/O doubles | `EmberCore.DisplayTopology.swift` (snapshot/entry/event/plan/verification + `DisplayReconciler`); `EmberCore.DisplayProtocols.swift` (enumerator/gamma/backlight/journal/settings/clock) | All `TopologyTests` use pure planner without displays | — (unit only) | Coordinator I/O still needs hardware for full path |
| 3. Settle by generation, not fixed sleep; debounce 200–300 ms; 2 s bound; cancellable Tasks; remove nonisolated timer state | `DisplayCoordinator.settleAndReconcile`, `reconcileTask`/`postVerifyTasks` with generation checks; coordinator timers MainActor-isolated | `staleGenerationInvalid`, `duplicatesCoalesce` | Plug cycles; verify no 0.75 s flash path remains | 2 s bound may reconcile mid-flap with warning |
| 4A. Still-online controlled: no restore/recapture; readback; reapply from saved baseline only on reset | `reconcileSettledSnapshot` `.reapplyFromBaseline` → `isTransformInstalled` else `apply` from entry | `unplugMakesZeroRestoreToSurvivor` | Matrix #2/#3/#5; confirm survivor never flashes | Requires writable target |
| 4B. Disconnected → pending, journal retained, others stay on | `.retainPending`; `pendingRestoreCount` from offline journaled | `disconnectRetainsEntry` | Matrix #6/#9 | — |
| 4C. New display: identity, capture, hardware capture on built-in, journal-before-mutation, verify, rollback retention | `journalThenApply` path with `rewriteRecoveryRecord` before `apply` | `newDisplayJournalFirst` | Matrix #2 first-connect | New display may show native output until controllable |
| 4D. Reconnected pending: canonical baseline, no recapture, no flash | `.applyPendingBaseline` from saved entry | `reconnectUsesSavedBaseline` | Matrix #6 | — |
| 4E. Unsupported/ambiguous untouched + recoverable error, no first-match | `leaveUnsupported`/`leaveAmbiguous`; `GammaDisplayController.target(matching:)` returns nil on >1 candidate | `ambiguousNoMutation` | Virtual/duplicate-serial displays | Zero-serial duplicates need manual resolution |
| 5. Post-verification immediate + 0.5 s + 2 s; bounded reapply; 30 s health; 3-in-60s degraded with Retry/Reset | `schedulePostVerification`, `runVerificationPass`, `startHealthCheck` (30 s ±5 s), `OverrideTracker` + `recordOverrideIfReset` | `osResetDetectable`, `repeatedResetsDegraded` | Matrix: override via Night Shift/True Tone; 10-min stability | Cannot distinguish hostile vs benign OS writes |

## Workstream 2 — Recovery journaling

| Requirement | Code change | Automated test | Manual verification | Limitation |
|---|---|---|---|---|
| 1. No swallowed load errors; explicit outcomes; quarantine + last-resort ColorSync reset + attention + export; backup | `RecoveryJournal.loadOutcome()`, `quarantineCorruptJournal()`, `backupURL`; coordinator `loadJournalEntriesForMutation`/`recoverIfNeeded` with no `try?` on safety paths | `corruptNotAbsent`, `emptyRetained` | Corrupt journal file test (manual) | Last-resort reset cannot prove exact restoration |
| 2. Schema validation; future rejected; legacy built-in never to external | `RecoveryRecord.init` rejects >maxSupported; `GammaDisplayController.target(matching:)` legacy guard | `futureSchemaRejected`, `migrationRoundTrip`, `legacySafe` | — | Future schemas need app update |
| 3. Per-display restore outcomes | `EmberCore.RecoverySafety` (`RestoreOutcome`/`RestoreReport`); `restoreEntriesVerified` | `mismatchRetains`, `disconnectedPending` | Diagnostics outcomes | — |
| 4. Verified exact restoration (gamma + hardware); fallback prunes only matching | `restoreVerified` (0.004) + hardware readback verify; `resetDisplayNow` fallback checks `isBaselinePresent` | `mismatchRetains` | `--system-self-test` restore phase | Tolerance may miss sub-visible drift |
| 5. Preserve failed rollback entries | Activation/apply paths retain full `recoveryEntries` on failure | `failedApplyRetains` | Single-display failure injection | — |

## Workstream 3 — Desired/observed/presentation

| Requirement | Code change | Automated test | Manual verification | Limitation |
|---|---|---|---|---|
| Separate desired/operation/observed/presentation; active only on verified; counts; fix pending-only inconsistency; single render source | `EmberCore.Presentation.swift` (`EmberPresentation`/`EmberPresenter`); `EmberSnapshot` extended (`isObservedActive`, counts, attention, solar struct); `ControlPanel`/`AppDelegate` render from it | `failedNotActive`, `pendingCalm`, `degradedNotSuppressed`, `counts` | Visual QA across states | — |
| Degraded→sleep path; authoritative state machine + exhaustive tests | `DisplayStateMachine` adds `reconciling`, `reconciliation*`, degraded/reconciling sleep/terminate, displayChanged during restore | `degradedSleepTerminal`, `exhaustive`, `topologyDuringTransitions` + `EmberCoreChecks` degraded-sleep | Sleep/wake matrix | — |

## Workstream 4 — Backlight Lock

| Requirement | Code change | Automated test | Manual verification | Limitation |
|---|---|---|---|---|
| Built-in-only targeting | `capability`/`capture`/`engage`/`restore` guard `CGDisplayIsBuiltin`; `DisplayTopologyEntry.isBacklightCandidate`; coordinator selects `identity.isBuiltIn` only | `externalNeverSelected` | External-only Mac (expect unavailable) | Cannot know every panel strategy |
| Never change unrestorable state | Capture-then-change; ambient disabled only when read true; reduced-capability continuation | `noWriteWhenCorrect` (ambient path) | — | Ambient getter may flap |
| Preference vs engagement | `settings.backlightLockEnabled` = preference; `BacklightEngagement` runtime; off/sleep/terminate preserve preference; only explicit off/reset clears | Manual (preference retained across off/on in snapshot) | Matrix #1/#8 | UI must convey engaged vs preferred |
| Read-before-write; tolerance; unavailable preserves + retries | `needsEngagement`, 5 s guard with drift-only writes, `engageBacklightIfPossible` retry in reconciliation | `driftSignalsWrite`, `noWriteWhenCorrect` | 8-hour idle wakeups | 5 s poll still wakes (toleranced) |
| Accurate language; Software brightness; banding note | Control panel/detail copy, header subtitle, README/About limits | — (copy review) | Read panel | Physical spectra vary |

## Workstream 5 — Primary-click quick toggle

| Requirement | Code change | Automated test | Manual verification | Limitation |
|---|---|---|---|---|
| `MenuBarPrimaryAction`, default openControls, Behavior UI, caption, left/right routing, prefs preserved, sun override, busy coalesce, haptics, immediate icon, a11y | `Models.MenuBarPrimaryAction` + settings field/migration; `EmberBehaviorRowView`; `DisplayCoordinator.handlePrimaryClick/setMenuBarPrimaryAction`; `AppDelegate.statusItemClicked` with left/right + `sendAction(on:)`; `PolicyHelpers.MenuBarRouting` | `legacyDefaultsOpenControls`, `primaryRoutes`, `rightAlwaysOpens`, `busyCoalesces` | Matrix #10 both modes + right-click | Control-click treated as right-click |

## Workstream 6 — AppKit UI

| Requirement | Code change | Automated test | Manual verification | Limitation |
|---|---|---|---|---|
| Sun row title alignment; grow downward; identical baselines; no fixed widths | `EmberToggleRowView` aligns icon/switch to `titleLabel.centerY`; removes 244pt width + 81pt height | Layout QA snapshots (manual) | Matrix #11; row states | Snapshots not automated |
| Real scroll view, pinned footer | `ControlPanel` embeds `scrollContent` in `NSScrollView` (autohides) | — | Large-text/permission-error QA | — |
| Pill: clear all on custom, breathing room, contrast, truthful animated, no dead dividers, hover/focus/a11y | `EmberPillControl` layout/custom reset, 1pt inset, contrast border, `updateAccessibility`, arrow keys, radio-group | `customClearsPreset` (preset helper) | Keyboard/VO QA | Dividers intentionally omitted |
| Switch: single path, disabled guard, mouse-up-inside, press action, full Reduce Motion | `EmberSwitch` `_isOn` + `updateVisual`, `pressedInside`, `accessibilityPerformPress`, Reduce Motion all paths | — | Keyboard/VO QA | — |
| Slider: fixed three-stop gradient clipped to fill; standard keyboard/focus/VO; immediate text; coalesced writes + 150 ms settings/journal debounce + flush | `EmberSliderCell.drawBar` three-stop over full track clipped to fill; `changeWarmth/Brightness` immediate text; coordinator 50 ms gamma + 150 ms persist debounce + `flushPendingSettings` | — | Drag-while-unplug matrix #4 | — |
| Animation/render: identity before scale, orb bookkeeping, stop on close/occlude, honor showWaves/animated, cached images, no redundant renders | `ControlPanel` entrance identity; `EmberOrbView` pulsing fix + `setWavesVisible`/`stopRepetitiveAnimation`; `AppDelegate` cached images | — | 8-hour idle observation | — |
| A11y/legibility: 4.5:1 text, 3:1 interactive, contrast/transparency/motion/differentiate, opaque surface, non-color cues, focus order | `DesignTokens` raised secondary/tertiary/muted + `surfaceOpaque`; Reduce Transparency opaque; focus rings/press/roles/labels | — | Accessibility Inspector + keyboard-only pass | Full audit still manual |
| Footer/authorship; Info.plist copyright; no speech-to-text variants | Footer “Designed by Marius Schober for circadian-aware evenings.”; plist copyright | — | — | — |
| Remove health absolutes; mechanism language; limits in About/README | Hero/panel/README copy (red-channel-only, melanopic caveat, banding, no PWM/sleep guarantees) | — | Copy review | — |

## Workstream 7 — Sun schedule

| Requirement | Code change | Automated test | Manual verification | Limitation |
|---|---|---|---|---|
| Validate timestamp age; independent timers; cached-failure retry; cancel retry only on fresh/disable; approximate-only; structured presentation; launch-at-login notice; retain preference; DST/polar/stale/TZ/wake tests | `SolarScheduleController`: age check (5 min), `scheduleTransition` no longer cancels retry, cached-failure `scheduleLocationRetry`, retry cleared on fresh success; `SolarPresentationData`; coordinator retains preference except denied/restricted | `staleRejected`, `dstBoundary`, `polar` + existing solar checks | Permission grant/deny/revoke, clock/TZ changes | Polar shoulder days still search ≤370 days |

## Workstream 8 — Diagnostics

Structured callback/generation/snapshot/plan/journal/delta/verification/backlight/override entries; Copy + Export (sanitized UUIDs); pending/unverified always visible. Code: `DiagnosticLog` + coordinator `logDisplayEvent/logReconciliationPlan` + `exportDiagnostics/sanitize` + `DiagnosticsWindowController` Retry/Copy/Export. Tests: log presence is manual; export sanitization by inspection. Limitation: no screenshots/content by design.

## Workstream 9 — Automated tests

`EmberCoreChecks` retained (59 checks) plus `EmberCoreTests` (36 Swift Testing tests, `swift test` in CI). Coverage maps above. CI uses fakes only; hardware-mutating tests are manual commands marked unexecuted. Limitation: full coordinator I/O still requires hardware.

## Workstream 10 — Release engineering

| Requirement | Code change | Verification |
|---|---|---|
| One version truth; remove stale strings | `AppVersion`; Info.plist 0.4.0/build 4; artifact names derived; `ProjectEmberMain`/header/footer updated | `swift build`, plist lint |
| Local vs production builds (xcrun SDK, clean staging, arm64 documented, tests+checks, Developer ID + hardened + timestamp, notarytool/staple/verify, DMG smoke, SHA-256; no ad-hoc/`--deep`/none-timestamp public path) | `scripts/build-local-beta.sh` (xcrun, clean, tests) + `scripts/build-production-release.sh` | Local build run; production script dry review only (no identity) |
| CI (macOS runner, debug+release+tests+checks+plist, no hardware mutation; branch rules documented) | `.github/workflows/ci.yml` + README notes | CI config review; local `swift test` pass |
| Docs (README/GOAL/SYSTEM_DESIGN/TEST_PLAN/notes describe 0.4.0; CHANGELOG/SECURITY/privacy/install/limits; license flagged) | Updated docs + `CHANGELOG.md` + `SECURITY.md` | Doc review |
| Distribution decision (direct signed/notarized; App Store variant documented, not built) | README distribution boundary | — |

## Manual hardware acceptance matrix

Not claimed as passed. See `RELEASE_NOTES.md` + final report: exact manual commands provided, marked unexecuted on this build machine. Required Mac model/OS/connection/display/HDR/True Tone/Night Shift/result fields must be recorded when run.
