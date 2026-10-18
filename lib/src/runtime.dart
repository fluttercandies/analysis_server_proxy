import 'dart:io';

/// Maximum time for a full analyzer operation.
/// Set `DANA_ANALYSIS_TIMEOUT_SECONDS=0` for no wall-clock limit.
Duration? get analysisTimeout {
  final value = Platform.environment['DANA_ANALYSIS_TIMEOUT_SECONDS'];
  if (value == '0') return null;
  final seconds = int.tryParse(value ?? '') ?? 1800;
  return Duration(seconds: seconds > 0 ? seconds : 1800);
}

/// Finds a Dart runtime capable of running `dart language-server`.
///
/// A standalone AOT executable cannot run the analyzer with
/// [Platform.resolvedExecutable], because that value is the executable itself.
/// The SDK/runtime environment is therefore preferred, with PATH and Flutter
/// SDK discovery as fallbacks.
Future<String> resolveDartExecutable() async {
  final configured = Platform.environment['DANA_DART_EXECUTABLE'];
  if (configured != null && configured.isNotEmpty) {
    return _requireExecutable(configured, 'DANA_DART_EXECUTABLE');
  }
  final sdk = Platform.environment['DART_SDK'];
  if (sdk != null && sdk.isNotEmpty) {
    final candidate = _dartInSdk(sdk);
    if (candidate.existsSync()) return candidate.path;
  }
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.isNotEmpty) {
    final candidate = _dartInFlutterRoot(flutterRoot);
    if (candidate.existsSync()) return candidate.path;
  }

  final resolved = File(Platform.resolvedExecutable).absolute;
  final name = resolved.uri.pathSegments.last.toLowerCase();
  if (name == 'dart' || name == 'dart.exe') return resolved.path;
  final sibling = File(
    '${resolved.parent.path}${Platform.pathSeparator}dart'
    '${Platform.isWindows ? '.exe' : ''}',
  );
  if (sibling.existsSync()) return sibling.path;

  final result = await Process.run(Platform.isWindows ? 'where.exe' : 'which', [
    'dart',
  ], runInShell: false);
  if (result.exitCode == 0) {
    for (final line in '${result.stdout}'.split(RegExp(r'[\r\n]+'))) {
      final candidate = line.trim();
      if (candidate.isEmpty || !File(candidate).existsSync()) continue;
      final lower = candidate.toLowerCase();
      if ((!Platform.isWindows &&
              !lower.endsWith('.bat') &&
              !lower.endsWith('.cmd')) ||
          (Platform.isWindows && lower.endsWith('dart.exe'))) {
        return candidate;
      }
    }
  }
  if (Platform.isWindows) {
    final flutter = await Process.run('where.exe', ['flutter']);
    if (flutter.exitCode == 0) {
      for (final line in '${flutter.stdout}'.split(RegExp(r'[\r\n]+'))) {
        final candidate = line.trim();
        if (candidate.isEmpty) continue;
        final flutterBin = Directory(File(candidate).absolute.path).parent;
        final dart = _dartInFlutterRoot(flutterBin.parent.path);
        if (dart.existsSync()) return dart.path;
      }
    }
  }
  throw StateError(
    'Could not locate a Dart executable for the analysis server. Set '
    'DANA_DART_EXECUTABLE or DART_SDK.',
  );
}

File _dartInSdk(String sdk) => File(
  '${Directory(sdk).absolute.path}${Platform.pathSeparator}bin'
  '${Platform.pathSeparator}dart${Platform.isWindows ? '.exe' : ''}',
);

File _dartInFlutterRoot(String root) => File(
  '${Directory(root).absolute.path}${Platform.pathSeparator}bin'
  '${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk'
  '${Platform.pathSeparator}bin${Platform.pathSeparator}dart'
  '${Platform.isWindows ? '.exe' : ''}',
);

String _requireExecutable(String path, String variable) {
  final file = File(path).absolute;
  if (!file.existsSync()) {
    throw StateError('$variable does not point to an executable: ${file.path}');
  }
  return file.path;
}
