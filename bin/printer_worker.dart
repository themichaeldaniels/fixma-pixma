// Native, isolated Windows I/O process. Only the verified service operations are allowed.
import 'dart:convert';
import 'dart:io';

import 'package:fixma_pixma/core/protocol.dart';
import 'package:fixma_pixma/platform/windows_usb.dart';

Future<void> main() async {
  if (!Platform.isWindows) {
    stderr.writeln('Windows only');
    exitCode = 2;
    return;
  }
  final usb = WindowsUsb();
  CanonCodec? codec;
  Map<String, dynamic>? profile;
  List<int>? keyword;
  ReplyAssembler? active;
  String? serial, firmware;
  var identityVerified = false,
      selectorOk = false,
      allowReset = false,
      clearSent = false;
  try {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      try {
        final request = jsonDecode(line) as Map<String, dynamic>;
        dynamic value;
        switch (request['op']) {
          case 'init':
            if (profile != null) throw StateError('Already initialized.');
            profile = Map<String, dynamic>.from(request['profile'] as Map);
            codec = CanonCodec(profile);
            allowReset = request['reset'] == true;
            value = true;
          case 'scan':
            value = usb
                .enumerate()
                .where((p) => p.toLowerCase().contains('vid_04a9&pid_'))
                .map(
                  (p) => {
                    'path': p,
                    'service': p.toLowerCase().contains('pid_12fe'),
                  },
                )
                .toList();
          case 'open':
            if (profile == null) throw StateError('Missing protocol profile.');
            final paths = usb
                .enumerate()
                .where((p) => p.toLowerCase().contains('vid_04a9&pid_12fe'))
                .toList();
            if (paths.length != 1) {
              throw StateError(
                paths.isEmpty
                    ? 'Put the printer in service mode and connect USB, then try again.'
                    : 'Connect just one Canon service-mode printer.',
              );
            }
            usb.open(paths.single);
            final id = latin1.decode(usb.ioctl(0x220034));
            final candidateSerial = RegExp(r'PSE:([^;]+);')
                .firstMatch(id)
                ?.group(1);
            final candidateFirmware = RegExp(r'VER:([^;]+);')
                .firstMatch(id)
                ?.group(1);
            if (!id.contains('MFG:Canon;') ||
                !id.contains('MDL:Device;') ||
                candidateSerial == null) {
              throw StateError('Unexpected Canon device identity.');
            }
            if (request['expectedSerial'] != null &&
                request['expectedSerial'] != candidateSerial) {
              throw StateError(
                'The connected printer differs from the diagnostic report.',
              );
            }
            final resolution = Map<String, dynamic>.from(
              profile['resolution'] as Map,
            );
            final version = usb.ioctl(0x22003c, [0x8a, 0, 0]);
            if (version.length != 20) throw StateError('Invalid model reply.');
            final model = latin1
                .decode(
                  CanonCodec(resolution).transform(
                    version,
                    List<int>.from(resolution['keyword'] as List),
                    decode: true,
                  ),
                )
                .split('\x00')
                .first;
            if (model != 'G7000 series') {
              throw StateError(
                'Only the G7020 / G7000 service profile is supported.',
              );
            }
            if (allowReset && candidateFirmware != '1.050') {
              throw StateError(
                'Reset is verified on firmware 1.050. Diagnostics remain available.',
              );
            }
            serial = candidateSerial;
            firmware = candidateFirmware;
            identityVerified = true;
            value = {'model': model, 'serial': serial, 'firmware': firmware};
          case 'session':
            if (!identityVerified || serial == null || keyword != null) {
              throw StateError('Invalid session state.');
            }
            usb.ioctl(0x220038, [0x81, 0, 0, 3], 0);
            keyword = usb.ioctl(0x22003c, [0x82, 0, 0]);
            if (keyword.length != 3) {
              throw StateError('The printer did not return a session keyword.');
            }
            value = {'keyword': hexOf(keyword)};
          case 'command':
            final operand = request['operand'] as String;
            if (keyword == null || active != null) {
              throw StateError('Invalid command state.');
            }
            if (!['10077c', '15', '0d0000'].contains(operand)) {
              throw StateError('Command not permitted.');
            }
            if (operand != '10077c' && !selectorOk) {
              throw StateError('Selector has not acknowledged success.');
            }
            if (operand == '0d0000') {
              if (!allowReset || clearSent || firmware != '1.050') {
                throw StateError('Counter clear is not permitted.');
              }
              clearSent = true;
            }
            final bytes = hexBytes(operand);
            active = ReplyAssembler(codec!, keyword, bytes.first);
            final frame = codec.encode(bytes, keyword);
            usb.ioctl(0x220038, frame, 0);
            value = {'frame': hexOf(frame)};
          case 'poll':
            if (active == null) throw StateError('No command is pending.');
            final raw = usb.ioctl(0x22003c, [0x86, 0, 0]);
            final reply = active.feed(raw);
            value = {
              'raw': hexOf(raw),
              'continuation': active.expected != null,
              'reply': reply == null
                  ? null
                  : {
                      'opcode': reply.opcode,
                      'status': reply.status,
                      'accepted': reply.accepted,
                      'reason': reply.reason,
                      'data': hexOf(reply.data),
                    },
            };
            if (reply != null) {
              if (reply.opcode == 0x10) selectorOk = reply.accepted;
              active = null;
            }
          case 'close':
            usb.close();
            stdout.writeln(jsonEncode({'ok': true, 'value': true}));
            return;
          default:
            throw StateError('Unknown operation.');
        }
        stdout.writeln(jsonEncode({'ok': true, 'value': value}));
      } catch (e) {
        stdout.writeln(jsonEncode({'ok': false, 'error': e.toString()}));
      }
    }
  } finally {
    usb.close();
  }
}
