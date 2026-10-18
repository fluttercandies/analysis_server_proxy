@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:dart_analysis_server_proxy/src/analyzer_path.dart';
import 'package:test/test.dart';

final _sep = Platform.pathSeparator;
const _fixture = 'test/fixtures/print_package_root.dart';

void main() {
  late Directory scratch;

  setUp(() async {
    final build = Directory('build');
    await build.create();
    scratch = await build.createTemp('analyzer_path_root_');
  });

  tearDown(() async {
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  group('resolvePackageRoot', () {
    test('finds the directory that holds pubspec.yaml', () async {
      final root = await resolvePackageRoot();
      expect(root, isNotNull);
      expect(root!.path, Directory.current.absolute.path);
      expect(File('${root.path}${_sep}pubspec.yaml').existsSync(), isTrue);
    });

    test('agrees across in-process, dart run and a compiled .dill', () async {
      final inProcess = (await resolvePackageRoot())!.path;

      final dartRun = await Process.run(Platform.resolvedExecutable, [
        'run',
        _fixture,
      ]);
      expect(dartRun.exitCode, 0, reason: '${dartRun.stderr}');

      final dill = '${scratch.path}${_sep}print_package_root.dill';
      final compile = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'kernel',
        _fixture,
        '-o',
        dill,
      ]);
      expect(compile.exitCode, 0, reason: '${compile.stderr}');
      final fromDill = await Process.run(Platform.resolvedExecutable, [dill]);
      expect(fromDill.exitCode, 0, reason: '${fromDill.stderr}');

      expect('${dartRun.stdout}'.trim(), inProcess);
      expect('${fromDill.stdout}'.trim(), inProcess);
    });

    test('returns null when the package cannot be resolved', () async {
      expect(await resolvePackageRoot(resolver: (_) async => null), isNull);
      expect(
        await resolvePackageRoot(
          resolver: (_) async => Uri.parse('http://example.invalid/lib/'),
        ),
        isNull,
      );
      expect(
        await resolvePackageRoot(
          resolver: (_) async => throw UnsupportedError('no packages'),
        ),
        isNull,
      );
    });

    test('returns null when the candidate has no pubspec.yaml', () async {
      final lib = await Directory('${scratch.path}${_sep}lib').create();
      expect(await resolvePackageRoot(resolver: (_) async => lib.uri), isNull);
    });
  });
}
