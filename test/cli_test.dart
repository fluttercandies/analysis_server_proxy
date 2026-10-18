import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  Future<ProcessResult> run(List<String> arguments) => Process.run(
    Platform.resolvedExecutable,
    ['bin/dana_analysis_server_proxy.dart', ...arguments],
  ).timeout(const Duration(seconds: 20));

  test('generated top-level and analyzer-path help', () async {
    for (final args in [
      ['--help'],
      ['-h'],
      ['help'],
    ]) {
      final result = await run(args);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('Available commands:'));
      expect(result.stdout, contains('Compile the proxy'));
      expect(result.stdout, contains('--upstream-executable'));
      expect(result.stdout, isNot(contains('install')));
      expect(result.stdout, isNot(contains('snapshot')));
    }
    for (final args in [
      ['analyzer-path', '--help'],
      ['help', 'analyzer-path'],
    ]) {
      final result = await run(args);
      expect(result.exitCode, 0);
      for (final flag in ['--output']) {
        expect(result.stdout, contains(flag));
      }
    }
  });

  test('analyzer-path usage errors exit 64 with usage', () async {
    for (final args in [
      ['analyzer-path', '--unknown'],
      ['analyzer-path', 'unexpected'],
      ['help', 'unknown'],
    ]) {
      final result = await run(args);
      expect(result.exitCode, 64);
      expect(result.stderr, contains('Usage:'));
    }
  });

  test('analyzer arguments and empty invocation remain transparent', () async {
    final upstream = File('test/fixtures/argument_upstream.dart').absolute.path;
    for (final args in [
      <String>[],
      ['--protocol=lsp', '--client-id=fixture', '--help'],
      ['--', 'install', '--help', '--unknown'],
    ]) {
      final explicit = args.isNotEmpty && args.first == '--';
      final process = await Process.start(Platform.resolvedExecutable, [
        'test/fixtures/proxy_driver.dart',
        upstream,
        Platform.resolvedExecutable,
        ...args,
      ]);
      final output = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr.transform(utf8.decoder).join();
      try {
        await process.stdin.close();
        expect(await process.exitCode.timeout(const Duration(seconds: 20)), 23);
        expect(await output, isEmpty);
        // The current proxy timestamps upstream stderr through its logger.
        expect(
          await errors,
          contains(jsonEncode(explicit ? args.skip(1).toList() : args)),
        );
      } finally {
        process.kill();
      }
    }
  });
}
