import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_server_proxy/src/proxy_logger.dart';
import 'package:test/test.dart';

final _sep = Platform.pathSeparator;

/// An [IOSink] that records everything written to it.
class _MemorySink implements IOSink {
  final buffer = StringBuffer();

  @override
  Encoding encoding = utf8;

  @override
  void write(Object? object) => buffer.write(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory scratch;

  setUp(() async {
    await Directory('build').create();
    scratch = await Directory('build').createTemp('proxy_logger_');
  });

  tearDown(() async {
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  test('rejects stdout as the sink', () {
    expect(() => ProxyLogger(sink: stdout), throwsArgumentError);
  });

  test('writes one timestamped record per event to the sink', () {
    final sink = _MemorySink();
    final logger = ProxyLogger(sink: sink);
    for (final event in ProxyLogEvent.values) {
      logger.log(event, 'detail ${event.name}');
    }
    final lines = const LineSplitter().convert(sink.buffer.toString());
    expect(lines, hasLength(ProxyLogEvent.values.length));
    for (final (index, event) in ProxyLogEvent.values.indexed) {
      final match = RegExp(r'^(\S+) \[(\w+)\] (.*)$').firstMatch(lines[index]);
      expect(match, isNotNull, reason: lines[index]);
      expect(DateTime.tryParse(match!.group(1)!), isNotNull);
      expect(match.group(2), event.name);
      expect(match.group(3), 'detail ${event.name}');
    }
  });

  test('indents continuation lines of multi-line details', () {
    final sink = _MemorySink();
    ProxyLogger(
      sink: sink,
    ).log(ProxyLogEvent.upstreamStartFailed, 'error\n#0 frame\n#1 frame\n');
    final lines = const LineSplitter().convert(sink.buffer.toString());
    expect(lines, hasLength(3));
    expect(lines[0], endsWith('[upstreamStartFailed] error'));
    expect(lines.skip(1), everyElement(startsWith('  #')));
  });

  test('does not touch disk unless DANA_PROXY_LOG is set', () {
    final logger = ProxyLogger.fromEnvironment(
      sink: _MemorySink(),
      environment: const {},
    );
    expect(logger.filePath, isNull);
    expect(
      ProxyLogger.fromEnvironment(
        sink: _MemorySink(),
        environment: const {'DANA_PROXY_LOG': ''},
      ).filePath,
      isNull,
    );
  });

  test('appends records to DANA_PROXY_LOG as well as the sink', () async {
    final path = '${scratch.path}${_sep}proxy.log';
    await File(path).writeAsString('existing\n');
    final sink = _MemorySink();
    final logger = ProxyLogger.fromEnvironment(
      sink: sink,
      environment: {'DANA_PROXY_LOG': path},
    );
    logger.log(ProxyLogEvent.upstreamExited, 'code=3');
    logger.log(ProxyLogEvent.frameError, 'bad frame');

    final file = await File(path).readAsString();
    expect(file, startsWith('existing\n'));
    expect(file.substring('existing\n'.length), sink.buffer.toString());
    expect(file, contains('[upstreamExited] code=3'));
    expect(file, contains('[frameError] bad frame'));
  });

  test('reports an unwritable log file once and keeps logging', () {
    final sink = _MemorySink();
    final logger = ProxyLogger(
      sink: sink,
      filePath: '${scratch.path}${_sep}missing$_sep${'proxy.log'}',
    );
    logger.log(ProxyLogEvent.upstreamStderr, 'one');
    logger.log(ProxyLogEvent.upstreamStderr, 'two');
    final text = sink.buffer.toString();
    expect('[proxyLog]'.allMatches(text), hasLength(1));
    expect(text, contains('[upstreamStderr] one'));
    expect(text, contains('[upstreamStderr] two'));
  });
}
