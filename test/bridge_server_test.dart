import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_server_proxy/src/bridge_server.dart';
import 'package:test/test.dart';

void main() {
  test('publishes one authenticated endpoint per root', () async {
    final first = await Directory.systemTemp.createTemp('dana-bridge-first-');
    final second = await Directory.systemTemp.createTemp('dana-bridge-second-');
    final seenRoots = <String>[];
    final server = BridgeServer((root, request) async {
      seenRoots.add(root);
      return {'ok': true, 'root': root, 'op': request['op']};
    });

    try {
      await server.start(roots: [first.path, second.path], fullCheck: true);
      final endpoints =
          [first, second].map((root) {
            return File(
              '${root.path}${Platform.pathSeparator}.dart_tool'
              '${Platform.pathSeparator}dana-ide-bridge.json',
            );
          }).toList();
      final metadata = [
        for (final endpoint in endpoints)
          jsonDecode(await endpoint.readAsString()) as Map,
      ];
      expect(metadata[0]['port'], metadata[1]['port']);
      expect(metadata[0]['token'], isNot(metadata[1]['token']));
      expect(metadata[0]['capabilities']['fullCheck'], isTrue);

      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        metadata[0]['port'] as int,
      );
      final response =
          utf8.decoder.bind(socket).transform(const LineSplitter()).first;
      socket.writeln(
        jsonEncode({'token': metadata[0]['token'], 'op': 'status'}),
      );
      final decoded = jsonDecode(await response) as Map;
      expect(decoded['ok'], isTrue);
      expect(decoded['root'], first.path);
      expect(seenRoots, [first.path]);
      await socket.close();
    } finally {
      await server.close();
      await first.delete(recursive: true);
      await second.delete(recursive: true);
    }
  });

  test('rejects an unknown token', () async {
    final root = await Directory.systemTemp.createTemp('dana-bridge-token-');
    final server = BridgeServer((_, _) async => {'ok': true});
    try {
      await server.start(roots: [root.path], fullCheck: false);
      final endpoint = File(
        '${root.path}${Platform.pathSeparator}.dart_tool'
        '${Platform.pathSeparator}dana-ide-bridge.json',
      );
      final metadata = jsonDecode(await endpoint.readAsString()) as Map;
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        metadata['port'] as int,
      );
      final response =
          utf8.decoder.bind(socket).transform(const LineSplitter()).first;
      socket.writeln(jsonEncode({'token': 'wrong', 'op': 'status'}));
      expect(jsonDecode(await response), {
        'ok': false,
        'error': 'Invalid bridge token',
      });
      await socket.close();
    } finally {
      await server.close();
      await root.delete(recursive: true);
    }
  });
}
