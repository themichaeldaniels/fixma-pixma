# Beta release review

Review date: 2026-10-23. Version: 0.9.0-beta.8.

The review covered the Flutter interface, controller workflows, USB worker,
Windows spooler helper, native window code, IPP and Canon transports, discovery,
local storage, imports, report exports, development probes and release scripts.
The source, stored Git objects and curated release packages receive a separate
privacy audit before publication. Local printer captures and build symbols are
excluded from release files.

## Issues corrected

- Diagnostic redaction now edits decoded string values, preserving JSON keys,
  numbers and booleans. Quoted paths can no longer corrupt the JSON syntax.
  Forward-slash paths, network paths, local user paths, URLs and email addresses
  are also redacted. Structured identifiers from prior operations cover errors
  referring to an earlier printer or queued document. Report contents still need
  human review before sharing; this is not a guarantee of anonymity.
- Discovery has shared packet and record budgets, validates expanded DNS names
  and record boundaries, ignores invalid ports, and handles interfaces closing
  during discovery. IPP rejects malformed boolean values.
- History loading has a 32 MB aggregate input budget as well as per-file limits.
  Report imports have nesting and total-count limits. Files and reset guards are
  not deleted by these limits.
- Future-dated queue, refill and maintenance confirmations are rejected after a
  clock rollback. Live identity checks and durable attempt guards remain required.
- USB helper output is bounded. Non-UTF8 diagnostics, broken input pipes and
  journal failures cannot escape asynchronous error handling. Disposal handles a
  failing helper close. The queue helper handles broken input-pipe futures.
- Native font-change events check that the Flutter engine exists. Windows
  message-loop errors exit cleanly, and console redirection handles failure
  correctly. The build script accepts an explicit output directory for checkouts
  in another location.
- Development probes reserve their proof file exclusively before connecting,
  preventing concurrent invocations from sharing one reset or maintenance proof.

## Verification

The regression suite includes 168 passing tests, including 18 new regressions
for these findings. Static analysis is clean. Parser, workflow and helper failure
tests use local servers, simulated printers and simulated processes; they do not
send physical maintenance or reset commands.

All 26 locked hosted dependencies were checked against the package registry's
advisory API on the review date. No advisories were returned. This check does not
cover every possible defect in the operating system, drivers, Flutter engine or
native runtime, and does not establish that the software has no vulnerabilities.

Fresh Windows Sandbox and final package verification results are recorded in
[VALIDATION.md](VALIDATION.md). The complete regression inventory is in
[TESTING.md](TESTING.md).

## Remaining limits

Hardware testing covers only the PIXMA G7020, firmware 1.050. Native clearing of
a nonzero waste counter and cancellation of a physical job already processing
inside the printer remain Experimental. A healthy zero counter was not reset to
manufacture a test result. The application is unsigned and is a Windows x64 beta.
Other printer models, Windows configurations, drivers and display settings have
not all been tested. Passing these checks reduces known risks; it does not prove
every hardware or failure state is free of bugs.

Version 0.9.0-beta.8 passed fresh normal-user Windows Sandbox startup, native
USB/queue helpers, missing-helper recovery and both-theme reporting. Native
save cancellation wrote no file and opened no form. Saving generated valid
diagnostic JSON before browser handoff; independent checks verified schema,
version, Windows information, privacy exclusions and unknown offline identity.
All 168 tests pass, including 18 review regressions; static analysis is clean.
All 26 locked hosted packages returned no registry advisories on 2026-10-23.
A separate read-only G7020 check returned firmware 1.050, Ready and four full
ink estimates. No physical printing, cleaning or reset commands were sent.

## Fixma Pixma rename verification

Version 0.9.0-beta.9 uses Fixma Pixma throughout the application, Windows product
metadata, executables, diagnostic exports, support links and download packages.
The GitHub repository is now fixma-pixma and remains private. The existing
PrinterCare data folder and legacy helper environment overrides are retained,
preserving settings, history and durable transaction guards when upgrading.

All 168 tests pass with updated light/dark screenshots; static analysis is clean.
The renamed Windows package passed fresh offline normal-user Sandbox startup,
restricted PATH, different working directory, native USB/queue helper checks and
missing-helper recovery. Both themes, native save cancellation and report saving
were inspected. Independent checks confirmed the new report identity and exact
new issue-form URL after saving, with no data in the URL. No issue was submitted
and no printer commands were sent. Hardware limits and Experimental labels remain.
