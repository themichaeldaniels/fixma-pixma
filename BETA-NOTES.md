# Printer Care 0.9.0-beta.1

Windows x64 public beta candidate, verified on Canon PIXMA G7020 firmware 1.050.
Extract the complete portable ZIP and run `printer_care.exe`.

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

**Clean Windows machine validation is pending.** A restricted-PATH run on the
development host does not replace a fresh Windows environment. The separate
clean Windows test kit prepares an offline Sandbox run or tests another clean
Windows PC/VM. It reports startup, read-only native helpers and missing-helper
handling without sending printer writes. The report distinguishes host checks
from an explicitly confirmed clean system. Native UI, theme and save-dialog
inspection are also required on that system before recording the release gate.

## Reporting a beta issue

Provide the app version, Windows version, printer model/firmware, the action taken
and the visible error. Use the redacted diagnostic summary where possible. Full
service exports can contain connected-printer identifiers and local information;
review them before sharing. Do not post serial numbers or private captures.

Application data stays local. Packages are unsigned. Licenses and required
third-party notices are included. No account or external reset key is required.
