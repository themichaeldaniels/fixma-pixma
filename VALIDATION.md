# Hardware and portable validation

Validation date: 2026-10-23. Printer: Canon PIXMA G7020, advertised as G7000
series, firmware 1.050. Initial physical checks used the 0.7.0 maintenance
implementation; automatic alignment was added and tested separately for 0.8.0.
Private captures and photographs are excluded from public source and packages.

| Check | Observed result | Limit |
| --- | --- | --- |
| Nozzle check | One command; matching nozzle job observed processing, then printer idle without a support code. Owner confirmed the sheet printed. | Photo shows all color bands and no obvious missing black lines or horizontal white streaks; individual nozzles cannot be certified at photo resolution. |
| Alignment-value check | Dispatched through the packaged native interface. Matching job completed; owner confirmed and photographed the A-T pattern sheet and saved values. | Prints existing values, not automatic alignment. Some blocks show striping; optimal alignment is not certified from this photo. |
| Automatic printhead alignment | One native-interface calibration command, two sheets prepared. Matching auto_registration job observed processing, then absent with the printer idle and error-free after about 4 minutes 19 seconds. All 20 A-T values read back; seven changed. | Firmware completion and saved adjustments verified. No additional print-quality photograph was taken after calibration. |
| Canon Windows job cancellation | One-page GDI job completed while individually paused. Production queue helper listed it, rejected changed title identity, canceled the correct job and verified its removal. | No physical page was delivered. This does not validate cancellation of a job already processing inside the printer. |
| Virtual Windows queue cancellation | Two held jobs listed and canceled using the release helper. | No unrelated jobs canceled or queue-wide settings changed. |
| Native export | Save dialog produced a nonempty report containing live status and the completed alignment transaction. | Full report contains private printer information; inspect before sharing. |
| Portable startup | ZIP extracted to a path with spaces, launched from another working directory with PATH restricted to Windows directories and isolated application data. Live identity and maintenance controls loaded. | Existing Windows host, not a clean VM. |
| Upgrade | Launched 0.6.1, then 0.7.0 against the same isolated state. Dark preference, older history, reset guard and former document file remained intact; malformed history did not block startup. | Does not cover every former version or third-party cleanup tool. |
| Runtime dependencies | Audited executable/DLL imports and bundled the Visual C++ runtime. Native application and helpers also started in fresh Windows Sandbox without development tools. | Applies to the tested Windows x64 guest; not every Windows or driver configuration. |
| Beta experimental confirmations | Explicit labels in maintenance/queues and additional acknowledgment before native waste reset or printer-side cancellation. Regression tests cover cancel and confirm paths. | Does not validate the untested physical operations themselves. |
| Automated Windows test kit | Fresh Windows Sandbox, OS build 10.0.26100.0, passed offline startup, working-directory/PATH isolation, read-only USB/queue helpers and missing-helper handling. No development tools detected; cleanWindowsPassed is true. | Networking and printer redirection disabled; no physical printer writes. The earlier development-host run correctly recorded a false clean-system result. |
| Clean Windows native interface | Light and dark appearance, device-theme following, offline queues and disabled maintenance controls, both experimental warnings and sample report export through the Windows save dialog inspected in the fresh guest. Saved report appeared in the guest Documents folder. | Current guest resolution and scale inspected; not every display configuration. Sample report used, with no hardware connected. |

The nozzle assessment follows Canon's [G7000 nozzle check guidance](https://ij.manual.canon/ij/webmanual/Manual/All/G7000%20series/EN/UG/ug-134.html).
Canon distinguishes [printing alignment values from adjusting alignment](https://ij.manual.canon/ij/webmanual/PrinterDriver/W/G7000%20series/1.0/EN/PPG/Dg-printer_assistant.html).
No cleaning, refill reset, waste reset, scanning or service-mode transition was
performed during these checks. Earlier hardware evidence covers standard cleaning,
the five supported settings, remaining-ink resets and native service diagnostics.

The original waste-counter reset succeeded. A nonzero clear through the native
application remains untested because the serviced printer's counter is zero.
This limitation remains visible; no repeat reset is needed to validate a healthy
printer. Additional model writes, manual alignment adjustment, EEPROM backup
and firmware flashing remain outside the implemented scope.
