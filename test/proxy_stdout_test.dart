@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_server_proxy/dart_analysis_server_proxy.dart';
import 'package:test/test.dart';

import 'support/random_frames.dart';

const _proxy = 'test/fixtures/proxy_driver.dart';
const _fakeUpstream = 'test/fixtures/fake_upstream.dart';
final _sep = Platform.pathSeparator;

/// Everything a proxy run produced on its standard streams.
class _Run {
  _Run(this.exitCode, this.stdoutBytes, this.stderrText);

  final int exitCode;
  final List<int> stdoutBytes;
  final String stderrText;
}

Future<_Run> _runProxy(
  List<String> proxyArguments,
  List<String> upstreamArguments, {
  Map<String, String>? environment,
  Future<void> Function(Process proxy, Stream<LspMessage> responses)? drive,
}) async {
  final proxy = await Process.start(Platform.resolvedExecutable, [
    _proxy,
    ...proxyArguments,
    ...upstreamArguments,
  ], environment: environment);
  final stdoutBytes = <int>[];
  final responses = StreamController<LspMessage>.broadcast();
  final decoder = StreamController<List<int>>();
  final decoded = decoder.stream
      .transform(LspMessageReader())
      .listen(responses.add, onError: responses.addError);
  final stdoutDone =
      proxy.stdout.listen((chunk) {
        stdoutBytes.addAll(chunk);
        decoder.add(chunk);
      }).asFuture<void>();
  final stderrText = proxy.stderr.transform(utf8.decoder).join();

  if (drive != null) {
    await drive(proxy, responses.stream);
  } else {
    await proxy.stdin.close();
  }
  final exitCode = await proxy.exitCode.timeout(const Duration(seconds: 60));
  await stdoutDone;
  await decoder.close();
  await decoded.cancel();
  await responses.close();
  return _Run(exitCode, stdoutBytes, await stderrText);
}

/// Property 6: stdout decodes as LSP frames whose bodies are all JSON.
Future<List<Object?>> _expectPureStdout(List<int> bytes) async {
  final outcome = await decodeChunks([bytes]);
  expect(outcome.error, isNull, reason: 'stdout must contain only LSP frames');
  return [for (final message in outcome.messages) jsonDecode(message.body)];
}

void main() {
  final dart = Platform.resolvedExecutable;

  test('forwards frames and keeps upstream stderr off stdout', () async {
    final run = await _runProxy(
      [_fakeUpstream, dart],
      ['echo'],
      drive: (proxy, responses) async {
        final answered = responses.firstWhere(
          (message) => (jsonDecode(message.body) as Map)['id'] == 1,
        );
        proxy.stdin.add(
          encodeLspMessage(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'initialize',
              'params': <String, Object?>{},
            }),
          ),
        );
        await proxy.stdin.flush();
        await answered.timeout(const Duration(seconds: 60));
        proxy.stdin.add(
          encodeLspMessage(jsonEncode({'jsonrpc': '2.0', 'method': 'exit'})),
        );
        await proxy.stdin.close();
      },
    );

    expect(run.exitCode, 0, reason: run.stderrText);
    final bodies = await _expectPureStdout(run.stdoutBytes);
    expect(bodies, [
      {
        'jsonrpc': '2.0',
        'method': 'window/logMessage',
        'params': {'type': 3, 'message': '分析 initialize 😀'},
      },
      {
        'jsonrpc': '2.0',
        'id': 1,
        'result': {'echo': 'initialize'},
      },
    ]);
    expect(run.stderrText, contains('[upstreamStderr] fake upstream ready'));
    expect(run.stderrText, isNot(contains('[upstreamExited]')));
    expect(run.stderrText, isNot(contains('[upstreamStartFailed]')));
  });

  test('logs an upstream launch failure to stderr only', () async {
    final missing = '${Directory.systemTemp.path}${_sep}no-such-dart-runtime';
    final run = await _runProxy([_fakeUpstream, missing], ['echo']);

    expect(run.exitCode, isNot(0));
    expect(run.stdoutBytes, isEmpty);
    expect(run.stderrText, contains('[upstreamStartFailed]'));
    expect(run.stderrText, contains(missing));
  });

  group('upstream crash', () {
    late Directory scratch;

    setUp(() async {
      await Directory('build').create();
      scratch = await Directory('build').createTemp('proxy_stdout_');
    });

    tearDown(() async {
      if (await scratch.exists()) await scratch.delete(recursive: true);
    });

    test('logs stderr and the exit code, and mirrors DANA_PROXY_LOG', () async {
      final logFile = File('${scratch.path}${_sep}proxy.log');
      final run = await _runProxy(
        [_fakeUpstream, dart],
        ['crash'],
        environment: {'DANA_PROXY_LOG': logFile.path},
      );

      expect(run.exitCode, 3);
      expect(await _expectPureStdout(run.stdoutBytes), isEmpty);
      final records = [
        '[upstreamStderr] boom: upstream failed',
        '[upstreamStderr] second stderr line',
        '[upstreamExited] code=3',
      ];
      for (final record in records) {
        expect(run.stderrText, contains(record));
      }
      final logged = await logFile.readAsString();
      for (final record in records) {
        expect(logged, contains(record));
      }
    });
  });
}
