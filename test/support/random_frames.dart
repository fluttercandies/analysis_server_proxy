import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_analysis_server_proxy/dart_analysis_server_proxy.dart';

/// Minimum number of generated cases per property.
const pbtRuns = 200;

/// One generated case. Bodies record a description of the generated input so
/// a failure report can show what was fed in.
class PbtCase {
  PbtCase(this.seed) : random = Random(seed);

  final int seed;
  final Random random;
  String input = '<not recorded>';
}

/// Runs [body] for [runs] deterministic seeds starting at [baseSeed].
///
/// Set `PBT_SEED=<seed>` to replay a single reported seed. On failure the seed
/// and the recorded input are printed before the error is rethrown.
Future<void> forAllSeeds(
  String property,
  FutureOr<void> Function(PbtCase c) body, {
  required int baseSeed,
  int runs = pbtRuns,
}) async {
  final replay = int.tryParse(Platform.environment['PBT_SEED'] ?? '');
  final seeds =
      replay != null ? [replay] : [for (var i = 0; i < runs; i++) baseSeed + i];
  for (final seed in seeds) {
    final c = PbtCase(seed);
    try {
      await body(c);
    } on Object {
      final input =
          c.input.length > 2000 ? '${c.input.substring(0, 2000)}…' : c.input;
      print(
        '[$property] failed with seed=$seed '
        '(replay with PBT_SEED=$seed)\ninput: $input',
      );
      rethrow;
    }
  }
}

const _fragments = [
  'a',
  'Z',
  '0',
  ' ',
  '"',
  r'\',
  '\n',
  '\r\n',
  '\t',
  '{',
  '}',
  ':',
  'é',
  '分析',
  'Ω',
  '😀',
  '\u{1F9EA}',
  '\u0000',
];

String _randomText(Random random, int maxFragments) {
  final buffer = StringBuffer();
  final count = random.nextInt(maxFragments + 1);
  for (var i = 0; i < count; i++) {
    buffer.write(_fragments[random.nextInt(_fragments.length)]);
  }
  return buffer.toString();
}

/// A random JSON body, including `{}` and multi-byte UTF-8 content.
String randomBody(Random random) {
  final roll = random.nextInt(20);
  if (roll == 0) return '{}';
  if (roll == 1) return jsonEncode({'blob': 'x' * (1 + random.nextInt(20000))});
  final fields = <String, Object?>{};
  final fieldCount = 1 + random.nextInt(4);
  for (var i = 0; i < fieldCount; i++) {
    fields['${_randomText(random, 3)}$i'] = switch (random.nextInt(3)) {
      0 => random.nextInt(1 << 31),
      1 => [for (var j = 0; j < random.nextInt(4); j++) _randomText(random, 4)],
      _ => _randomText(random, 40),
    };
  }
  return jsonEncode(fields);
}

/// A random message sequence; empty sequences are generated on purpose.
List<String> randomBodies(Random random, {int maxCount = 8}) {
  final count = random.nextInt(maxCount + 1);
  return [for (var i = 0; i < count; i++) randomBody(random)];
}

/// Frames [body] with a random but valid header block: varying header-name
/// case, optional Content-Type before or after, and optional spaces.
List<int> randomValidFrame(Random random, String body) {
  final payload = utf8.encode(body);
  const names = ['Content-Length', 'content-length', 'CONTENT-LENGTH'];
  final lengthLine =
      '${names[random.nextInt(names.length)]}:'
      '${' ' * random.nextInt(3)}${payload.length}';
  const typeLine = 'Content-Type: application/vscode-jsonrpc; charset=utf-8';
  final lines = switch (random.nextInt(3)) {
    0 => [lengthLine],
    1 => [typeLine, lengthLine],
    _ => [lengthLine, typeLine],
  };
  return [...utf8.encode('${lines.join('\r\n')}\r\n\r\n'), ...payload];
}

/// Frames [bodies] back to back with [randomValidFrame].
List<int> randomValidStream(Random random, List<String> bodies) => [
  for (final body in bodies) ...randomValidFrame(random, body),
];

/// Returns a Content-Length value that does not match `^\d+$` (or overflows
/// an int), never contains CR/LF and has no surrounding whitespace.
String randomInvalidContentLength(Random random) {
  const fixed = [
    '',
    '+12',
    '-1',
    '1.5',
    '0x1f',
    '12abc',
    '1 2',
    '１２',
    '٣',
    '99999999999999999999999',
    'NaN',
  ];
  if (random.nextBool()) return fixed[random.nextInt(fixed.length)];
  const alphabet = 'abcXYZ+-._ /:#é分0123456789';
  final length = 1 + random.nextInt(12);
  var value =
      String.fromCharCodes([
        for (var i = 0; i < length; i++)
          alphabet.codeUnitAt(random.nextInt(alphabet.length)),
      ]).trim();
  if (RegExp(r'^\d*$').hasMatch(value)) value = '${value}x';
  return value;
}

/// Splits [bytes] into chunks: 0-byte and 1-byte chunks, small and large
/// chunks, and forced cuts inside every `\r\n\r\n` separator when
/// [cutSeparators] is set.
List<List<int>> randomSplit(
  Random random,
  List<int> bytes, {
  bool cutSeparators = true,
  int maxChunk = 4096,
}) {
  final cuts = <int>{};
  if (cutSeparators) {
    for (final separator in separatorOffsets(bytes)) {
      cuts.add(separator + 1 + random.nextInt(3));
    }
  }
  var position = 0;
  while (position < bytes.length) {
    position += _chunkSize(random, maxChunk);
    if (position < bytes.length) cuts.add(position);
  }
  final ordered = cuts.toList()..sort();
  final chunks = <List<int>>[];
  var from = 0;
  for (final cut in [...ordered, bytes.length]) {
    while (random.nextInt(8) == 0) {
      chunks.add(const []);
    }
    chunks.add(bytes.sublist(from, cut));
    from = cut;
  }
  return chunks;
}

int _chunkSize(Random random, int maxChunk) => switch (random.nextInt(10)) {
  0 || 1 => 1,
  2 || 3 || 4 => 2 + random.nextInt(63),
  _ => 1 + random.nextInt(maxChunk),
};

/// Start indexes of every `\r\n\r\n` in [bytes].
List<int> separatorOffsets(List<int> bytes) => [
  for (var i = 0; i + 3 < bytes.length; i++)
    if (bytes[i] == 13 &&
        bytes[i + 1] == 10 &&
        bytes[i + 2] == 13 &&
        bytes[i + 3] == 10)
      i,
];

/// Messages and the terminating error (if any) produced by [LspMessageReader].
class DecodeOutcome {
  DecodeOutcome(this.messages, this.error);

  final List<LspMessage> messages;
  final Object? error;
}

Future<DecodeOutcome> decodeChunks(List<List<int>> chunks) async {
  final messages = <LspMessage>[];
  Object? error;
  final done = Completer<void>();
  Stream<List<int>>.fromIterable(chunks)
      .transform(LspMessageReader())
      .listen(
        messages.add,
        onError: (Object e) => error = e,
        onDone: done.complete,
      );
  await done.future;
  return DecodeOutcome(messages, error);
}

/// Human-readable summary of generated chunks for failure reports.
String describeChunks(List<String> bodies, List<List<int>> chunks) =>
    'bodies=${jsonEncode(bodies)} '
    'chunkSizes=${chunks.map((c) => c.length).toList()}';
