import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bridge_server.dart';
import 'dart_project.dart';
import 'lsp_framing.dart';
import 'proxy_logger.dart';
import 'runtime.dart';

/// A transparent process proxy for an upstream Dart analysis server.
///
/// Uses the SDK's `dart language-server` through `dart.analyzerPath`.
class LspProxy {
  /// [startUpstream] allows embedders and protocol tests to supply a process.
  /// It receives the analyzer arguments without a runtime or subcommand.
  LspProxy.languageServer({
    this.upstreamExecutable,
    this.startUpstream,
    ProxyLogger? logger,
    this.fullCheckSettle = defaultFullCheckSettle,
    this.fullCheckSettleLimit = defaultFullCheckSettleLimit,
  }) : _injectedLogger = logger;

  static const defaultFullCheckSettle = Duration(seconds: 2);
  // About one cold `dart analyze` of a large workspace: waiting longer than
  // that before falling back would cost more than running it directly.
  static const defaultFullCheckSettleLimit = Duration(seconds: 180);

  /// Largest per-request `settleLimitSeconds` a bridge client may ask for.
  static const maxFullCheckSettleLimit = Duration(hours: 1);

  final String? upstreamExecutable;
  final Future<Process> Function(List<String> arguments)? startUpstream;

  /// A bridge `fullCheck` answers only after no `publishDiagnostics` has
  /// arrived for this long. Analyzer plugins publish their diagnostics after
  /// the server already reports idle, so idle alone is not "done".
  final Duration fullCheckSettle;

  /// Upper bound on that wait once the analyzer is idle; when reached the
  /// answer has `settled: false`. A bridge request may override it with
  /// `settleLimitSeconds`.
  final Duration fullCheckSettleLimit;
  final _sinceLastPublish = Stopwatch();
  final ProxyLogger? _injectedLogger;
  Process? _child;
  IOSink? _output;
  BridgeServer? _bridge;
  final _statusChanges = StreamController<bool>.broadcast();
  final _diagnostics = <String, List<Object?>>{};
  bool? _isAnalyzing;

  /// Completes the first time the analyzer reports idle. Before that the
  /// diagnostics cache only reflects a partial initial pass.
  final _firstIdle = Completer<void>();
  DateTime? _lastIdleAt;
  final _roots = <String>{};
  Future<void> _writes = Future<void>.value();
  Future<void> _fromIde = Future<void>.value();
  late ProxyLogger _logger;

  /// Runs the proxy until the upstream exits and returns its exit code.
  ///
  /// Diagnostics go to the injected [ProxyLogger], or by default to
  /// [errorOutput] (stderr) plus `DANA_PROXY_LOG` when set; [output] only ever
  /// receives LSP frames.
  Future<int> run(
    List<String> arguments, {
    Stream<List<int>>? input,
    IOSink? output,
    IOSink? errorOutput,
  }) async {
    final logger =
        _logger =
            _injectedLogger ?? ProxyLogger.fromEnvironment(sink: errorOutput);
    final Process child;
    try {
      child =
          _child =
              await (startUpstream?.call(arguments) ??
                  Process.start(
                    upstreamExecutable ?? await resolveDartExecutable(),
                    ['language-server', ...arguments],
                    mode: ProcessStartMode.normal,
                  ));
    } on Object catch (error, stack) {
      logger.log(ProxyLogEvent.upstreamStartFailed, '$error\n$stack');
      rethrow;
    }
    final inputStream = input ?? stdin;
    final outputSink = _output = output ?? stdout;
    final subscriptions = <StreamSubscription<Object?>>[];

    final stderrDone = Completer<void>();
    subscriptions.add(
      child.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
            (line) => logger.log(ProxyLogEvent.upstreamStderr, line),
            onDone: stderrDone.complete,
          ),
    );
    subscriptions.add(
      inputStream
          .transform(LspMessageReader())
          .listen(
            // Chain IDE messages: `initialize` awaits the bridge start, and
            // a later message must not overtake it on the way to the child.
            (message) =>
                _fromIde = _fromIde.then((_) => _forwardFromIde(message)),
            onError: (Object error) {
              logger.log(ProxyLogEvent.frameError, 'from IDE: $error');
              child.kill();
            },
            onDone:
                () => unawaited(
                  _fromIde.whenComplete(() => _safeClose(child.stdin)),
                ),
          ),
    );
    subscriptions.add(
      child.stdout
          .transform(LspMessageReader())
          .listen(
            _forwardFromServer,
            onError: (Object error) {
              logger.log(ProxyLogEvent.frameError, 'from upstream: $error');
              child.kill();
            },
          ),
    );

