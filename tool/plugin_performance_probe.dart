import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_server_proxy/dart_analysis_server_proxy.dart';

// Research harness only. Uses existing tools and the unmodified SDK language server.
Future<void> main(List<String> args) async {
  final root = Directory(args.single).absolute.path;
  final workspace = Directory.current.parent.path;
  final dana = '$workspace/dart_analysis_daemon/bin/dart_analysis_daemon.dart';
  final dart = Platform.resolvedExecutable;
  final leafPath =
      Directory(root).uri.resolve('lib/unit_4999.dart').toFilePath();
  final records = <Map<String, Object?>>[];
  void record(Map<String, Object?> value) {
    records.add(value);
    stdout.writeln(jsonEncode(value));
  }

  Future<Map> cli(String label, List<String> arguments) async {
    final watch = Stopwatch()..start();
    final result = await Process.run(dart, arguments, workingDirectory: root);
    watch.stop();
    Map data = {};
    try {
      data = jsonDecode(result.stdout as String) as Map;
    } catch (_) {}
    record({
      'scenario': label,
      'wallMs': watch.elapsedMilliseconds,
      'exitCode': result.exitCode,
      for (final key in [
        'ok',
        'error',
        'stack',
        'elapsedMs',
        'files',
        'errors',
        'warnings',
        'infos',
      ])
        if (data.containsKey(key)) key: data[key],
      if (data['diagnostics'] is Map)
        'diagnosticFiles': (data['diagnostics'] as Map).length,
      if ((result.stderr as String).isNotEmpty) 'stderr': result.stderr,
      if (result.exitCode > 1) 'stdout': result.stdout,
    });
    if (result.exitCode > 1) throw StateError('Failed: $label');
    return data;
  }

  List<String> check(String mode, String reuse) => [
    dana,
    'check',
    '--root',
    root,
    '--mode',
    mode,
    '--reuse-ide',
    reuse,
    if (mode == 'fast') ...['--files', leafPath],
  ];

  Future<Map> request(File endpointFile, Map<String, Object?> command) async {
    final endpoint = jsonDecode(await endpointFile.readAsString()) as Map;
    final socket = await Socket.connect(
      endpoint['address'],
      endpoint['port'],
      timeout: const Duration(seconds: 2),
    );
    try {
      final response =
          socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first;
      socket.writeln(jsonEncode({...command, 'token': endpoint['token']}));
      await socket.flush();
      return jsonDecode(await response.timeout(const Duration(minutes: 5)))
          as Map;
    } finally {
      socket.destroy();
    }
  }

  final daemonEndpoint = File('$root/.dart_tool/ai-analyzer-session.json');
  final bridgeEndpoint = File('$root/.dart_tool/dana-ide-bridge.json');
  Process? proxy;
  Process? daemon;
  final pending = <int, Completer<Map>>{};
  var nextId = 1;
  try {
    record({
      'scenario': 'environment',
      'dart': Platform.version,
      'root': root,
      'options': await File('$root/analysis_options.yaml').readAsString(),
      'fileCount': Directory('$root/lib').listSync().whereType<File>().length,
    });
    for (var i = 1; i <= 2; i++) {
      await cli('standalone_$i', ['analyze', '--format=machine']);
    }
    final coldWatch = Stopwatch()..start();
    daemon = await Process.start(dart, [
      dana,
      'serve',
      '--root',
      root,
    ], workingDirectory: root);
    daemon.stdout.transform(utf8.decoder).listen((line) => stderr.write(line));
    final ready = Completer<void>();
    daemon.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          stderr.writeln(line);
          if (line.contains('session ready:') && !ready.isCompleted) {
            ready.complete();
          }
        });
    await ready.future.timeout(const Duration(minutes: 5));
    await cli('daemon_initial_full', check('full', 'never'));
    record({
      'scenario': 'daemon_process_cold_with_initial_full',
      'wallMs': coldWatch.elapsedMilliseconds,
    });
    for (var i = 1; i <= 3; i++) {
      await cli('daemon_hot_fast_$i', check('fast', 'never'));
      await cli('daemon_hot_full_$i', check('full', 'never'));
    }
    final leaf = leafPath;
    final original = await File(leaf).readAsString();
    for (final invalid in [true, false]) {
      final watch = Stopwatch()..start();
      final result = await request(daemonEndpoint, {
        'op': 'check',
        'files': [
          {
            'path': leaf,
            'content':
                invalid ? '$original\nint probe = missingProbe;\n' : original,
          },
        ],
      });
      final full = await request(daemonEndpoint, {'op': 'fullCheck'});
      watch.stop();
      record({
        'scenario': invalid ? 'daemon_overlay_error' : 'daemon_overlay_restore',
        'wallMs': watch.elapsedMilliseconds,
        'fastErrors': result['errors'],
        'fullErrors': full['errors'],
        'fullFiles': full['files'],
        if (result['ok'] != true) 'failure': result,
      });
      if (result['errors'] != (invalid ? 1 : 0) ||
          full['errors'] != (invalid ? 1 : 0)) {
        throw StateError('Overlay diagnostics mismatch');
      }
    }
    await request(daemonEndpoint, {
      'op': 'clearContent',
      'files': [leaf],
    });
    await cli('daemon_stop', [dana, 'stop', '--root', root]);
    await daemon.exitCode.timeout(const Duration(seconds: 15));
    daemon = null;

    if (await bridgeEndpoint.exists()) {
      throw StateError('Existing bridge; leave it untouched');
    }
    final startWatch = Stopwatch()..start();
    proxy = await Process.start(dart, [
      '$workspace/analysis_server_proxy/bin/dana_analysis_server_proxy.dart',
      '--upstream-executable',
      dart,
      '--',
      '--lsp',
    ], workingDirectory: root);
    final child = proxy;
    child.stderr.transform(utf8.decoder).listen((line) => stderr.write(line));
    child.stdout.transform(LspMessageReader()).listen((message) {
      final data = jsonDecode(message.body) as Map;
      final id = data['id'];
      if (data.containsKey('method') && id != null) {
        child.stdin.add(
          encodeLspMessage(
            jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': null}),
          ),
        );
      } else if (id is int) {
        pending.remove(id)?.complete(data);
      }
    });
    Future<Map> lsp(String method, Object? params) async {
      final id = nextId++;
      final done = pending[id] = Completer<Map>();
      child.stdin.add(
        encodeLspMessage(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'method': method,
            'params': params,
          }),
        ),
      );
      await child.stdin.flush();
      return done.future.timeout(const Duration(minutes: 5));
    }

    void notify(String method, Object? params) {
      child.stdin.add(
        encodeLspMessage(
          jsonEncode({'jsonrpc': '2.0', 'method': method, 'params': params}),
        ),
      );
    }

    await lsp('initialize', {
      'processId': pid,
      'rootUri': Directory(root).uri.toString(),
      'capabilities': {},
      'initializationOptions': {'onlyAnalyzeProjectsWithOpenFiles': false},
      'workspaceFolders': [
        {'uri': Directory(root).uri.toString(), 'name': 'benchmark'},
      ],
    });
    notify('initialized', {});
    await child.stdin.flush();
    await cli('proxy_initial_full', check('full', 'require'));
    record({
      'scenario': 'proxy_process_cold_with_initial_full',
      'wallMs': startWatch.elapsedMilliseconds,
    });
    for (var i = 1; i <= 3; i++) {
      await cli('proxy_hot_fast_$i', check('fast', 'require'));
      await cli('proxy_hot_full_$i', check('full', 'require'));
    }
    final uri = File(leaf).uri.toString();
    notify('textDocument/didOpen', {
      'textDocument': {
        'uri': uri,
        'languageId': 'dart',
        'version': 1,
        'text': '$original\nint probe = missingProbe;\n',
      },
    });
    await child.stdin.flush();
    final bad = await cli('proxy_overlay_error_full', check('full', 'require'));
    notify('textDocument/didChange', {
      'textDocument': {'uri': uri, 'version': 2},
      'contentChanges': [
        {'text': original},
      ],
    });
    await child.stdin.flush();
    final clean = await cli(
      'proxy_overlay_restore_full',
      check('full', 'require'),
    );
    if (bad['errors'] != 1 || clean['errors'] != 0) {
      throw StateError('Proxy overlay mismatch');
    }
    notify('textDocument/didClose', {
      'textDocument': {'uri': uri},
    });
    await lsp('shutdown', null);
    notify('exit', null);
    await child.stdin.flush();
    await child.stdin.close();
    try {
      await child.exitCode.timeout(const Duration(seconds: 15));
      record({'scenario': 'proxy_shutdown', 'graceful': true});
      proxy = null;
    } on TimeoutException {
      record({
        'scenario': 'proxy_shutdown',
        'graceful': false,
        'note':
            'Timed out after shutdown/exit; cleanup will terminate the owned process.',
      });
    }
  } finally {
    if (proxy != null) {
      await proxy.stdin.close();
      try {
        await proxy.exitCode.timeout(const Duration(seconds: 15));
      } catch (_) {
        proxy.kill();
      }
    }
    if (await daemonEndpoint.exists()) {
      try {
        await request(daemonEndpoint, {'op': 'shutdown'});
      } catch (_) {}
    }
    if (daemon != null) {
      try {
        await daemon.exitCode.timeout(const Duration(seconds: 15));
      } catch (_) {
        daemon.kill();
      }
    }
    final output = File(
      '$workspace/benchmarks/minimal-plugin/probe-results-2026-10-16.json',
    );
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert(records),
    );
    stdout.writeln('Saved ${output.path}');
  }
}
