# Pixma Fixa 0.9.0-beta.4

Windows x64 beta, verified on Canon PIXMA G7020 firmware 1.050.
Extract the complete portable ZIP and run `pixma_fixa.exe`.

Connection requirements are explicit in the interface and README. The 5B00 waste
counter and service report require USB plus manual service mode; Wi-Fi is not
supported for those operations. Remaining-ink resets and supported normal-mode
maintenance use Wi-Fi/Ethernet. Failed user actions show the returned error and
connection steps. Automatic refresh failures remain inline, without repeated
popups. An uncertain operation is never retried by the error dialog.

The waste-counter panel and reset popup now warn about ink spilling from full or
blocked pads. Replace saturated or blocked pads before resetting the counter or
running Ink Flush again on the printer. Reset requires a separate acknowledgment
of this spill risk. A counter reset does not empty the pads. Ink Flush is not an
implemented app action.

The existing local data folder is retained so earlier preferences, history and
transaction safeguards remain available.

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

**0.9.0-beta.3 clean Windows validation passed on 2026-10-23.** A fresh Windows Sandbox guest
with no detected development tools passed offline startup, restricted PATH and
working-directory isolation, read-only USB and Windows queue helpers, and
graceful missing-helper handling. Networking and printer redirection were
disabled. Native interface inspection verified light and dark appearance,
device-theme following, offline controls, both experimental warnings, and sample
report export through the Windows save dialog. The new spill warning was visible
in the waste-counter panel, and reset stayed disabled without live evidence.
The exported sample report was independently checked for nonempty content and
sample identity. All 130 regression tests passed; static analysis is clean.
No printer writes were sent.

This validates the portable package on the tested Windows guest. It does not
certify every Windows version, display scaling, driver or hardware configuration.
Physical printer behavior is covered separately by the hardware evidence above.
The separate clean Windows test kit supports repeating these startup checks.

Version 0.9.0-beta.4 also passed clean normal-user Sandbox startup and interactive
checks. Actual offline network discovery and USB diagnostic failures displayed
the new connection-specific dialogs. Both themes, device-theme following and
nonempty native sample export after error recovery passed. All 136 tests pass;
static analysis is clean. No physical printer writes were sent. A cleanup error
during an ink-count check now releases the busy state and blocks preparation.

## Reporting a beta issue

Provide the app version, Windows version, printer model/firmware, the action taken
and the visible error. Use the redacted diagnostic summary where possible. Full
service exports can contain connected-printer identifiers and local information;
review them before sharing. Do not post serial numbers or private captures.

Application data stays local. Packages are unsigned. Licenses and required
third-party notices are included. No account or external reset key is required.
