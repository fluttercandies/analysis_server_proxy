import 'dart:io';

/// Events the proxy reports outside the LSP stream.
enum ProxyLogEvent {
  upstreamStartFailed,
  upstreamExited,
  upstreamStderr,
  frameError,
}

/// Diagnostic log for the proxy.
///
/// stdout carries LSP frames only, so records always go to [sink] (stderr by
/// default, which Dart-Code shows in its output channel) and, when
/// `DANA_PROXY_LOG=<path>` is set, are also appended to that file. Nothing is
/// written to disk unless that variable is set.
class ProxyLogger {
  /// Throws [ArgumentError] if [sink] is [stdout].
  ProxyLogger({IOSink? sink, this.filePath}) : _sink = sink ?? stderr {
    if (identical(_sink, stdout)) {
      throw ArgumentError.value(
        sink,
        'sink',
        'stdout is reserved for LSP frames',
      );
    }
  }

  /// Uses `DANA_PROXY_LOG` from [environment] (default: the process
  /// environment) as the optional log file.
  factory ProxyLogger.fromEnvironment({
    IOSink? sink,
    Map<String, String>? environment,
  }) {
    final path = (environment ?? Platform.environment)['DANA_PROXY_LOG'];
    return ProxyLogger(
      sink: sink,
      filePath: path == null || path.isEmpty ? null : path,
    );
  }

  final IOSink _sink;

  /// Optional file that receives a copy of every record.
  final String? filePath;

  bool _fileFailed = false;

  /// Writes one record: `<ISO-8601 time> [<event>] <detail>`. Continuation
  /// lines of a multi-line [detail] (e.g. a stack trace) are indented.
  void log(ProxyLogEvent event, String detail) {
    final record =
        '${DateTime.now().toIso8601String()} [${event.name}] '
        '${detail.trimRight().replaceAll('\n', '\n  ')}\n';
    try {
      _sink.write(record);
    } on StateError {
      // The sink was closed during shutdown; the file copy below still runs.
    }
    final path = filePath;
    if (path == null || _fileFailed) return;
    try {
      File(path).writeAsStringSync(record, mode: FileMode.append, flush: true);
    } on FileSystemException catch (error) {
      // Report once on the sink and stop retrying, so a bad path cannot flood
      // stderr or break forwarding.
      _fileFailed = true;
      try {
        _sink.write(
          '${DateTime.now().toIso8601String()} [proxyLog] cannot write '
          'DANA_PROXY_LOG=$path: ${error.message}\n',
        );
      } on StateError {
        // Sink already closed.
      }
    }
  }
}
