# Pixma Fixa 0.9.0-beta.2

Windows x64 beta, verified on Canon PIXMA G7020 firmware 1.050.
Extract the complete portable ZIP and run `pixma_fixa.exe`.

This release introduces the Pixma Fixa name and renamed Windows executables.
The existing local data folder is retained so earlier preferences, history and
transaction safeguards remain available. Supported maintenance behavior is unchanged.

## Experimental features

- **Native waste-counter reset:** a nonzero clear through this app has not been
  verified on hardware. The original protocol reset succeeded, and native service
  diagnostics and reset safeguards were tested. The interface labels this reset
  Experimental and requires a separate acknowledgment in addition to absorber
  servicing and the existing live identity, firmware and counter checks.
- **Printer-side cancellation:** cancellation of a physical job already processing
  inside the printer remains unverified. The queue view and confirmation label it
  Experimental and require acknowledgment. Queue listing is verified. Held jobs in
  the Windows queue were canceled successfully, including changed-identity refusal.

An unknown model, unsupported firmware, missing command or absent capability
never becomes enabled simply because a feature is experimental. Full EEPROM
backup, manual alignment, deep cleaning, ink flush and firmware flashing remain
unimplemented. Supported maintenance features retain their existing preparation
and live readiness checks.

## Beta validation

Automated regression and visual tests cover both themes, confirmations and guards.
Physical tests cover status, refill counts, standard cleaning, five settings,
nozzle and alignment checks, automatic alignment and USB service diagnostics.
See [VALIDATION.md](VALIDATION.md) and [TESTING.md](TESTING.md) for limits.

**Clean Windows validation passed on 2026-10-23.** A fresh Windows Sandbox guest
with no detected development tools passed offline startup, restricted PATH and
working-directory isolation, read-only USB and Windows queue helpers, and
graceful missing-helper handling. Networking and printer redirection were
disabled. Native interface inspection verified light and dark appearance,
device-theme following, offline controls, both experimental warnings, and sample
report export through the Windows save dialog. No printer writes were sent.

This validates the portable package on the tested Windows guest. It does not
certify every Windows version, display scaling, driver or hardware configuration.
Physical printer behavior is covered separately by the hardware evidence above.
The separate clean Windows test kit supports repeating these startup checks.

For the renamed 0.9.0-beta.2 build, all automated checks passed again in fresh
Sandbox, using its system session because interactive guest login reported a
session-limit error. The renamed native title, light/dark frames and live status
were inspected on the development host, and all 129 regression tests passed.
The full interactive Sandbox inspection above applies to 0.9.0-beta.1; repeating
that inspection for 0.9.0-beta.2 remains pending. No printer writes were sent.

## Reporting a beta issue

Provide the app version, Windows version, printer model/firmware, the action taken
and the visible error. Use the redacted diagnostic summary where possible. Full
service exports can contain connected-printer identifiers and local information;
review them before sharing. Do not post serial numbers or private captures.

Application data stays local. Packages are unsigned. Licenses and required
third-party notices are included. No account or external reset key is required.
