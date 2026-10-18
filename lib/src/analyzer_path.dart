import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:args/args.dart';

/// Resolves a `package:` URI to a file URI; [Isolate.resolvePackageUri] in
/// production.
typedef PackageUriResolver = Future<Uri?> Function(Uri packageUri);

/// Resolves the proxy package root so kernel compilation can find sources.
///
/// `Platform.script` is unreliable here: after `pub global activate` it points
/// into the pub cache, and for a `.dill` it points at the .dill file. The
/// package's own `package:` URI resolves to its real `lib/` directory in
/// `dart run`, compiled .dill and global-activation launches alike, so the
/// parent of `lib/` is the root. Returns null when resolution is unavailable
/// or the candidate has no `pubspec.yaml`.
Future<Directory?> resolvePackageRoot({
  PackageUriResolver resolver = Isolate.resolvePackageUri,
}) async {
  final Uri? libUri;
  try {
    libUri = await resolver(Uri.parse('package:dart_analysis_server_proxy/'));
  } on UnsupportedError {
    // Package resolution is not available in this runtime (e.g. AOT).
    return null;
  }
  if (libUri == null || libUri.scheme != 'file') return null;
  var path = Directory.fromUri(libUri.resolve('..')).absolute.path;
  while (path.length > 1 && path.endsWith(Platform.pathSeparator)) {
    path = path.substring(0, path.length - 1);
  }
  final root = Directory(path);
  final pubspec = File('${root.path}${Platform.pathSeparator}pubspec.yaml');
  return pubspec.existsSync() ? root : null;
}

/// Builds the `analyzer-path` subcommand parser.
ArgParser buildAnalyzerPathParser() =>
    ArgParser()..addOption(
      'output',
      abbr: 'o',
      valueHelp: 'file',
      help: 'Where to write the proxy kernel (.dill) (required).',
    );

/// Compiles the proxy into a kernel (.dill) for Dart-Code's
/// `dart.analyzerPath` and prints the setting to use.
///
/// The .dill file is compiled with the running Dart SDK; rerun after upgrading
/// the SDK, since a kernel (.dill) only loads on the SDK that built it.
Future<int> runAnalyzerPath(
  ArgResults results, {
  PackageUriResolver? resolvePackageUri,
}) async {
  final requested = results['output'] as String?;
  if (requested == null || requested.isEmpty) {
    stderr.writeln('Pass --output <file> for the proxy kernel (.dill).');
    return 64;
  }
  final output = File(requested).absolute;
  final packageRoot = await resolvePackageRoot(
    resolver: resolvePackageUri ?? Isolate.resolvePackageUri,
  );
  if (packageRoot == null) {
    stderr.writeln('Cannot locate dart_analysis_server_proxy package root');
    return 70;
  }
  final dart = await _runningDart();
  if (dart == null) {
    stderr.writeln('Cannot locate the Dart executable running this command.');
    return 70;
  }
  await output.parent.create(recursive: true);
  final temporary = File('${output.path}.$pid.tmp');
  try {
    await _compile(dart, packageRoot, [
      'compile',
      'kernel',
      'bin/dana_analysis_server_proxy.dart',
      '-o',
      temporary.path,
    ]);
    await temporary.rename(output.path);
  } on StateError catch (error) {
    stderr.writeln(error.message);
    return 1;
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
  final sdkVersion = Platform.version.split(' ').first;
  stdout
    ..writeln('Wrote ${output.path} (Dart $sdkVersion)')
    ..writeln()
    ..writeln('Point Dart-Code at it, then restart the analyzer:')
    ..writeln(
      '  ${jsonEncode('dart.analyzerPath')}: ${jsonEncode(output.path)}',
    )
    ..writeln()
    ..writeln(
      'In a single-folder window, put it in the project\'s '
      '.vscode/settings.json (relative to the project). In a multi-root '
      'window, put it in the .code-workspace settings (relative to that '
      'file); folder settings are ignored there.',
    )
    ..writeln(
      'The .dill file only loads on Dart $sdkVersion; regenerate it after '
      'changing the SDK.',
    );
  return 0;
}

/// The `dart` executable of the running SDK, or null.
Future<String?> _runningDart() async {
  final executable = File(Platform.resolvedExecutable).absolute;
  final name = executable.uri.pathSegments.last.toLowerCase();
  if (name == 'dart' || name == 'dart.exe') return executable.path;
  final sibling = File(
    '${executable.parent.path}${Platform.pathSeparator}'
    'dart${Platform.isWindows ? '.exe' : ''}',
  );
  return sibling.existsSync() ? sibling.path : null;
}

Future<void> _compile(
  String dartExecutable,
  Directory packageRoot,
  List<String> arguments,
) async {
  // A package activated from pub.dev or git lives in the pub cache without a
  // package config of its own; its dependencies are resolved by the config
  // pub wrote for the activation, which is the one this isolate runs with.
  final packageConfig = await Isolate.packageConfig;
  final result = await Process.run(
    dartExecutable,
    [
      arguments.first,
      arguments[1],
      if (packageConfig != null && packageConfig.scheme == 'file')
        '--packages=${packageConfig.toFilePath()}',
      ...arguments.skip(2),
    ],
    workingDirectory: packageRoot.path,
    runInShell: false,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'Kernel compilation failed (${result.exitCode}):\n'
      '${result.stdout}\n${result.stderr}',
    );
  }
}
