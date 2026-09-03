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

## License decision (owner action required)

The repository currently has no explicit license. Do not ship a public 1.0
until the owner decides:

- Proprietary product: add an explicit copyright/all-rights-reserved notice and
  consider making the source repository private.
- Open-source product: owner selects and approves a license before public 1.0.
