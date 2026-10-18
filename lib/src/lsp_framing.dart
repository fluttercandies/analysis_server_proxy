import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// One decoded LSP message. [body] contains the UTF-8 JSON payload.
class LspMessage {
  LspMessage(this.body, {this.headers = const {}});

  final String body;
  final Map<String, String> headers;
}

/// Why a frame could not be decoded.
enum LspFrameErrorKind {
  missingContentLength,
  invalidContentLength,
  invalidHeader,
  truncated,
}

/// The only error the LSP framer raises for malformed input.
class LspFrameException implements Exception {
  LspFrameException(this.kind, this.message, {this.rawValue});

  final LspFrameErrorKind kind;
  final String message;

  /// The offending value as received, for [LspFrameErrorKind.invalidContentLength]
  /// and [LspFrameErrorKind.invalidHeader].
  final String? rawValue;

  @override
  String toString() =>
      'LspFrameException(${kind.name}): $message'
      '${rawValue == null ? '' : ' (received: ${jsonEncode(rawValue)})'}';
}

/// Reads Content-Length framed LSP messages from a byte stream.
///
/// Performance matters here: a single analysis pass on a large workspace can
/// emit multi-megabyte `publishDiagnostics` notifications, rapidly and
/// back-to-back. A naive `List<int>` buffer with `removeRange(0, n)` after
/// each message and a from-the-start header scan is O(n^2) in the buffered
/// bytes and stalls the proxy under that load (the analyzer then appears
/// unresponsive to the IDE and gets killed). This implementation keeps a
/// growable byte buffer with a moving read offset — no per-message shifting —
/// resumes the header search where it left off, and compacts only
/// occasionally, giving linear throughput on large message streams.
///
/// Malformed input is reported as an [LspFrameException] error on the stream,
/// after which the stream ends.
class LspMessageReader extends StreamTransformerBase<List<int>, LspMessage> {
  @override
  Stream<LspMessage> bind(Stream<List<int>> stream) async* {
    final decoder = LspFrameDecoder();
    await for (final chunk in stream) {
      decoder.addChunk(chunk);
      LspMessage? message;
      while ((message = decoder.next()) != null) {
        yield message!;
      }
    }
    decoder.finish();
  }
}

/// Incremental Content-Length frame decoder with a moving read offset.
///
/// Public inside `src/` so tests can observe its copy accounting; it is not
/// exported from the package library.
class LspFrameDecoder {
  static final _decimal = RegExp(r'^\d+$');

  // Growable byte buffer. Bytes before [_start] are already consumed.
  Uint8List _buffer = Uint8List(0);
  int _length = 0; // Valid bytes in _buffer are [0, _length).
  int _start = 0; // Next unconsumed byte.

  // Resume point for the header-separator scan, so each byte is examined once
  // instead of re-scanning from the start on every call.
  int _scanFrom = 0;

  // When the current frame's header has been parsed, the body length is known
  // and we only need to wait for enough bytes.
  int _bodyStart = -1;
  int _bodyLength = -1;
  Map<String, String> _headers = const {};

  int _ingestedBytes = 0;
  int _compactedBytes = 0;
  int _relocatedBytes = 0;

  /// Bytes copied from incoming chunks into the buffer; equals the input size.
  int get ingestedBytes => _ingestedBytes;

  /// Unconsumed bytes shifted to the buffer front. Compaction only runs when
  /// consumed bytes are at least as many as the bytes moved, so the total is
  /// bounded by the input size.
  int get compactedBytes => _compactedBytes;

  /// Unconsumed bytes moved into a larger buffer on growth. Capacity doubles,
  /// so the total stays below twice the largest buffered amount.
  int get relocatedBytes => _relocatedBytes;

  void addChunk(List<int> chunk) {
    if (chunk.isEmpty) return;
    _ensureCapacity(chunk.length);
    _buffer.setRange(_length, _length + chunk.length, chunk);
    _length += chunk.length;
    _ingestedBytes += chunk.length;
  }

  /// Returns the next complete message, or null when more bytes are needed.
  ///
  /// Throws [LspFrameException] when the current frame header is malformed;
  /// no message is produced for that frame.
  LspMessage? next() {
    if (_bodyStart < 0) {
      // Still looking for the end of the header block.
      final separator = _findHeaderSeparator();
      if (separator < 0) {
        _compactIfWorthwhile();
        return null;
      }
      _parseHeaders(separator);
      _bodyStart = separator + 4;
    }
    if (_length - _bodyStart < _bodyLength) {
      // Header parsed, body not fully arrived yet.
      _compactIfWorthwhile();
      return null;
    }
    final body = utf8.decode(
      Uint8List.sublistView(_buffer, _bodyStart, _bodyStart + _bodyLength),
    );
    final headers = _headers;
    // Advance past this frame.
    _start = _bodyStart + _bodyLength;
    _scanFrom = _start;
    _bodyStart = -1;
    _bodyLength = -1;
    _headers = const {};
    return LspMessage(body, headers: headers);
  }

