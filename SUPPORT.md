# Testing another printer or reporting a problem

Pixma Fixa has been hardware-tested only on a **Canon PIXMA G7020 running
firmware 1.050**. Other models and firmware versions have not been validated.
Some standard network status features may work; maintenance and reset behavior
may differ even when two printers report the same family name.

You are welcome to try read-only discovery, status and connection checks on
another model and send feedback. Do not force a reset or bypass a blocked
model/firmware check. Do not reset a healthy waste counter just to create a test.

## Make a useful report

1. Choose **Diagnostics > Report a problem**, then **Save report and open issue
   form**. Pick a location for the diagnostic `.json`. The app saves it before
   opening the GitHub form and keeps the saved path visible. Canceling the save
   or failing to write the file does not open the browser.
2. Open the saved file in Notepad and review it. Describe the action, expected
   result, actual result and panel error. Include the exact physical model from
   the printer label, without its serial. A reported family such as G7000 series
   may not identify the regional model.
3. In the [issue form](https://github.com/themichaeldaniels/pixma-fixa/issues/new?template=model-support.yml), drag the reviewed `.json` into the **Reviewed
   diagnostic summary** field, or use that field's attachment control. GitHub
   sign-in is required to submit; repository access is required while private.

Nothing is attached or submitted automatically. If the browser cannot open, the
saved report remains available with a copyable issue link. Retrying the browser
does not save a second report.

The report uses readings and errors already captured by the app. It does not
send printer commands or clear the error being reported. You can report an
offline printer or a failure during an operation without repeating it.
For a first report from another model, gather read-only status and connection
checks first if possible: use normal mode on the same network, Find printers or
Add by address, then Diagnostics > Connection > Run connection checks. Missing
readings stay missing; the report does not imply that fresh checks succeeded.
Export diagnostic summary remains available as a separate option.

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
