# Regression test inventory

Run from the project directory:

```powershell
flutter analyze
flutter test --coverage
```

Tests use simulated printers, captured sanitized protocol fixtures, temporary
application state and local HTTP servers. Automated runs do not contact the
owner's printer or send hardware maintenance commands. Widget tests cover the
actual maintenance interface and screenshots in both themes. Regenerate golden
screenshots only after intentional UI changes and visual review.

## Coverage map

| Area | Primary test files | Regression checks |
| --- | --- | --- |
| USB protocol | protocol_test, workflow_test | Captured vectors, encode/decode, fragments, selector rejection, one-shot clear, interrupted writes, readback |
| Canon refill | ink_counter_test, ink_reset_workflow_test | XML namespaces, capability/firmware checks, selected colors, full counts, changed identity, unknown levels, durable guards |
| Maintenance/settings | canon_maintenance_test | Captured commands, two-sheet automatic alignment capability, preparation, idle/ink requirements, matching task completion, lost replies, adjustment readback failures, settings readback/restoration |
| Network | network_test, network_controller_test | IPP lengths/types/errors, DNS bounds/loops, discovery, address fallback, polling, offline recovery, restored selection |
| Queues | queue_test, queue_widget_test | Source identity, job fingerprints, stale views, new arrivals, confirmed lists, cancellation once, Windows helper bounds |
| Diagnostics | diagnostics_test, diagnostics_widget_test | Usage parsing, redaction, model evidence, report comparisons/imports, offline capture bounds, read-only checks |
| Model reports | support_summary_test | Unknown-model evidence, missing identity, bounded capability/history fields, private payload exclusion, longest-first identifier redaction |
| Repair tracking | repair_verification_test | Restart/display confirmation, same-device pinning, busy/error refusal, persistent guards, failed checks revoke verification |
| Reliability | release_reliability_test | Corrupt history, unwritable/failing storage, cleanup errors, cross-instance locking, preference preservation, invalid reset evidence, upgrade data preservation |
| Interface | widget_test and other widget files | System/light/dark appearance, minimum-width layouts, accessibility text scaling, confirmations, null dropdown guards, sample separation, navigation scope |
| Experimental actions | experimental_features_test, queue_widget_test | Separate spill-risk and experimental acknowledgments required; either alone or unchecking the spill acknowledgment blocks reset. Cancel sends nothing. Printer-side cancellation acknowledgment remains separate. |
| Action errors | action_feedback_test | USB/service-mode help, normal-mode mismatch, network errors after explicit refresh, quiet background failures, uncertain-delivery warning, no retry on dismiss, safe completion after screen removal |

## Individual test cases

### final_review_test.dart

- Redaction preserves JSON keys and primitive types, including identifiers matching JSON literals.
- Quoted, forward-slash, network and local user paths, URLs and email addresses redact without corrupting JSON.
- Prior-operation printer identifiers and document metadata are removed from current errors.
- Discovery limits total records and packets, including malformed packets.
- Overlong names, invalid DNS record boundaries, invalid ports and malformed IPP booleans are rejected.
- Nested report imports have depth and total-count bounds; history has an aggregate memory budget.
- Disposal handles a failed helper close.
- Clock rollback cannot authorize queue cancellation, ink reset, maintenance or settings.

### worker_lifecycle_test.dart

- Non-UTF8 diagnostics do not crash a pending request.
- An asynchronous journal failure terminates the helper without an uncaught error.
- Closing an already-closed helper input is safe and idempotent.
- Oversized helper output terminates the helper and reports a bounded failure.

The service-guide widget test also verifies the complete G7020 instructions fit
the minimum window width with larger text, scroll when needed and can be closed.

### problem_report_test.dart

- Closing the instructions does not save or open anything.
- Saving completes before browser launch; the saved path and attachment instructions stay visible.
- Canceling file selection does not open the browser and permits another attempt.
- Save failures display the returned error and block browser launch.
- Browser failures retain the file and fallback link; retrying does not save again.
- Pending saves reject duplicate dispatch and do not open the browser early.
- Closing during save prevents the subsequent browser launch.
- Closing during browser launch safely ignores a late failure.
- Production file export preserves the original error snapshot, applies redaction and sends no printer commands, even while an operation is busy.
- Canceling native path selection writes no file.

