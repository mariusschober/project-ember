# Security

Project Ember is local-first. There are no accounts, servers, analytics,
telemetry, crash-reporting SDKs, or network dependencies.

## Reporting a vulnerability

Contact the maintainer privately. Do not open a public issue for a suspected
vulnerability. Include the app version, macOS version, Mac model, display
topology, and steps to reproduce. Diagnostics exports are local-only; attach
only the sanitized export (`Export Diagnostics…`), never screenshots of
personal content.

## Scope

- Display transfer-table writes are reversible and journaled before mutation.
- Recovery baselines are stored at
  `~/Library/Application Support/Project Ember/display-recovery-v1.json`
  (mode 600, excluded from backup) with a last-known-good backup alongside.
- Approximate location (rounded to 0.1°) stays on-device for Sun scheduling.
- Backlight Lock dynamically loads the private `DisplayServices.framework`;
  direct distribution is the supported path. See README distribution notes.
- The signed release carries the Hardened Runtime with exactly one entitlement,
  `com.apple.security.personal-information.location`
  (`Resources/ProjectEmber.entitlements`), which CoreLocation requires once the
  runtime is enabled. There is no App Sandbox entitlement: Project Ember is a
  direct download, not an App Store product.

## Licence

Project Ember is proprietary software. Copyright © 2026 Marius Schober. All
rights reserved. You may install and use the official, unmodified binary free
of charge; the source is published for reading and reference only, and
redistribution or derivative distribution of the source is not permitted. The
complete terms are in [LICENSE](LICENSE) and match the `NSHumanReadableCopyright`
notice in `Resources/Info.plist`.
