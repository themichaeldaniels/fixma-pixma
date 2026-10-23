# Printer Care

A local Windows utility for maintaining the Canon PIXMA G7020. No account, reset key, Python installation, or bundled Canon application is required.

## Scope

- Discover network printers and read identity, firmware, estimated ink, current errors, and reported capabilities.
- Read G7000 page counts and printhead replacement counters.
- Reset remaining-ink counts after confirming the selected tanks were refilled.
- Run standard printhead cleaning, nozzle checks, and alignment checks.
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
| Queue cancellation | Completed, held one-page Canon Windows spool job canceled; changed identity rejected; physical in-flight IPP job cancellation remains untested |
| Portable startup and upgrade | Extracted ZIP runs with a restricted PATH and unrelated working directory; prior settings, history, guards and saved files preserved |

Ink percentages are stored estimates, not physical tank measurements. Remaining-ink reset and waste-absorber reset are separate operations. A counter reset does not remove waste ink. Full EEPROM backup, firmware flashing, ink flush, deep cleaning, and unvalidated model writes are not implemented.

## Run

Extract the complete Windows ZIP and run `printer_care.exe`. Keep both helper executables, DLLs, and the data directory together. See [START-HERE.txt](START-HERE.txt).

The current package is a preview. Clean Windows machine validation remains pending. Distribution files are unsigned. No driver changes or automatic service-mode transitions are performed. See [VALIDATION.md](VALIDATION.md) for observed results and limits, including the difference between printing alignment values and adjusting alignment.

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
