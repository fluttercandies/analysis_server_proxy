import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_server_proxy/dart_analysis_server_proxy.dart';

Future<void> main() async {
  final workspace = Directory.current.absolute.path;
  final analyzerPath = Platform.environment['DANA_SMOKE_ANALYZER_PATH'];
  if (analyzerPath == null || !await File(analyzerPath).exists()) {
    throw StateError('Set DANA_SMOKE_ANALYZER_PATH to a compiled proxy .dill.');
  }
  final project = await Directory.systemTemp.createTemp('dana-e2e-smoke-');
  final secondProject = await Directory.systemTemp.createTemp(
    'dana-e2e-second-',
  );
  await File(
    '${project.path}${Platform.pathSeparator}pubspec.yaml',
  ).writeAsString('name: dana_e2e_smoke\nenvironment:\n  sdk: ^3.7.0\n');
  await File(
    '${project.path}${Platform.pathSeparator}main.dart',
  ).writeAsString('void main() { print(unknownName); }\n');
  await File(
    '${secondProject.path}${Platform.pathSeparator}pubspec.yaml',
  ).writeAsString('name: dana_e2e_second\nenvironment:\n  sdk: ^3.7.0\n');
  await File(
    '${secondProject.path}${Platform.pathSeparator}main.dart',
  ).writeAsString('void main() {}\n');
  final process = await Process.start(Platform.resolvedExecutable, [
    analyzerPath,
    '--lsp',
  ]);
  final messages =
      process.stdout.transform(LspMessageReader()).asBroadcastStream();
  final stderrLines = <String>[];
  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(stderrLines.add);
  final rootUri = project.uri.toString();
  process.stdin.add(
    encodeLspMessage(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'processId': pid,
          'rootUri': rootUri,
          'capabilities': <String, Object?>{},
          'workspaceFolders': [
            {'uri': rootUri, 'name': 'smoke'},
            {'uri': secondProject.uri.toString(), 'name': 'second'},
          ],
        },
      }),
    ),
  );
  await process.stdin.flush();
  await messages
      .map((message) => jsonDecode(message.body) as Map)
      .firstWhere((message) => message['id'] == 1)
      .timeout(const Duration(seconds: 30));
  process.stdin.add(
    encodeLspMessage(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'initialized',
        'params': <String, Object?>{},
      }),
    ),
  );
  await process.stdin.flush();
  final endpoint = File(
    '${project.path}${Platform.pathSeparator}.dart_tool'
    '${Platform.pathSeparator}dana-ide-bridge.json',
  );
  for (var attempt = 0; !await endpoint.exists() && attempt < 40; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  if (!await endpoint.exists()) {
    throw StateError('bridge endpoint was not created; stderr: $stderrLines');
  }
  final endpointMetadata = jsonDecode(await endpoint.readAsString()) as Map;
  final status = await _bridgeRequest(endpointMetadata, {
    'token': endpointMetadata['token'],
    'op': 'status',
  });
  if (status['ok'] != true ||
      status['root'] is! String ||
      !_samePath(status['root'] as String, project.path)) {
    throw StateError('bridge status did not select the expected root: $status');
  }
  final invalidToken = await _bridgeRequest(endpointMetadata, {
    'token': 'not-the-bridge-token',
    'op': 'status',
  });
  if (invalidToken['ok'] != false) {
    throw StateError('bridge accepted an invalid token: $invalidToken');
  }
  final dana = _findDanaEntry(workspace);
  final check = await Process.run(Platform.resolvedExecutable, [
    dana,
    'check',
    '--root',
    project.path,
    '--mode',
    'full',
    '--reuse-ide',
    'require',
  ]);
  if (check.exitCode != 1) {
    throw StateError(
      'dana bridge check failed (${check.exitCode}):\n${check.stdout}\n${check.stderr}',
    );
  }
  final result = jsonDecode(check.stdout as String) as Map;
  if ((result['errors'] as num?) == null || (result['errors'] as num) < 1) {
    throw StateError('expected analyzer error, got: $result');
  }
  final secondCheck = await Process.run(Platform.resolvedExecutable, [
    dana,
    'check',
    '--root',
    secondProject.path,
    '--mode',
    'full',
    '--reuse-ide',
    'require',
  ]);
  if (secondCheck.exitCode != 0) {
    throw StateError(
      'second-root full check leaked diagnostics (${secondCheck.exitCode}):\n'
      '${secondCheck.stdout}\n${secondCheck.stderr}',
    );
  }
  final source = File('${project.path}${Platform.pathSeparator}main.dart');
  await source.writeAsString('void main() {}\n');
  final fastCheck = await Process.run(Platform.resolvedExecutable, [
    dana,
    'check',
    '--root',
    project.path,
    '--mode',
    'fast',
    '--reuse-ide',
    'require',
    '--files',
    source.path,
  ]);
  if (fastCheck.exitCode != 0) {
    throw StateError(
      'dana fast bridge check failed (${fastCheck.exitCode}):\n'
      '${fastCheck.stdout}\n${fastCheck.stderr}',
    );
  }
  final fastResult = jsonDecode(fastCheck.stdout as String) as Map;
  if (fastResult['errors'] != 0) {
    throw StateError('expected no fast-check errors, got: $fastResult');
  }
  process.kill();
  await process.exitCode.timeout(const Duration(seconds: 10));
  if (await project.exists()) await project.delete(recursive: true);
  if (await secondProject.exists()) await secondProject.delete(recursive: true);
  stdout.writeln('end-to-end bridge smoke passed');
}

Future<Map> _bridgeRequest(Map endpoint, Map<String, Object?> request) async {
  final socket = await Socket.connect(
    endpoint['address'] as String,
    endpoint['port'] as int,
  );
  try {
    final response =
        utf8.decoder.bind(socket).transform(const LineSplitter()).first;
    socket.writeln(jsonEncode(request));
    return jsonDecode(await response.timeout(const Duration(seconds: 10)))
        as Map;
  } finally {
    await socket.close();
  }
}

bool _samePath(String first, String second) {
  return Directory(first).resolveSymbolicLinksSync() ==
      Directory(second).resolveSymbolicLinksSync();
}

String _findDanaEntry(String workspace) {
  final configured = Platform.environment['DANA_ENTRYPOINT'];
  if (configured != null && configured.isNotEmpty) {
    final entry = File(configured).absolute;
    if (entry.existsSync()) return entry.path;
    throw StateError('DANA_ENTRYPOINT does not exist: ${entry.path}');
  }

  final parent = Directory(workspace).parent;
  final candidates = <String>[];
  for (final entity in parent.listSync(followLinks: false)) {
    if (entity is! Directory) continue;
    final entry = File(
      '${entity.path}${Platform.pathSeparator}bin'
      '${Platform.pathSeparator}dart_analysis_daemon.dart',
    );
    if (entry.existsSync()) candidates.add(entry.path);
  }
  if (candidates.length == 1) return candidates.single;
  throw StateError(
    'Could not uniquely locate the dana entrypoint. Set DANA_ENTRYPOINT. '
    'Candidates: $candidates',
  );
}