    final exitCode = await child.exitCode;
    // Let the last stderr lines reach the log; a descendant holding the pipe
    // open must not block shutdown.
    await stderrDone.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    if (exitCode != 0) {
      logger.log(
        ProxyLogEvent.upstreamExited,
        exitCode < 0 && !Platform.isWindows
            ? 'code=$exitCode signal=${-exitCode}'
            : 'code=$exitCode',
      );
    }
    await _bridge?.close();
    await _statusChanges.close();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await outputSink.flush();
    return exitCode;
  }

  Future<void> _forwardFromIde(LspMessage message) async {
    final json = decodeJson(message);
    if (json['method'] == 'initialize') {
      final roots = <String>{};
      for (final root in _rootsFromInitialize(json['params'])) {
        if (await isDartProjectRoot(root)) roots.add(root);
      }
      if (roots.isNotEmpty) {
        try {
          await _startBridge(roots);
        } on Object catch (error, stack) {
          // The bridge is an optional add-on: the IDE must keep its analyzer
          // even when the bridge cannot start, so log and keep forwarding.
          _logger.log(
            ProxyLogEvent.upstreamStartFailed,
            'IDE bridge failed to start: $error\n$stack',
          );
        }
      }
    }
    await _writeToChild(message.body);
  }

  void _forwardFromServer(LspMessage message) {
    final json = decodeJson(message);
    _observe(json);
    try {
      _output!.add(encodeLspMessage(message.body));
    } on Object {
      // The IDE may have disconnected while the analyzer was flushing its
      // final notifications. Terminate the child instead of leaking an
      // unhandled broken-pipe error from the proxy.
      _child?.kill();
    }
  }

  void _observe(Map<String, Object?> message) {
    if (message['method'] == 'textDocument/publishDiagnostics') {
      final params = message['params'];
      if (params is Map &&
          params['uri'] is String &&
          params['diagnostics'] is List) {
        final path = _uriToPath(params['uri'] as String);
        if (path != null) {
          _diagnostics[path] = List<Object?>.from(
            params['diagnostics'] as List,
          );
          _sinceLastPublish
            ..reset()
            ..start();
        }
      }
    }
    if (message['method'] == r'$/analyzerStatus') {
      final params = message['params'];
      if (params is Map && params['isAnalyzing'] is bool) {
        _setAnalyzing(params['isAnalyzing'] as bool);
      }
    }
    if (message['method'] == r'$/progress') {
      final params = message['params'];
      final value = params is Map ? params['value'] : null;
      if (value is Map && value['kind'] == 'begin') _setAnalyzing(true);
      if (value is Map && value['kind'] == 'end') _setAnalyzing(false);
    }
  }

  void _setAnalyzing(bool value) {
    if (_isAnalyzing == value) return;
    _isAnalyzing = value;
    if (!value) {
      _lastIdleAt = DateTime.now();
      if (!_firstIdle.isCompleted) _firstIdle.complete();
    }
    _statusChanges.add(value);
  }

  Future<void> _startBridge(Iterable<String> roots) async {
    if (_bridge != null) return;
    _roots.addAll(roots);
    final bridge = _bridge = BridgeServer(_handleBridgeRequest);
    await bridge.start(roots: _roots, fullCheck: true);
  }

  Future<Map<String, Object?>> _handleBridgeRequest(
    String root,
    Map<String, Object?> request,
  ) async {
    switch (request['op']) {
      case 'check':
        final value = request['files'];
        if (value is! List ||
            value.isEmpty ||
            value.any((file) => file is! String)) {
          return {'ok': false, 'error': 'check.files must be non-empty paths'};
        }
        final files = [
          for (final file in value.cast<String>()) _normalizePath(root, file),
        ];
        if (files.any((file) => !_isInsideRoot(root, file))) {
          return {'ok': false, 'error': 'check file is outside bridge root'};
        }
        // Do not snapshot the diagnostics cache while the IDE-owned analyzer
        // is still publishing the current pass. The first notification can
        // belong to an unrelated file, which made directory checks flaky.
        await _waitForIdle(requireCycle: false);
        final expanded = <String>[];
        final directoryFiles = <String>{};
        for (final file in files) {
          if (Directory(file).existsSync()) {
            final candidates = await _filesUnderDirectory(root, file);
            expanded.addAll(candidates);
            directoryFiles.addAll(candidates);
          } else {
            expanded.add(file);
          }
        }
        final uniqueFiles = expanded.toSet().toList()..sort();
        final watchedFiles = uniqueFiles
            .where(
              (file) =>
                  !directoryFiles.contains(file) ||
                  !_diagnostics.containsKey(file),
            )
            .toList(growable: false);
        if (watchedFiles.isNotEmpty) {
          await _notifyChild('workspace/didChangeWatchedFiles', {
            'changes': [
              for (final file in watchedFiles)
                {'uri': Uri.file(file).toString(), 'type': 2},
            ],
          });
          await _waitForIdle(requireCycle: false);
        }
        final resultFiles = [
          for (final file in uniqueFiles)
            if (!directoryFiles.contains(file) ||
                _diagnostics.containsKey(file))
              file,
        ];
        final diagnostics = {
          for (final file in resultFiles) file: _diagnostics[file] ?? const [],
        };
        return {
          'ok': true,
          'source': 'ide-bridge',
          'mode': 'fast',
          ..._countsFor(diagnostics),
          'diagnostics': diagnostics,
        };
      case 'status':
        return {
          'ok': true,
          'source': 'ide-bridge',
          'root': root,
          'isAnalyzing': _isAnalyzing ?? false,
          'files':
              _diagnostics.keys
                  .where((path) => _isInsideRoot(root, path))
                  .length,
        };
      case 'fullCheck':
        final requestedLimit = request['settleLimitSeconds'];
        final Duration settleLimit;
        if (requestedLimit == null) {
          settleLimit = fullCheckSettleLimit;
        } else if (requestedLimit is int &&
            requestedLimit > 0 &&
            requestedLimit <= maxFullCheckSettleLimit.inSeconds) {
          settleLimit = Duration(seconds: requestedLimit);
        } else {
          return {
            'ok': false,
            'source': 'ide-bridge',
            'error':
                'fullCheck.settleLimitSeconds must be an integer in '
                '1..${maxFullCheckSettleLimit.inSeconds}',
          };
        }
        // Answer from the IDE analyzer's live cache instead of forcing
        // `dart/reanalyze`: that would discard the warm state the bridge
        // exists to reuse, and its idle signal fires before analyzer plugins
        // have republished their diagnostics, yielding a partial result.
        try {
          final firstPass = _firstIdle.future;
          await (analysisTimeout == null
              ? firstPass
              : firstPass.timeout(analysisTimeout!));
        } on TimeoutException {
          return {
            'ok': false,
            'source': 'ide-bridge',
            'error': 'IDE analyzer has not finished its first analysis pass',
          };
        }
        // The analyzer's own file watcher can lag a fresh disk edit by a
        // second or more, so the cache may not yet reflect it. Tell it
        // explicitly about Dart files written since it last went idle and
        // wait for the pass that follows.
        final since = (_lastIdleAt ?? DateTime.now()).subtract(
          const Duration(seconds: 3),
        );
        final changed = await _dartFilesModifiedSince(root, since);
        if (changed.isNotEmpty) {
          await _notifyChild('workspace/didChangeWatchedFiles', {
            'changes': [
              for (final file in changed)
                {'uri': Uri.file(file).toString(), 'type': 2},
            ],
          });
          await _waitForAnalysisStart(const Duration(seconds: 3));
        }
        final settled = await _waitForSettled(settleLimit);
        final diagnostics = {
          for (final entry in _diagnostics.entries)
            if (_isInsideRoot(root, entry.key)) entry.key: entry.value,
        };
        return {
          'ok': true,
          'source': 'ide-bridge',
          'mode': 'full',
          'settled': settled,
          ..._countsFor(diagnostics),
          'files': diagnostics.length,
          'diagnostics': diagnostics,
        };
      default:
        return {'ok': false, 'error': 'Unsupported bridge operation'};
    }
  }

  Future<void> _notifyChild(String method, Map<String, Object?> params) {
    return _writeToChild(
      jsonEncode({'jsonrpc': '2.0', 'method': method, 'params': params}),
    );
  }

  /// Waits until the analyzer is idle and no diagnostics have been published
  /// for [fullCheckSettle]. A pass of any length is waited out (bounded only
  /// by `analysisTimeout`); a publish gap during a pass does not count as
  /// done. Once idle, publishing must go quiet within [fullCheckSettleLimit].
  /// Returns false when either bound is hit.
  Future<bool> _waitForSettled(Duration settleLimit) async {
    const poll = Duration(milliseconds: 100);
    final overallLimit = analysisTimeout;
    final overall = Stopwatch()..start();
    final sinceIdle = Stopwatch()..start();
    while (true) {
      if (overallLimit != null && overall.elapsed >= overallLimit) {
        return false;
      }
      if (_isAnalyzing == true) {
        sinceIdle.reset();
        await Future<void>.delayed(poll);
        continue;
      }
      final quietFor =
          _sinceLastPublish.isRunning
              ? _sinceLastPublish.elapsed
              : fullCheckSettle;
      if (quietFor >= fullCheckSettle) return true;
      if (sinceIdle.elapsed >= settleLimit) return false;
      final wait = fullCheckSettle - quietFor;
      await Future<void>.delayed(wait < poll ? wait : poll);
    }
  }

  /// Waits up to [window] for the analyzer to start a pass. Returns early if
  /// it is already analyzing; returns after [window] if it never starts
  /// (it found nothing to redo).
  Future<void> _waitForAnalysisStart(Duration window) async {
    final watch = Stopwatch()..start();
    while (_isAnalyzing != true && watch.elapsed < window) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Dart files under [root] modified after [since], skipping hidden
  /// directories and `build/`.
  Future<List<String>> _dartFilesModifiedSince(
    String root,
    DateTime since,
  ) async {
    final result = <String>[];
    final pending = <Directory>[Directory(root).absolute];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      try {
        await for (final entity in current.list(followLinks: false)) {
          final name = entity.path.split(Platform.pathSeparator).last;
          if (name.startsWith('.')) continue;
          if (entity is Directory) {
            if (name != 'build') pending.add(entity);
          } else if (entity is File && name.endsWith('.dart')) {
            final modified = entity.statSync().modified;
            if (modified.isAfter(since)) result.add(entity.path);
          }
        }
      } on FileSystemException {
        // A directory vanished or is unreadable mid-scan; skip it.
      }
    }
    return result;
  }

  Future<void> _waitForIdle({required bool requireCycle}) async {
    var sawWorking = _isAnalyzing == true;
    final completer = Completer<void>();
    late final StreamSubscription<bool> subscription;
    subscription = _statusChanges.stream.listen((value) {
      if (value) {
        sawWorking = true;
      } else if (sawWorking && !completer.isCompleted) {
        completer.complete();
      }
    });
    final timeout = Timer(
      requireCycle
          ? (analysisTimeout ?? const Duration(days: 3650))
          : const Duration(seconds: 2),
      () {
        if (!completer.isCompleted) {
          if (requireCycle) {
            completer.completeError(
              TimeoutException('Analyzer did not become idle'),
            );
          } else {
            completer.complete();
          }
        }
      },
    );
    try {
      if (!requireCycle && _isAnalyzing == false) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!sawWorking && !completer.isCompleted) completer.complete();
      }
      await completer.future;
    } finally {
      timeout.cancel();
      await subscription.cancel();
    }
  }

  Future<void> _writeToChild(String body) {
    _writes = _writes.then((_) async {
      _child!.stdin.add(encodeLspMessage(body));
      await _child!.stdin.flush();
    });
    return _writes;
  }

  Map<String, int> _countsFor(Map<String, List<Object?>> diagnosticsByFile) {
    var errors = 0;
    var warnings = 0;
    var infos = 0;
    for (final diagnostics in diagnosticsByFile.values) {
      for (final diagnostic in diagnostics) {
        if (diagnostic is! Map) continue;
        switch (diagnostic['severity']) {
          case 1:
            errors++;
          case 2:
            warnings++;
          case 3:
            infos++;
        }
      }
    }
    return {'errors': errors, 'warnings': warnings, 'infos': infos};
  }

  static Set<String> _rootsFromInitialize(Object? value) {
    if (value is! Map) return const {};
    final roots = <String>{};
    final rootUri = value['rootUri'];
    if (rootUri is String) {
      final root = _uriToPath(rootUri);
      if (root != null) roots.add(root);
    }
    final folders = value['workspaceFolders'];
    if (folders is List) {
      for (final folder in folders.whereType<Map>()) {
        final uri = folder['uri'];
        if (uri is String) {
          final root = _uriToPath(uri);
          if (root != null) roots.add(root);
        }
      }
    }
    return roots;
  }

  static String? _uriToPath(String value) {
    try {
      final uri = Uri.parse(value);
      return uri.scheme == 'file'
          ? uri.toFilePath(windows: Platform.isWindows)
          : null;
    } on FormatException {
      return null;
    }
  }

  String _normalizePath(String root, String path) {
    if (File(path).isAbsolute) return path;
    return File('$root${Platform.pathSeparator}$path').absolute.path;
  }

  bool _isInsideRoot(String root, String path) {
    final normalizedRoot = Directory(root).absolute.path;
    final normalizedPath = File(path).absolute.path;
    final prefix =
        normalizedRoot.endsWith(Platform.pathSeparator)
            ? normalizedRoot
            : '$normalizedRoot${Platform.pathSeparator}';
    return normalizedPath == normalizedRoot ||
        normalizedPath.startsWith(prefix);
  }

  Future<List<String>> _filesUnderDirectory(
    String root,
    String directory,
  ) async {
    final normalizedDirectory = Directory(directory).absolute.path;
    final result = <String>[];
    final pending = <Directory>[Directory(normalizedDirectory)];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      await for (final entity in current.list(followLinks: false)) {
        final name =
            entity.uri.pathSegments.isEmpty
                ? entity.path
                : entity.uri.pathSegments.last;
        if (name.startsWith('.')) continue;
        if (entity is Directory) {
          pending.add(entity);
        } else if (entity is File &&
            entity.path.toLowerCase().endsWith('.dart') &&
            _isInsideRoot(root, entity.path)) {
          result.add(entity.absolute.path);
        }
      }
    }
    result.sort();
    return result;
  }

  static Map<String, Object?> decodeJson(LspMessage message) {
    final value = jsonDecode(message.body);
    if (value is! Map) throw const FormatException('LSP body is not an object');
    return Map<String, Object?>.from(value);
  }
}

Future<void> _safeClose(IOSink sink) async {
  try {
    await sink.close();
  } on Object {
    // The child may have closed its input after handling shutdown already.
  }
}
