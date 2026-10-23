# Testing another printer or reporting a problem

Pixma Fixa has been hardware-tested only on a **Canon PIXMA G7020 running
firmware 1.050**. Other models and firmware versions have not been validated.
Some standard network status features may work; maintenance and reset behavior
may differ even when two printers report the same family name.

You are welcome to try read-only discovery, status and connection checks on
another model and send feedback. Do not force a reset or bypass a blocked
model/firmware check. Do not reset a healthy waste counter just to create a test.

## Make a useful report

1. Leave the printer in normal mode. Connect it and the PC to the same local
   network, then use **Overview > Find printers** or **Add by address**.
2. Note the exact model printed on the printer's label. A reported family such
   as G7000 series may not identify the regional model. Do not include its serial.
3. Open **Diagnostics > Connection > Run connection checks**. These checks read
   interfaces, status and visible queues; they do not print, clean or reset.
4. Choose **Export diagnostic summary**. Open the JSON and review it before
   sharing. Describe the action, expected result, actual result and panel error.
5. [Open an issue](https://github.com/themichaeldaniels/pixma-fixa/issues), or add
   the report to an existing issue for that model. Repository access is required
   while the project is private. The app does not upload anything automatically.

The summary includes the app/Windows version, reported model and firmware,
selected advertised capabilities, current connection errors, connection-check
results, USB product IDs and up to 20 recent operation outcomes. Missing readings
stay missing. It excludes raw packet/event data, print-job titles and contents,
raw USB paths and known device identifiers. Known identifiers and addresses in
included error text are redacted. **Review it yourself before posting it.**

## Local history and full reports

The app records operation stages, returned errors and the exchanges it captures
in local history under `%LOCALAPPDATA%/PrinterCare`. Full report exports can
include serial numbers, network details and other private information. Do not
post the whole data folder, raw service report or full history by default. Keep
transaction guards intact, especially after an uncertain reset or maintenance
operation.

The redacted summary is the first report to send. If we need more evidence, we
can ask for a specific, reviewed capture instead of collecting everything.

## What logs can and cannot tell us

Model/firmware and capability reports help reproduce parser failures, identify
protocol differences and build regression fixtures without owning each printer.
Error and operation records help locate the failing step. They do not reveal
every undocumented command or prove what a physical maintenance operation did.

Adding a write feature can still require a volunteer with that exact model,
reviewed protocol evidence and controlled before/after tests. Acknowledgment
alone is not proof of a successful repair. Unvalidated writes stay blocked.
