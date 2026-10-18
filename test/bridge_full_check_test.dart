@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_server_proxy/dart_analysis_server_proxy.dart';
import 'package:test/test.dart';

const _fakeUpstream = 'test/fixtures/fake_upstream.dart';

/// A proxy running in-process against the fake upstream, with an IDE side
/// driven by the test.
class _Harness {
  _Harness._(this.root, this._input, this._done);

  final Directory root;
  final StreamController<List<int>> _input;
  final Future<int> _done;

  static Future<_Harness> start(
    String mode, {
    required Duration settle,
    required Duration limit,
    List<Directory> workspaceRoots = const [],
  }) async {
    await Directory('build').create();
    final root = (await Directory('build').createTemp('bridge_full_')).absolute;
    await File('${root.path}/pubspec.yaml').writeAsString('name: fixture\n');
    final input = StreamController<List<int>>();
    final output = StreamController<List<int>>();
    unawaited(output.stream.drain<void>());
    final proxy = LspProxy.languageServer(
      startUpstream:
          (arguments) => Process.start(Platform.resolvedExecutable, [
            _fakeUpstream,
            ...arguments,
          ]),
      fullCheckSettle: settle,
      fullCheckSettleLimit: limit,
    );
    final done = proxy.run(
      [mode],
      input: input.stream,
      output: IOSink(output.sink),
      errorOutput: IOSink(StreamController<List<int>>()..stream.drain<void>()),
    );
    final rootUri = Uri.file(root.path).toString();
    void send(Map<String, Object?> json) =>
        input.add(encodeLspMessage(jsonEncode({'jsonrpc': '2.0', ...json})));
    send({
      'id': 1,
      'method': 'initialize',
      'params': {
        'rootUri': rootUri,
        'workspaceFolders': [
          {'uri': rootUri, 'name': 'root'},
          for (final workspaceRoot in workspaceRoots)
            {
              'uri': Uri.file(workspaceRoot.path).toString(),
              'name': 'additional root',
            },
        ],
      },
    });
    send({'method': 'initialized', 'params': <String, Object?>{}});
    return _Harness._(root, input, done);
  }

  File get endpoint => File('${root.path}/.dart_tool/dana-ide-bridge.json');

  Future<Map<String, Object?>> request(Map<String, Object?> body) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!endpoint.existsSync()) {
      if (DateTime.now().isAfter(deadline)) fail('bridge file never appeared');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final metadata =
        jsonDecode(await endpoint.readAsString()) as Map<String, Object?>;
    final socket = await Socket.connect(
      metadata['address'] as String,
      metadata['port'] as int,
    );
    socket.writeln(jsonEncode({...body, 'token': metadata['token']}));
    await socket.flush();
    final line =
        await socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first;
    socket.destroy();
    return jsonDecode(line) as Map<String, Object?>;
  }

  Future<void> stop() async {
    _input.add(
      encodeLspMessage(jsonEncode({'jsonrpc': '2.0', 'method': 'exit'})),
    );
    await _input.close();
    await _done.timeout(const Duration(seconds: 30));
    if (await root.exists()) await root.delete(recursive: true);
  }
}

List<String> _codes(Map<String, Object?> response) => [
  for (final diagnostics in (response['diagnostics'] as Map).values)
    for (final diagnostic in diagnostics as List)
      (diagnostic as Map)['code'] as String,
];

