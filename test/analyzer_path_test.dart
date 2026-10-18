import 'dart:io';

import 'package:dart_analysis_server_proxy/dart_analysis_server_proxy.dart';
import 'package:test/test.dart';

void main() {
  late Directory scratch;

  setUp(() async {
    await Directory('build').create();
    scratch = await Directory('build').createTemp('analyzer_path_');
  });

  tearDown(() async {
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  test(
    'analyzer-path compiles a loadable proxy and prints the setting',
    () async {
      final output = File('${scratch.absolute.path}/proxy.dill');
      final result = await Process.run(Platform.resolvedExecutable, [
        'bin/dana_analysis_server_proxy.dart',
        'analyzer-path',
        '--output',
        output.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(await output.exists(), isTrue);
      expect('${result.stdout}', contains('"dart.analyzerPath"'));
      expect('${result.stdout}', contains(output.path));
      // No temporary file is left next to the output.
      expect(scratch.listSync().map((e) => e.uri.pathSegments.last), [
        'proxy.dill',
      ]);

      // The .dill runs and still routes management commands.
      final help = await Process.run(Platform.resolvedExecutable, [
        output.path,
        '--help',
      ]);
      expect(help.exitCode, 0, reason: '${help.stderr}');
      expect('${help.stdout}', contains('analyzer-path'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('an unresolvable package root exits 70 and writes nothing', () async {
    final output = File('${scratch.absolute.path}/proxy.dill');
    final code = await runAnalyzerPath(
      buildAnalyzerPathParser().parse(['--output', output.path]),
      resolvePackageUri: (_) async => null,
    );
    expect(code, 70);
    expect(scratch.listSync(), isEmpty);
  });

  test('--output is required', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'bin/dana_analysis_server_proxy.dart',
      'analyzer-path',
    ]);
    expect(result.exitCode, 64);
    expect('${result.stderr}', contains('output'));
    expect(scratch.listSync(), isEmpty);
  });
}