### support_summary_test.dart

- Unknown-model support summaries preserve model, firmware and advertised capabilities without granting maintenance eligibility.
- Capabilities and recent history are bounded; missing identity remains unknown and malformed history is excluded.
- Full private URIs are redacted before overlapping shorter hostnames, preserving valid JSON.

### action_feedback_test.dart

- [USB diagnostic failure explains the cable and service-mode requirement once](test/action_feedback_test.dart#L58)
- [normal USB mode is explained after an explicit service-printer search](test/action_feedback_test.dart#L74)
- [background network errors stay inline; manual refresh shows the returned failure](test/action_feedback_test.dart#L95)
- [mutation failure warns about uncertain delivery and never retries](test/action_feedback_test.dart#L119)
- [an action that finishes after its screen is removed does not open a dialog](test/action_feedback_test.dart#L159)

Names containing interpolation describe parameterized cases; the test runner
expands them for each theme/vector. Line locations refer to the current source.

### canon_maintenance_test.dart

- [captured capability enables only supported print patterns and standard cleaning](test/canon_maintenance_test.dart#L102)
- [standard cleaning packet equals the physically tested command](test/canon_maintenance_test.dart#L114)
- [nozzle packet selects one plain sheet from the cassette](test/canon_maintenance_test.dart#L144)
- [automatic alignment requires the advertised two-sheet cassette capability](test/canon_maintenance_test.dart#L154)
- [automatic alignment command selects calibration and allows sufficient completion time](test/canon_maintenance_test.dart#L177)
- [alignment readback preserves zero and signed values, ignoring unknown or invalid items](test/canon_maintenance_test.dart#L195)
- [alignment completion must match auto_registration rather than a check print](test/canon_maintenance_test.dart#L214)
- [settings parse named values; settings generator rejects arbitrary commands](test/canon_maintenance_test.dart#L231)
- [completion requires the matching job, operation and type](test/canon_maintenance_test.dart#L253)
- [switching printers discards cached maintenance controls](test/canon_maintenance_test.dart#L299)
- [one standard cycle waits for matching busy-to-idle completion](test/canon_maintenance_test.dart#L306)
- [confirmation, fresh identity and readiness are required before dispatch](test/canon_maintenance_test.dart#L320)
- [automatic alignment records before and after adjustments after matching completion](test/canon_maintenance_test.dart#L334)
- [automatic alignment cannot start unprepared or repeat after lost acknowledgment](test/canon_maintenance_test.dart#L346)
- [successful alignment remains completed if optional adjustment readback is unavailable](test/canon_maintenance_test.dart#L358)
- [lost acknowledgment is never replayed; durable guard survives new controller](test/canon_maintenance_test.dart#L371)
- [selected setting readback and untouched other values are required](test/canon_maintenance_test.dart#L392)

### diagnostics_test.dart

- [candidate and unknown firmware profiles cannot grant verified features](test/diagnostics_test.dart#L32)
- [USB identity change is evidence, never a model verification](test/diagnostics_test.dart#L51)
- [zero readback and acknowledgment do not prove a repair](test/diagnostics_test.dart#L74)
- [uncertain command remains uncertain even with later normal status](test/diagnostics_test.dart#L93)
- [repair store overwrites atomically and restores evidence across launches](test/diagnostics_test.dart#L104)
- [old reset guard migrates once and remains an effective one-shot guard](test/diagnostics_test.dart#L126)
- [comparison requires same identity, data class, and chronological order](test/diagnostics_test.dart#L147)
- [raw imports cannot turn into live diagnostic or reset eligibility](test/diagnostics_test.dart#L170)
- [saved history JSON imports without trusting its redundant serial fields](test/diagnostics_test.dart#L188)
- [offline captured reply validates ordering and decodes without a transport](test/diagnostics_test.dart#L200)
- [shared diagnostic summary removes known identity, addresses and local paths](test/diagnostics_test.dart#L237)
- [normal-mode usage fields preserve missing and invalid values as unknown](test/diagnostics_test.dart#L251)

### diagnostics_widget_test.dart

- [repair confirmation is explicit and persists while status remains pending](test/diagnostics_widget_test.dart#L93)
- [comparison dropdowns select reports and render actual deltas](test/diagnostics_widget_test.dart#L110)
- [narrow layout and enlarged text keep all diagnostics accessible](test/diagnostics_widget_test.dart#L129)
- [diagnostic pages ${mode.name} visual check](test/diagnostics_widget_test.dart#L145)

### experimental_features_test.dart

- [experimental reset requires explicit opt-in; confirm=$accept](test/experimental_features_test.dart#L8)
- [experimental opt-in alone cannot bypass the spill warning](test/experimental_features_test.dart#L81)

### ink_counter_test.dart

- [reset request matches the captured successful G7020 command](test/ink_counter_test.dart#L12)
- [outer OK cannot hide a rejected or missing vendor acknowledgment](test/ink_counter_test.dart#L26)
- [G7000 capabilities advertise a supported per-color refill reset](test/ink_counter_test.dart#L39)
- [stored counters parse by named color and signed unknown stays unknown](test/ink_counter_test.dart#L56)
- [reset codec accepts only one of the four full-refill colors](test/ink_counter_test.dart#L85)
- [XML replies reject wrong operations, service, namespaces and DTD](test/ink_counter_test.dart#L101)
- [CHMP handles a bodyless POST acknowledgment and fragmented chunked XML](test/ink_counter_test.dart#L116)
- [unrecognized printer cannot dispatch an ink reset](test/ink_counter_test.dart#L179)

### ink_reset_workflow_test.dart

- [selected colors reset once with durable records and real readback](test/ink_reset_workflow_test.dart#L68)
- [confirmation and a nonempty valid selection are required](test/ink_reset_workflow_test.dart#L82)
- [lost reply is never retried and survives controller restart](test/ink_reset_workflow_test.dart#L90)
- [changed identity, busy state and unknown counters block dispatch](test/ink_reset_workflow_test.dart#L110)
- [unselected changes stop the batch before another write](test/ink_reset_workflow_test.dart#L127)
- [already full counts are read without dispatching another reset](test/ink_reset_workflow_test.dart#L135)
- [failed ink-check cleanup releases busy state and blocks reset preparation](test/ink_reset_workflow_test.dart#L145)

### network_controller_test.dart

- [fresh discovery reads identity and supplies without enabling service reset](test/network_controller_test.dart#L53)
- [failed refresh retains old readings but marks them offline, recovery clears error](test/network_controller_test.dart#L63)
- [saved selection works without multicast, snapshots and preferences reload](test/network_controller_test.dart#L77)
- [stable printer identity follows a discovered address change](test/network_controller_test.dart#L95)
- [automatic refresh runs every 15 seconds and pauses during service work](test/network_controller_test.dart#L109)

### network_test.dart

- [Refusing jobs is busy even with no visible queue or Canon support code](test/network_test.dart#L44)
- [IPP query encodes only the read-only attribute operation](test/network_test.dart#L59)
- [IPP repeated values, signed unknowns, request matching, and bounds](test/network_test.dart#L65)
- [G7000 supplies align by marker order and missing fields stay unknown](test/network_test.dart#L81)
- [current support code uses live Canon status, not stored error history](test/network_test.dart#L102)
- [address entry accepts hostname, explicit port and URI; rejects credentials and redirects](test/network_test.dart#L132)
- [DNS-SD records preserve advertised path and port, deduplicate IPP/IPPS](test/network_test.dart#L148)
- [DNS decoder rejects pointer loops and truncated records](test/network_test.dart#L199)
- [HTTP transport sends an IPP read request to the advertised endpoint](test/network_test.dart#L241)

### protocol_test.dart

- [36 independent known-frame vectors and inverse decoding](test/protocol_test.dart#L14)
- [captured G7000 version decodes with resolution profile](test/protocol_test.dart#L40)
- [continuation assembly preserves complete 63-byte response](test/protocol_test.dart#L49)
- [empty first polls are pending; empty continuation is rejected](test/protocol_test.dart#L65)
- [wrong opcode and malformed frame are rejected](test/protocol_test.dart#L71)
- [unknown, unsupported, and not-ready states are never success](test/protocol_test.dart#L89)
- [service report parses usage and distinguishes error history](test/protocol_test.dart#L99)
- [non-Canon text is not accepted as a service report](test/protocol_test.dart#L113)
- [sample and stale reports cannot enable reset](test/protocol_test.dart#L131)
- [zero or absent counter cannot enable reset](test/protocol_test.dart#L138)
- [firmware, servicing, and one-shot guard are enforced](test/protocol_test.dart#L142)
- [a rejected selector never sends a subsequent command](test/protocol_test.dart#L148)

### queue_test.dart

- [IPP preserves separate job groups, state, and creation identity](test/queue_test.dart#L103)
- [IPP allows individual cancel and listing, never purge or print](test/queue_test.dart#L121)
- [IPP identity is reread and a reused job ID is never canceled](test/queue_test.dart#L133)
- [Queue batch cancels the confirmed list and leaves new arrivals](test/queue_test.dart#L182)
- [A lost cancel reply stops the batch without retrying](test/queue_test.dart#L214)
- [Expired queue confirmation cannot dispatch](test/queue_test.dart#L234)

### queue_widget_test.dart

- [Unread queue dropdown always has a non-null sentinel](test/queue_widget_test.dart#L118)
- [Cancel listed jobs shows the exact source and jobs before dispatch](test/queue_widget_test.dart#L135)
- [printer-side cancellation requires a separate experimental acknowledgment](test/queue_widget_test.dart#L160)
- [Queue view fits 900px with larger text](test/queue_widget_test.dart#L209)
- [$theme queues screenshot](test/queue_widget_test.dart#L223)

### release_reliability_test.dart

- [development refill probe requires an explicit printer address](test/release_reliability_test.dart#L38)
- [malformed history never prevents loading a valid record](test/release_reliability_test.dart#L45)
- [unwritable history prevents work and releases busy state](test/release_reliability_test.dart#L73)
- [failed final journal write still releases busy state](test/release_reliability_test.dart#L85)
- [peer cleanup failure is reported without locking the application](test/release_reliability_test.dart#L96)
- [failed preference save preserves previous preferences and does not throw](test/release_reliability_test.dart#L109)
- [upgrade leaves former document caches and reset guards untouched](test/release_reliability_test.dart#L122)
- [invalid counters and future diagnostic times never enable a reset](test/release_reliability_test.dart#L137)
- [a second app instance cannot dispatch during an existing transaction](test/release_reliability_test.dart#L163)
- [truncated USB frames and malformed hex are rejected before decoding](test/release_reliability_test.dart#L191)

### repair_verification_test.dart

- [selecting another printer clears previous identity and usage checks](test/repair_verification_test.dart#L108)
- [no status check before declared restart and no writes during verification](test/repair_verification_test.dart#L120)
- [same-model different serial cannot verify or read counters](test/repair_verification_test.dart#L141)
- [5B00 and Busy override prior display confirmation](test/repair_verification_test.dart#L149)
- [lost connection invalidates previous successful verification](test/repair_verification_test.dart#L159)
- [connection checks explain an empty queue and printer Busy without mutations](test/repair_verification_test.dart#L173)

### widget_test.dart

- [IP field keeps accessibility edits through rebuilds and submits displayed value](test/widget_test.dart#L136)
- [system default follows live Windows brightness changes](test/widget_test.dart#L169)
- [appearance menu provides persistent light, dark, and system choices](test/widget_test.dart#L187)
- [sample report clearly labeled and reset disabled](test/widget_test.dart#L207)
- [empty state is honest and renders at 900px](test/widget_test.dart#L224)
- [live overview displays device firmware, ink, and current errors separately](test/widget_test.dart#L230)
- [live overview fits minimum window and larger text](test/widget_test.dart#L263)
- [ink reset dialog requires selected colors and refill confirmation](test/widget_test.dart#L271)
- [refill guide explains stale estimates without changing counts](test/widget_test.dart#L305)
- [maintenance confirmation requires preparation before one command](test/widget_test.dart#L326)
- [unread Canon settings do not create dropdowns with null values](test/widget_test.dart#L420)
- [scheduled quiet mode is preserved as a non-null current choice](test/widget_test.dart#L431)
- [compact report remains aligned at minimum window width](test/widget_test.dart#L469)
- [${mode.name} maintenance screenshot](test/widget_test.dart#L479)
- [${mode.name} service report screenshot](test/widget_test.dart#L490)
- [${mode.name} live overview screenshot](test/widget_test.dart#L498)

### workflow_test.dart

- [reset persists one-shot guard before dispatch and reads counter back](test/workflow_test.dart#L84)
- [failed selector never creates a marker or sends clear](test/workflow_test.dart#L110)
- [uncertain clear is recorded and a second click cannot repeat it](test/workflow_test.dart#L119)
- [preexisting guard prevents even a USB connection](test/workflow_test.dart#L133)
- [zero counter and sample data cannot reach the worker](test/workflow_test.dart#L141)
- [appearance setting is restored without starting a USB session](test/workflow_test.dart#L151)

## Hardware and release checks

Automated tests do not establish every physical outcome. Nozzle and alignment-value
sheets were printed and photographed on the G7020. A complete held one-page Canon
Windows spool job was canceled, while changed job identity was rejected. Native
export, extracted portable startup, and upgrade data preservation passed.
Automatic alignment completed through the native interface; its matching job and
saved adjustments were verified separately from the alignment-value check print.
Fresh Windows Sandbox startup and native interface checks passed. Physical
in-flight IPP cancellation remains unverified. See [VALIDATION.md](VALIDATION.md)
for the evidence and its limits.
Version 0.9.0-beta.3 passed clean guest automation and interactive inspection under
the normal Sandbox user account. Both themes, device-theme following, offline
controls, the new absorber warning and nonempty native sample export were verified.
The clean Windows test kit is documented in [tool/CLEAN-WINDOWS-TEST.txt](tool/CLEAN-WINDOWS-TEST.txt).
It checks fresh portable startup, restricted PATH, an unrelated working directory,
read-only helper responses and graceful missing-helper handling. It records a
clean-system pass separately from a development-host run. Genuine fresh Windows
validation and manual theme/layout/save-dialog inspection are release gates.
Keep nonzero native waste-clear validation listed as untested; do not reset a
healthy zero-counter printer to manufacture evidence. Standard cleaning, settings,
refill reset and native service diagnostics have prior hardware evidence.

Release checks also include static analysis, unchanged screenshot comparisons,
native launch, read-only printer identity/status/queue checks, archive integrity,
required notices, absence of private evidence/build products from source archives,
and a clean Git tree. Passing tests reduce regression risk; they are not a proof
that every possible printer/driver/firmware state is bug-free.

Version 0.9.0-beta.5 passed fresh normal-user Windows Sandbox startup and native
interface checks. The compatibility notice and diagnostic-export explanation
were inspected in both themes. Read-only checks and native JSON export passed;
the saved summary was independently checked for version, Windows information,
operation outcomes, omitted raw payloads and unknown offline identity. All 139
tests pass; static analysis is clean. No printer writes were sent.

Version 0.9.0-beta.6 passed fresh normal-user Windows Sandbox startup and
read-only helper checks. The Report a problem dialog was inspected in both
themes. Closing the instructions returned to Diagnostics. An explicit launch
opened the default browser; its process independently confirmed the fixed
issue-form URL with no diagnostic query data. All 143 tests pass; static
analysis is clean. Networking and printer access were disabled. No issue was
submitted and no printer writes were sent. Browser failure, duplicate launch
and closing during launch are covered by simulated widget tests.

Version 0.9.0-beta.7 passed fresh normal-user Windows Sandbox startup and
read-only helper checks. Integrated reporting was inspected in both themes.
Canceling the native save dialog wrote no file and opened no issue form.
Saving generated valid diagnostic JSON, then opened the browser with the
exact issue-form URL. Independent checks verified schema/version, Windows
information, omitted raw payloads and unknown offline identity. The saved
path remained visible in the app. The G7020 service guide was inspected.
All 150 tests pass; static analysis is clean. No issue was submitted and no
printer writes were sent. Save failures, browser retry without another save,
duplicate dispatch, closing during save and original error preservation are
covered by regression tests. Networking and printer access were disabled.

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