void main() {
  test('publishes bridge endpoints only for Dart workspace roots', () async {
    final nonDartRoot = await Directory.systemTemp.createTemp(
      'bridge_non_dart_',
    );
    final harness = await _Harness.start(
      'edit',
      settle: const Duration(milliseconds: 500),
      limit: const Duration(seconds: 20),
      workspaceRoots: [nonDartRoot],
    );
    try {
      await harness.request({'op': 'status'});
      expect(await harness.endpoint.exists(), isTrue);
      expect(
        await File(
          '${nonDartRoot.path}/.dart_tool/dana-ide-bridge.json',
        ).exists(),
        isFalse,
      );
    } finally {
      await harness.stop();
      await nonDartRoot.delete(recursive: true);
    }
  });

  test('fullCheck waits for diagnostics published after idle and never '
      'forces a reanalysis', () async {
    final harness = await _Harness.start(
      'diag',
      settle: const Duration(milliseconds: 1500),
      limit: const Duration(seconds: 20),
    );
    try {
      final response = await harness.request({'op': 'fullCheck'});
      expect(response['ok'], isTrue, reason: '$response');
      expect(response['source'], 'ide-bridge');
      expect(response['settled'], isTrue);
      expect(
        _codes(response),
        containsAll(['unused_import', 'late_plugin_lint']),
      );
      expect(response['files'], 2);
      expect(response['warnings'], 1);
      expect(response['infos'], 1);
    } finally {
      await harness.stop();
    }
  });

  test('fullCheck sees a Dart file edited just before the call and waits out '
      'a publish gap inside the pass', () async {
    final harness = await _Harness.start(
      'edit',
      settle: const Duration(seconds: 1),
      limit: const Duration(seconds: 20),
    );
    try {
      final baseline = await harness.request({'op': 'fullCheck'});
      expect(baseline['ok'], isTrue, reason: '$baseline');
      expect(_codes(baseline), isNot(contains('edited_error')));

      final edited = File('${harness.root.path}/lib/edited.dart');
      await edited.create(recursive: true);
      await edited.writeAsString('void main() {}\n');
      final response = await harness.request({'op': 'fullCheck'});
      expect(response['ok'], isTrue, reason: '$response');
      expect(response['settled'], isTrue);
      expect(_codes(response), contains('edited_error'));
      expect(response['errors'], 1);
    } finally {
      await harness.stop();
    }
  });

  test(
    'fullCheck without edits answers from the cache without a new pass',
    () async {
      final harness = await _Harness.start(
        'edit',
        settle: const Duration(milliseconds: 500),
        limit: const Duration(seconds: 20),
      );
      try {
        await harness.request({'op': 'fullCheck'});
        final watch = Stopwatch()..start();
        final response = await harness.request({'op': 'fullCheck'});
        watch.stop();
        expect(response['settled'], isTrue);
        expect(_codes(response), isNot(contains('edited_error')));
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      } finally {
        await harness.stop();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('settleLimitSeconds overrides the default limit per request', () async {
    final harness = await _Harness.start(
      'chatty',
      settle: const Duration(milliseconds: 800),
      limit: const Duration(minutes: 10),
    );
    try {
      final watch = Stopwatch()..start();
      final response = await harness.request({
        'op': 'fullCheck',
        'settleLimitSeconds': 2,
      });
      watch.stop();
      expect(response['ok'], isTrue, reason: '$response');
      expect(response['settled'], isFalse);
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    } finally {
      await harness.stop();
    }
  });

  test('an invalid settleLimitSeconds is rejected', () async {
    final harness = await _Harness.start(
      'diag',
      settle: const Duration(milliseconds: 300),
      limit: const Duration(seconds: 20),
    );
    try {
      for (final value in <Object>[0, -1, 3601, 1.5, '30']) {
        final response = await harness.request({
          'op': 'fullCheck',
          'settleLimitSeconds': value,
        });
        expect(response['ok'], isFalse, reason: 'value=$value $response');
        expect('${response['error']}', contains('settleLimitSeconds'));
      }
    } finally {
      await harness.stop();
    }
  });

  test(
    'fullCheck gives up at the settle limit and reports settled: false',
    () async {
      final harness = await _Harness.start(
        'chatty',
        settle: const Duration(milliseconds: 800),
        limit: const Duration(seconds: 2),
      );
      try {
        final watch = Stopwatch()..start();
        final response = await harness.request({'op': 'fullCheck'});
        watch.stop();
        expect(response['ok'], isTrue, reason: '$response');
        expect(response['settled'], isFalse);
        expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      } finally {
        await harness.stop();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
