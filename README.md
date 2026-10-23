# Printer Care

A local Windows utility for maintaining the Canon PIXMA G7020. No account, reset key, Python installation, or bundled Canon application is required.

## Scope

- Discover network printers and read identity, firmware, estimated ink, current errors, and reported capabilities.
- Read G7000 page counts and printhead replacement counters.
- Reset remaining-ink counts after confirming the selected tanks were refilled.
- Run standard printhead cleaning, nozzle checks, alignment-value checks, and automatic printhead alignment.
- Read and change quiet mode, automatic power on/off, paper-abrasion prevention, and ink drying wait.
- Inspect the printer queue and separately selected Windows queues; cancel only confirmed jobs.
- Read the USB service report and perform a guarded waste-counter reset after absorber servicing.
- Keep local history, repair follow-ups, diagnostic exports, report comparisons, and offline protocol inspection.
- Follow Windows appearance automatically, with persistent Light and Dark overrides.

Document scanning, document previews, PDF generation, and scan archives are removed in 0.7.0. Existing files from older versions are preserved. General document printing is outside this utility's scope.

## Compatibility and verification

Windows x64 is the supported platform. Canon maintenance and reset commands are restricted to the G7020/G7000 profile and firmware 1.050. A family name alone does not establish compatibility with every regional model. Other IPP printers can expose read-only status and queue capabilities. G6020 is a research candidate, with no service writes enabled.

| Feature | Evidence |
| --- | --- |
| Identity, firmware, ink estimates, usage, settings reads | Verified on the connected G7020 |
| Remaining-ink resets | Each color acknowledged and independently read back at 100% |
| Standard cleaning and five settings | Hardware tested, settings restored |
| USB service report, history/export and reset guards | Hardware tested |
| Waste-counter clear | Original protocol reset succeeded; native nonzero clear remains untested |
| Nozzle/alignment checks | Matching jobs completed, both sheets printed and photographed; no obvious nozzle defects in the supplied photo |
| Automatic printhead alignment | One matching calibration job completed in about 4 minutes 19 seconds; saved A-T values read back, with seven adjustments changed |
| Queue cancellation | Completed, held one-page Canon Windows spool job canceled; changed identity rejected; physical in-flight IPP job cancellation remains untested |
| Portable startup and upgrade | Extracted ZIP runs with a restricted PATH and unrelated working directory; prior settings, history, guards and saved files preserved |

Ink percentages are stored estimates, not physical tank measurements. Remaining-ink reset and waste-absorber reset are separate operations. A counter reset does not remove waste ink. Full EEPROM backup, firmware flashing, ink flush, deep cleaning, and unvalidated model writes are not implemented.

Automatic printhead alignment uses two plain Letter or A4 sheets in the front
cassette and takes about 4 to 5 minutes. It prints and measures alignment patterns
and saves the adjustment in the printer. The separate alignment check prints
existing values on one sheet. Alignment requires live capability/identity checks,
an idle error-free printer, reported ink in all colors and preparation confirmation.
The app tracks the matching job for up to ten minutes, records adjustment values
before and after completion when available, and never repeats an uncertain command.

## Run

Extract the complete Windows ZIP and run `printer_care.exe`. Keep both helper executables, DLLs, and the data directory together. See [START-HERE.txt](START-HERE.txt).

The current package is a public beta. Offline startup, native helpers, missing-helper handling, appearance and sample report export passed in fresh Windows Sandbox without development tools. Distribution files are unsigned. Native nonzero waste-counter clear and printer-side in-flight job cancellation are marked Experimental in the interface and require an additional acknowledgment. No driver changes or automatic service-mode transitions are performed. See [BETA-NOTES.md](BETA-NOTES.md) and [VALIDATION.md](VALIDATION.md) for observed results and limits.

## Build and test

Use Flutter 3.47.7 / Dart 3.13.5 and Visual Studio with Desktop development with C++. From the project directory:

```powershell
./tool/build-windows.ps1 -FlutterRoot C:/src/flutter
```

The script resolves locked dependencies, runs static analysis and tests, compiles native USB/queue helpers, builds the release application, and creates a portable ZIP. Debug symbols are kept outside that ZIP. See [TESTING.md](TESTING.md) for the regression inventory and manual checks.

## Data and transaction handling

Application data lives in `%LOCALAPPDATA%/PrinterCare`. History and settings remain local. Full report exports contain private printer information; the separate diagnostic summary omits known serials, network addresses and raw USB paths. Review exports before sharing.

Mutations require live identity/readiness checks and explicit preparation. Uncertain commands are never automatically repeated. Waste resets use an exclusive durable attempt marker; refill/maintenance attempts have persistent guards. An OS file lock serializes recorded transactions across instances sharing the same state directory. Losing a reply does not establish success. Repair verification requires a normal restart, same-device status, and display confirmation.

Only service selector `10077c`, report query `15`, and waste clear `0d0000` are exposed by the USB worker. The worker runs separately to bound stalled driver calls. Normal-mode Canon commands use bounded CHMP requests. Network queues use IPP status/listing/identity/cancellation only; no print documents or empty Create-Job probes are submitted by the utility. Jobs still held on other computers or phones are outside this PC's view.

## License

Zlib. Required upstream and dependency attribution is retained in [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt). Font assets are bundled under their included license. No proprietary vendor executable, firmware image, installer, or reset key is distributed.
