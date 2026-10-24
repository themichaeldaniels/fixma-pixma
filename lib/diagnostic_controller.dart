part of 'controller.dart';

extension CareDiagnostics on CareController {
  void restoreRepairs() {
    try {
      repairs = repairStore.read();
      repairLoadError = '';
      // Migrate existing one-shot guards. This does not clear or relax a guard.
      for (final file
          in directory
              .listSync(followLinks: false)
              .whereType<File>()
              .where(
                (f) =>
                    RegExp(r'^reset-[A-Za-z0-9_-]+\.json$')
                        .hasMatch(f.uri.pathSegments.last),
              )) {
        if (file.lengthSync() > 65536) continue;
        try {
          final v = jsonDecode(file.readAsStringSync()) as Map;
          final serial = v['serial'] as String?;
          final created = DateTime.tryParse(v['time'] as String? ?? '');
          if (serial == null ||
              serial.isEmpty ||
              created == null ||
              repairs.any(
                (r) => r.kind == 'wasteCounter' && r.serial == serial,
              )) {
            continue;
          }
          final record = RepairRecord(
            id: 'repair-${created.microsecondsSinceEpoch}',
            serial: serial,
            model: 'G7000 series',
            firmware: '1.050',
            createdAt: created,
          );
          record.acknowledged =
              v['state'] == 'Clear acknowledged; restart verification pending';
          repairStore.write(record);
          repairs.add(record);
        } catch (_) {
          /* Keep malformed guards untouched. */
        }
      }
      repairs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (e) {
      repairLoadError =
          'Repair records unavailable: ${CareController.cleanError(e)}';
    }
  }

  void rememberUsbBaseline() {
    usbBaseline = devices.map((d) => d['path'] as String).toSet();
    message = 'USB baseline saved for this session. Change the connection or enter service mode, then run connection checks.';
    notifyListeners();
  }

  Future<void> checkConnections() async {
    if (busy || networkRefreshing) return;
    await run('connection checks', () async {
      await _discoverUsb();
      final checks = usbChecks(devices, usbBaseline, usbError);
      diagnosticIdentity = null;
      canonUsage = null;
      final target = selectedPrinter;
      if (target == null) {
        checks.add(
          const ConnectionCheck(
            'Local network',
            'No printer selected',
            'Choose a printer or add its address in Overview.',
          ),
        );
      } else {
        await _readNetwork();
        if (!networkOnline) {
          checks.add(
            ConnectionCheck(
              'Local network',
              'Unavailable',
              networkError,
              attention: true,
            ),
          );
        } else {
          final status = networkStatus!;
          checks.add(
            ConnectionCheck(
              'Local network',
              status.stateLabel,
              '${status.model} · firmware ${status.firmware}',
              attention: status.stateLabel != 'Ready',
            ),
          );
          final support = ModelSupport.find(status.model);
          checks.add(
            ConnectionCheck(
              'Feature profile',
              support == null
                  ? 'Standard network features'
                  : support.matchesFirmware(status.firmware)
                  ? 'Verified G7000 firmware'
                  : 'Research or different firmware',
              support == null
                  ? 'Capabilities can be read. Service and reset commands require a verified profile.'
                  : support.note,
            ),
          );
          try {
            printerJobs = await printerQueues.read(target);
            checks.add(
              ConnectionCheck(
                'Printer queue',
                '${printerJobs!.jobs.length} visible job(s)',
                printerJobs!.jobs.isEmpty && status.stateLabel != 'Ready'
                    ? 'An empty queue does not clear a device-level Busy state. Check the panel when nearby.'
                    : 'Jobs waiting on other computers or phones are not visible here.',
              ),
            );
          } catch (e) {
            checks.add(
              ConnectionCheck(
                'Printer queue',
                'Unavailable',
                CareController.cleanError(e),
                attention: true,
              ),
            );
          }
          if (support?.family == 'G7000 series') {
            InkCounterPeer? p;
            try {
              p = await inkFactory(target.uri.host);
              final identity = await p.identity(), counters = await p.read();
              diagnosticIdentity = identity;
              checks.add(
                ConnectionCheck(
                  'Canon status',
                  counters.ready ? 'Idle' : counters.state,
                  counters.supportCode.isEmpty
                      ? 'Direct Canon status read. No maintenance command sent.'
                      : 'Support code ${counters.supportCode}',
                  attention: !counters.ready,
                ),
              );
              if (p is CanonInkPeer) {
                try {
                  canonUsage = CanonUsage.parse(
                    await p.connection.exchange(CanonUsage.query),
                  );
                  checks.add(
                    ConnectionCheck(
                      'Reported usage',
                      canonUsage!.totalPages == null
                          ? 'Partial counters'
                          : '${canonUsage!.totalPages} total pages',
                      canonUsage!.summary,
                    ),
                  );
                } catch (e) {
                  checks.add(
                    ConnectionCheck(
                      'Reported usage',
                      'Unavailable',
                      CareController.cleanError(e),
                    ),
                  );
                }
              }
            } catch (e) {
              checks.add(
                ConnectionCheck(
                  'Canon status',
                  'Unavailable',
                  CareController.cleanError(e),
                  attention: true,
                ),
              );
            } finally {
              await p?.close();
            }
          }
        }
      }
      connectionChecks = checks;
      connectionCheckedAt = DateTime.now();
      currentLog!['checks'] = checks.map((v) => v.toJson()).toList();
      currentLog!['writeCommandsSent'] = 0;
      message = 'Connection checks saved. No printing, maintenance, or reset was started.';
    });
  }

  void trackDeviceIssue() {
    final identity = diagnosticIdentity;
    if (busy || identity == null || identity.serial.isEmpty) return;
    if (repairs.any((r) => r.serial == identity.serial && !r.verified)) {
      message = 'A follow-up for this printer is already saved.';
      notifyListeners();
      return;
    }
    final record = RepairRecord(
      id: 'repair-${DateTime.now().microsecondsSinceEpoch}',
      serial: identity.serial,
      model: identity.model,
      firmware: identity.firmware,
      createdAt: DateTime.now(),
      kind: 'deviceIssue',
    );
    try {
      repairStore.write(record);
      restoreRepairs();
      message =
          'Printer follow-up saved. Restart verification can be resumed later.';
    } catch (e) {
      lastError = CareController.cleanError(e);
    }
    notifyListeners();
  }

  void confirmRepairRestart(RepairRecord record) {
    if (busy || !repairs.contains(record)) return;
    record.confirmRestart();
    try {
      repairStore.write(record);
    } catch (e) {
      lastError = CareController.cleanError(e);
    }
    notifyListeners();
  }

  void confirmRepairDisplay(RepairRecord record, bool clear) {
    if (busy || !repairs.contains(record) || !record.restartConfirmed) return;
    record.displayClear = clear;
    try {
      repairStore.write(record);
    } catch (e) {
      lastError = CareController.cleanError(e);
    }
    notifyListeners();
  }

  Future<void> checkRepair(RepairRecord record) async {
    if (busy || networkRefreshing || !repairs.contains(record)) return;
    final target = selectedPrinter;
    if (target == null || !record.restartConfirmed) {
      lastError = 'Select the printer in Overview and confirm its normal Power-button restart first.';
      notifyListeners();
      return;
    }
    await run('repair verification', () async {
      InkCounterPeer? peer;
      record.identityMatched = false;
      record.ready = false;
      record.faultAbsent = false;
      record.checkedAt = DateTime.now();
      try {
        final status = await network.read(target);
        if (ModelSupport.find(status.model)?.family != record.model ||
            status.firmware != record.firmware) {
          throw StateError(
            'Model or firmware does not match the saved repair. No repair was marked verified.',
          );
        }
        peer = await inkFactory(target.uri.host);
        final identity = await peer.identity();
        if (identity.serial != record.serial ||
            identity.model != record.model ||
            identity.firmware != record.firmware) {
          throw StateError(
            'This is a different printer or firmware. The saved repair was not verified.',
          );
        }
        record.identityMatched = true;
        final counters = await peer.read();
        record.faultAbsent =
            counters.supportCode != '5B00' &&
            status.canon?.supportCode != '5B00';
        record.ready =
            counters.ready &&
            status.state == 3 &&
            status.stateLabel == 'Ready' &&
            status.attributes['printer-is-accepting-jobs']?.firstOrNull !=
                false;
        record.observation = record.ready && record.faultAbsent
            ? 'Same printer is idle and 5B00 is absent. Confirm its display below.'
            : 'Same printer reports ${status.stateLabel} / ${counters.state}${counters.supportCode.isEmpty ? '' : ' · ${counters.supportCode}'}. Check the panel; no recovery command was sent.';
        currentLog!['repairId'] = record.id;
        currentLog!['network'] = status.toJson();
        currentLog!['verified'] = record.verified;
        message = record.observation;
      } catch (e) {
        record.observation = CareController.cleanError(e);
        rethrow;
      } finally {
        await peer?.close();
        repairStore.write(record);
      }
    });
  }

  List<ServiceReport> get comparisonReports {
    final values = <ServiceReport>[...importedReports];
    if (report != null) values.add(report!);
    for (final entry in history) {
      try {
        if (entry['report'] is Map) {
          values.add(
            ServiceReport.fromJson(
              Map<String, dynamic>.from(entry['report'] as Map),
            ),
          );
        }
      } catch (_) {}
    }
    final unique = <String, ServiceReport>{};
    for (final value in values) {
      unique['${value.serial}/${value.capturedAt.toIso8601String()}/${value.sample}'] =
          value;
    }
    return unique.values.toList()
      ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
  }

  void addComparisonReports(String text) {
    final imported = importReports(text);
    final next = [...imported, ...importedReports].take(200).toList();
    final encoded = jsonEncode(next.map((r) => r.toJson()).toList());
    if (utf8.encode(encoded).length > 2 * 1024 * 1024) {
      throw const FormatException(
        'Saved comparison reports are limited to 2 MB.',
      );
    }
    final temp = File('${directory.path}/comparison-reports.tmp');
    temp.writeAsStringSync(encoded, flush: true);
    temp.renameSync('${directory.path}/comparison-reports.json');
    importedReports = next;
    message =
        '${imported.length} report(s) imported for comparison only. Live diagnostic and reset eligibility are unchanged.';
    notifyListeners();
  }

  void restoreComparisonReports() {
    final file = File('${directory.path}/comparison-reports.json');
    try {
      if (file.existsSync() && file.lengthSync() <= 2 * 1024 * 1024) {
        importedReports = importReports(file.readAsStringSync());
      }
    } catch (_) {
      /* A damaged import never grants live report eligibility. */
    }
  }

  String diagnosticSummary() {
    final status = networkStatus;
    final reportedModel = status?.text('printer-make-and-model');
    final model = reportedModel == null || reportedModel.isEmpty
        ? null
        : reportedModel;
    final reportedFirmware = status?.text('printer-firmware-string-version');
    final capabilities = <String, List<Object?>>{};
    for (final key in const [
      'document-format-supported',
      'sides-supported',
      'color-supported',
      'media-supported',
      'marker-types',
    ]) {
      final values = status?.attributes[key];
      if (values == null) continue;
      capabilities[key] = values.take(64).map((value) {
        if (value is String) {
          return value.length > 256 ? value.substring(0, 256) : value;
        }
        if (value is num || value is bool) return value;
        return 'Unrecognized value type';
      }).toList();
    }
    return redactedDiagnosticText(
      {
        'schemaVersion': 2,
        'application': '$applicationName $applicationVersion',
        'platform': {
          'system': Platform.operatingSystem,
          'version': Platform.operatingSystemVersion,
        },
        'hardwareValidation':
            'Only PIXMA G7020 firmware 1.050 has been hardware-tested.',
        'networkPrinter': status == null
            ? null
            : {
                'reportedModel': model,
                'firmware': reportedFirmware == null || reportedFirmware.isEmpty
                    ? null
                    : reportedFirmware,
                'capturedAt': status.capturedAt.toIso8601String(),
                'online': networkOnline,
                'state': status.stateLabel,
                'stateReasons': status.reasons,
                'supportCode': status.canon?.supportCode,
                'advertisedCapabilities': capabilities,
                'verifiedFirmwareProfile':
                    ModelSupport.find(status.model)
                        ?.matchesFirmware(status.firmware) ??
                    false,
              },
        'serviceReport': report == null
            ? null
            : {
                'family': 'G7000 series',
                'firmware': report!.firmware,
                'sample': report!.sample,
                'capturedAt': report!.capturedAt.toIso8601String(),
              },
        'currentErrors': {
          'operation': lastError,
          'network': networkError,
          'usb': usbError,
          'printerQueue': printerQueueError,
          'windowsQueue': windowsQueueError,
        },
        'recentOperations': history
            .take(20)
            .map(
              (entry) => {
                for (final key in const [
                  'kind',
                  'status',
                  'started',
                  'finished',
                  'counterClearAttempted',
                  'inkCounterAttempted',
                ])
                  if (entry[key] is String || entry[key] is bool)
                    key:
                        entry[key] is String &&
                            (entry[key] as String).length > 512
                        ? (entry[key] as String).substring(0, 512)
                        : entry[key],
                'failed': entry['error'] != null,
              },
            )
            .toList(),
        'checkedAt': connectionCheckedAt?.toIso8601String(),
        'reportedUsage': canonUsage?.toJson(),
        'checks': connectionChecks.map((v) => v.toJson()).toList(),
        'usbProducts': devices
            .map(
              (d) => {
                'product': ModelSupport.usbProduct(d['path'] as String),
                'service': d['service'] == true,
              },
            )
            .toList(),
        'repairs': repairs
            .map(
              (r) => {'kind': r.kind, 'stage': r.stage, 'firmware': r.firmware},
            )
            .toList(),
        'privacy': 'Raw packets, event data, job titles and document contents are not included. Known serial numbers, device names, USB paths and network addresses are redacted. Review before sharing.',
        'verification': 'Live status checks do not prove printed quality.',
      },
      identifiers: [
        ...knownDiagnosticIdentifiers([currentLog, ...history]),
        if (diagnosticIdentity != null) diagnosticIdentity!.serial,
        if (report != null) report!.serial,
        if (status != null) ...[
          status.serial,
          status.identity,
          status.target.key,
          status.target.uri.host,
          if (status.name != model) status.name,
        ],
        if (selectedPrinter != null) selectedPrinter!.uri.host,
        if (selectedPrinter != null) selectedPrinter!.discoveryId,
        for (final target in networkPrinters) ...[
          target.key,
          target.uri.host,
          target.discoveryId,
          if (target.discoveredName != model) target.discoveredName,
        ],
        for (final queue in [printerJobs, windowsJobs])
          for (final job in queue?.jobs ?? <QueueJob>[]) ...[
            job.title,
            job.owner,
            job.uri,
          ],
        ...repairs.map((r) => r.serial),
      ],
    );
  }
}