  /// Signals end of input. Throws [LspFrameException] with
  /// [LspFrameErrorKind.truncated] when a partial frame is still buffered.
  void finish() {
    final pending = _length - _start;
    if (pending != 0) {
      throw LspFrameException(
        LspFrameErrorKind.truncated,
        'Input ended inside an LSP frame ($pending unconsumed bytes)',
      );
    }
  }

  // Scans for `\r\n\r\n` starting at [_scanFrom], returning its index in the
  // buffer or -1. Remembers progress so bytes are scanned at most once.
  int _findHeaderSeparator() {
    final buffer = _buffer;
    var i = _scanFrom < _start ? _start : _scanFrom;
    final end = _length - 3;
    while (i < end) {
      if (buffer[i] == 13 &&
          buffer[i + 1] == 10 &&
          buffer[i + 2] == 13 &&
          buffer[i + 3] == 10) {
        return i;
      }
      i++;
    }
    // Keep scan progress but never past the last 3 bytes (a separator could
    // still straddle the next chunk boundary).
    _scanFrom = i;
    return -1;
  }

  void _parseHeaders(int separator) {
    final String headerText;
    try {
      headerText = utf8.decode(
        Uint8List.sublistView(_buffer, _start, separator),
      );
    } on FormatException {
      throw LspFrameException(
        LspFrameErrorKind.invalidHeader,
        'LSP header block is not valid UTF-8',
      );
    }
    final headers = <String, String>{};
    for (final line in headerText.split('\r\n')) {
      if (line.isEmpty) continue;
      final colon = line.indexOf(':');
      if (colon <= 0) {
        throw LspFrameException(
          LspFrameErrorKind.invalidHeader,
          'Invalid LSP header line',
          rawValue: line,
        );
      }
      headers[line.substring(0, colon).toLowerCase()] =
          line.substring(colon + 1).trim();
    }
    final rawLength = headers['content-length'];
    if (rawLength == null) {
      throw LspFrameException(
        LspFrameErrorKind.missingContentLength,
        'LSP header has no Content-Length',
      );
    }
    // int.tryParse alone would accept forms such as "+12" or "0x1f".
    final length =
        _decimal.hasMatch(rawLength) ? int.tryParse(rawLength) : null;
    if (length == null) {
      throw LspFrameException(
        LspFrameErrorKind.invalidContentLength,
        'Content-Length is not a non-negative decimal integer',
        rawValue: rawLength,
      );
    }
    _headers = headers;
    _bodyLength = length;
  }

  // Drops already-consumed bytes when they dominate the buffer, keeping memory
  // bounded without shifting on every message.
  void _compactIfWorthwhile() {
    if (_start >= 64 * 1024 && _start * 2 >= _length) _compact();
  }

  void _ensureCapacity(int extra) {
    if (_buffer.length - _length >= extra) return;
    // Reuse the consumed prefix when it is at least as large as what has to
    // move; this keeps compaction cost bounded by consumed input.
    if (_start > 0 && _start * 2 >= _length) {
      _compact();
      if (_buffer.length - _length >= extra) return;
    }
    final remaining = _length - _start;
    final needed = remaining + extra;
    var newCapacity = _buffer.isEmpty ? 8192 : _buffer.length * 2;
    while (newCapacity < needed) {
      newCapacity *= 2;
    }
    // Only unconsumed bytes move into the new buffer.
    final grown = Uint8List(newCapacity);
    grown.setRange(0, remaining, _buffer, _start);
    _relocatedBytes += remaining;
    _buffer = grown;
    _rebase(remaining);
  }

  void _compact() {
    final remaining = _length - _start;
    _buffer.setRange(0, remaining, _buffer, _start);
    _compactedBytes += remaining;
    _rebase(remaining);
  }

  // Shifts all offsets after the unconsumed bytes moved to index 0.
  void _rebase(int remaining) {
    if (_bodyStart >= 0) _bodyStart -= _start;
    _scanFrom = _scanFrom > _start ? _scanFrom - _start : 0;
    _length = remaining;
    _start = 0;
  }
}

List<int> encodeLspMessage(String body) {
  final payload = utf8.encode(body);
  final header = utf8.encode('Content-Length: ${payload.length}\r\n\r\n');
  final out = Uint8List(header.length + payload.length);
  out.setRange(0, header.length, header);
  out.setRange(header.length, out.length, payload);
  return out;
}
