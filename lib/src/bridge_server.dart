import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

typedef BridgeRequestHandler =
    Future<Map<String, Object?>> Function(
      String root,
      Map<String, Object?> request,
    );

class BridgeServer {
  BridgeServer(this.onRequest);

  final BridgeRequestHandler onRequest;
  final _clients = <Socket>{};
  final _rootsByToken = <String, String>{};
  final _endpoints = <File>[];
  ServerSocket? _server;

  Future<void> start({
    required Iterable<String> roots,
    required bool fullCheck,
  }) async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    for (final root in roots.toSet()) {
      final token = _randomToken();
      _rootsByToken[token] = root;
      final endpoint = File(
        '${Directory(root).path}${Platform.pathSeparator}.dart_tool'
        '${Platform.pathSeparator}dana-ide-bridge.json',
      );
      await endpoint.parent.create(recursive: true);
      final metadata = jsonEncode({
        'protocol': 1,
        'transport': 'loopback',
        'root': root,
        'address': InternetAddress.loopbackIPv4.address,
        'port': _server!.port,
        'token': token,
        'pid': pid,
        'owner': 'dana-analysis-server-proxy',
        'capabilities': {
          'fastCheck': true,
          'fullCheck': fullCheck,
          'status': true,
          'overlay': false,
        },
      });
      final temporary = File('${endpoint.path}.$pid.tmp');
      await temporary.writeAsString(metadata);
      await temporary.rename(endpoint.path);
      _endpoints.add(endpoint);
    }
    _server!.listen(_listen);
  }

  Future<void> close() async {
    await _server?.close();
    for (final client in _clients.toList()) {
      client.destroy();
    }
    _clients.clear();
    for (final endpoint in _endpoints) {
      if (await endpoint.exists()) await endpoint.delete();
    }
  }

  void _listen(Socket socket) {
    _clients.add(socket);
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) async {
            if (line.trim().isEmpty) return;
            Map<String, Object?> response;
            try {
              final value = jsonDecode(line);
              final token = value is Map ? value['token'] : null;
              final root = token is String ? _rootsByToken[token] : null;
              if (value is! Map || root == null) {
                response = {'ok': false, 'error': 'Invalid bridge token'};
              } else {
                final request = Map<String, Object?>.from(value)
                  ..remove('token');
                response = await onRequest(root, request);
              }
            } catch (error) {
              response = {'ok': false, 'error': '$error'};
            }
            socket.writeln(jsonEncode(response));
            await socket.flush();
          },
          onDone: () {
            _clients.remove(socket);
            socket.destroy();
          },
          onError: (_) {
            _clients.remove(socket);
            socket.destroy();
          },
        );
  }
}

String _randomToken() {
  final random = Random.secure();
  return List<String>.generate(
    32,
    (_) => random.nextInt(16).toRadixString(16),
  ).join();
}
