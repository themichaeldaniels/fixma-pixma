import 'dart:convert';
import 'dart:io';

/// Evidence for a single waste-counter attempt. This record cannot dispatch a
/// command and never removes the existing one-shot reset guard.
class RepairRecord {
  final String id, serial, model, firmware, kind;
  final DateTime createdAt;
  DateTime updatedAt;
  final double? beforeCounter;
  double? afterCounter;
  bool acknowledged = false,
      restartConfirmed = false,
      displayClear = false,
      printChecked = false,
      identityMatched = false,
      ready = false,
      faultAbsent = false;
  String observation = 'No normal-mode check yet.';
  DateTime? checkedAt;
  RepairRecord({
    required this.id,
    required this.serial,
    required this.model,
    required this.firmware,
    required this.createdAt,
    this.beforeCounter,
    this.kind = 'wasteCounter',
  }) : updatedAt = createdAt;

  String get stage => kind == 'wasteCounter' && !acknowledged
      ? 'Result uncertain'
      : !restartConfirmed
      ? 'Restart pending'
      : checkedAt == null
      ? 'Status check pending'
      : !(identityMatched && ready && faultAbsent)
      ? 'Needs attention'
      : !displayClear
      ? 'Display check pending'
      : kind == 'deviceIssue'
      ? 'Printer status clear'
      : 'Fault cleared';
  bool get verified =>
      stage == 'Fault cleared' || stage == 'Printer status clear';
  void confirmRestart() {
    restartConfirmed = true;
    // A status read made before the declared restart cannot verify it.
    checkedAt = null;
    identityMatched = false;
    ready = false;
    faultAbsent = false;
    displayClear = false;
    printChecked = false;
    observation = 'Read this printer again after restart.';
  }

  Map<String, dynamic> toJson() => {
    'schema': 1,
    'id': id,
    'serial': serial,
    'model': model,
    'firmware': firmware,
    'kind': kind,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'beforeCounter': beforeCounter,
    'afterCounter': afterCounter,
    'acknowledged': acknowledged,
    'restartConfirmed': restartConfirmed,
    'displayClear': displayClear,
    'printChecked': printChecked,
    'identityMatched': identityMatched,
    'ready': ready,
    'faultAbsent': faultAbsent,
    'observation': observation,
    'checkedAt': checkedAt?.toIso8601String(),
    'stage': stage,
  };
  factory RepairRecord.fromJson(Map<String, dynamic> v) {
    if (v['schema'] != 1 ||
        !RegExp(r'^repair-[0-9]+$').hasMatch(v['id'] as String? ?? '') ||
        (v['serial'] as String? ?? '').isEmpty) {
      throw const FormatException('Invalid repair record.');
    }
    final r = RepairRecord(
      id: v['id'] as String,
      serial: v['serial'] as String,
      model: v['model'] as String,
      firmware: v['firmware'] as String,
      createdAt: DateTime.parse(v['createdAt'] as String),
      beforeCounter: (v['beforeCounter'] as num?)?.toDouble(),
      kind: v['kind'] == 'deviceIssue' ? 'deviceIssue' : 'wasteCounter',
    );
    r.updatedAt = DateTime.parse(v['updatedAt'] as String);
    r.afterCounter = (v['afterCounter'] as num?)?.toDouble();
    r.acknowledged = v['acknowledged'] == true;
    r.restartConfirmed = v['restartConfirmed'] == true;
    r.displayClear = v['displayClear'] == true;
    r.printChecked = v['printChecked'] == true;
    r.identityMatched = v['identityMatched'] == true;
    r.ready = v['ready'] == true;
    r.faultAbsent = v['faultAbsent'] == true;
    r.observation = v['observation'] as String? ?? '';
    r.checkedAt = DateTime.tryParse(v['checkedAt'] as String? ?? '');
    return r;
  }
}

class RepairStore {
  final Directory directory;
  RepairStore(this.directory);
  void write(RepairRecord value) {
    if (!RegExp(r'^repair-[0-9]+$').hasMatch(value.id)) {
      throw const FormatException('Invalid repair ID');
    }
    directory.createSync(recursive: true);
    value.updatedAt = DateTime.now();
    // Keep the last complete file if an interruption occurs while writing.
    final temp = File('${directory.path}/${value.id}.tmp');
    temp.writeAsStringSync(jsonEncode(value.toJson()), flush: true);
    temp.renameSync('${directory.path}/${value.id}.json');
  }

  List<RepairRecord> read() {
    if (!directory.existsSync()) return [];
    final files =
        directory
            .listSync(followLinks: false)
            .whereType<File>()
            .where(
              (f) =>
                  RegExp(r'^repair-[0-9]+\.json$')
                      .hasMatch(f.uri.pathSegments.last),
            )
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    final result = <RepairRecord>[];
    for (final f in files.take(200)) {
      try {
        if (f.lengthSync() > 65536) continue;
        result.add(
          RepairRecord.fromJson(
            jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
          ),
        );
      } catch (_) {
        /* One damaged record must not hide other repairs. */
      }
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }
}
