import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_analysis_server_proxy/dart_analysis_server_proxy.dart';
import 'package:dart_analysis_server_proxy/src/lsp_framing.dart'
    show LspFrameDecoder;
import 'package:test/test.dart';

import 'support/random_frames.dart';

void main() {
  test('parses fragmented and coalesced LSP messages', () async {
    final first = encodeLspMessage(
      jsonEncode({'id': 1, 'method': 'initialize'}),
    );
    final second = encodeLspMessage(
      jsonEncode({'id': 2, 'method': 'shutdown'}),
    );
    final bytes = <int>[...first, ...second];
    final messages =
        await Stream<List<int>>.fromIterable([
          bytes.sublist(0, 7),
          bytes.sublist(7, first.length + 3),
          bytes.sublist(first.length + 3),
        ]).transform(LspMessageReader()).toList();

    expect(messages, hasLength(2));
    expect(jsonDecode(messages[0].body), {'id': 1, 'method': 'initialize'});
    expect(jsonDecode(messages[1].body), {'id': 2, 'method': 'shutdown'});
  });

  test('uses UTF-8 byte length rather than character length', () {
    final bytes = encodeLspMessage('{"message":"分析"}');
    expect(utf8.decode(bytes), contains('Content-Length:'));
  });

  test(
    'streams many large messages without loss or quadratic blowup',
    () async {
      // Mimics a large-workspace diagnostics burst: many multi-hundred-KB
      // messages back to back. The previous List<int> + removeRange(0,n) reader
      // was O(n^2) and stalled here; this must complete quickly and losslessly.
      const messageCount = 400;
      final payloads = [
        for (var i = 0; i < messageCount; i++)
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'textDocument/publishDiagnostics',
            'params': {'id': i, 'blob': 'x' * 300000},
          }),
      ];
      // Keep the same 120 MB workload in byte buffers. A growable List<int>
      // plus copied chunks multiplies fixture memory before parsing begins.
      final builder = BytesBuilder(copy: false);
      for (final payload in payloads) {
        builder.add(Uint8List.fromList(encodeLspMessage(payload)));
      }
      final bytes = builder.takeBytes();

      final sw = Stopwatch()..start();
      final messages =
          await Stream<List<int>>.fromIterable(
            // Feed in modest chunks to exercise buffering across boundaries.
            [
              for (var i = 0; i < bytes.length; i += 65536)
                Uint8List.sublistView(
                  bytes,
                  i,
                  i + 65536 > bytes.length ? bytes.length : i + 65536,
                ),
            ],
          ).transform(LspMessageReader()).toList();
      sw.stop();

      expect(messages, hasLength(messageCount));
      expect(jsonDecode(messages.first.body)['params']['id'], 0);
      expect(jsonDecode(messages.last.body)['params']['id'], messageCount - 1);
      // Generous bound: linear parsing of ~120MB completes in well under this;
      // the old O(n^2) path blew far past it.
      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 20)),
        reason: 'framing should be linear, not quadratic',
      );
    },
  );

  test('handles a header split across chunk boundaries', () async {
    final frame = encodeLspMessage(jsonEncode({'id': 9, 'method': 'ping'}));
    // Split right inside the Content-Length header.
    final messages =
        await Stream<List<int>>.fromIterable([
          frame.sublist(0, 5),
          frame.sublist(5, 10),
          frame.sublist(10),
        ]).transform(LspMessageReader()).toList();
    expect(messages, hasLength(1));
    expect(jsonDecode(messages.single.body), {'id': 9, 'method': 'ping'});
  });

  group('properties', () {
    test('P1: any split decodes like a single chunk', () async {
      await forAllSeeds('P1 split equivalence', baseSeed: 0x1000, (c) async {
        final bodies = randomBodies(c.random);
        final bytes = randomValidStream(c.random, bodies);
        final chunks = randomSplit(c.random, bytes);
        c.input = describeChunks(bodies, chunks);

        final whole = await decodeChunks([bytes]);
        final split = await decodeChunks(chunks);
        expect(whole.error, isNull);
        expect(split.error, isNull);
        expect(_bodies(split.messages), _bodies(whole.messages));
        expect(_headers(split.messages), _headers(whole.messages));
        expect(_bodies(split.messages), bodies);
      });
    });

    test('P2: encode then decode round-trips byte for byte', () async {
      await forAllSeeds('P2 round trip', baseSeed: 0x2000, (c) async {
        final bodies = randomBodies(c.random);
        c.input = jsonEncode(bodies);
        final bytes = [for (final body in bodies) ...encodeLspMessage(body)];

        final outcome = await decodeChunks([bytes]);
        expect(outcome.error, isNull);
        expect(outcome.messages, hasLength(bodies.length));
        for (var i = 0; i < bodies.length; i++) {
          expect(
            utf8.encode(outcome.messages[i].body),
            utf8.encode(bodies[i]),
            reason: 'message $i',
          );
        }
      });
    });

    test('P3: buffer copies stay linear in the input size', () async {
      await forAllSeeds('P3 linear copies', baseSeed: 0x3000, (c) {
        // Large enough bodies to cross the 64 KiB compaction threshold.
        final count = c.random.nextInt(12);
        final bodies = [
          for (var i = 0; i < count; i++)
            c.random.nextInt(3) == 0
                ? jsonEncode({'blob': 'y' * c.random.nextInt(200000)})
                : randomBody(c.random),
        ];
        final bytes = randomValidStream(c.random, bodies);
        final chunks = randomSplit(c.random, bytes);
        c.input = describeChunks(bodies, chunks);

        final decoder = LspFrameDecoder();
        final decoded = <String>[];
        for (final chunk in chunks) {
          decoder.addChunk(chunk);
          LspMessage? message;
          while ((message = decoder.next()) != null) {
            decoded.add(message!.body);
          }
        }
        decoder.finish();

        final n = bytes.length;
        expect(decoded, bodies);
        expect(decoder.ingestedBytes, n);
        expect(
          decoder.ingestedBytes + decoder.compactedBytes,
          lessThanOrEqualTo(2 * n),
          reason: 'setRange + compaction copies',
        );
        expect(
          decoder.relocatedBytes,
          lessThanOrEqualTo(2 * n),
          reason: 'growth relocation copies',
        );
      });
    });

    test('P4: missing or invalid Content-Length is rejected', () async {
      await forAllSeeds('P4 header validation', baseSeed: 0x4000, (c) async {
        final prefix = randomBodies(c.random, maxCount: 3);
        final missing = c.random.nextBool();
        final value = missing ? null : randomInvalidContentLength(c.random);
        final header =
            missing
                ? 'Content-Type: application/vscode-jsonrpc'
                : 'Content-Length: $value';
        final bytes = [
          ...randomValidStream(c.random, prefix),
          ...utf8.encode('$header\r\n\r\n{}'),
          // A valid frame after the bad one must not be produced either.
          ...encodeLspMessage('{"after":true}'),
        ];
        final chunks = randomSplit(c.random, bytes);
        c.input = '${describeChunks(prefix, chunks)} header=$header';

        final outcome = await decodeChunks(chunks);
        expect(_bodies(outcome.messages), prefix);
        final error = outcome.error;
        expect(error, isA<LspFrameException>());
        error as LspFrameException;
        if (missing) {
          expect(error.kind, LspFrameErrorKind.missingContentLength);
          expect(error.rawValue, isNull);
        } else {
          expect(error.kind, LspFrameErrorKind.invalidContentLength);
          expect(error.rawValue, value);
        }
      });
    });
  });

  group('frame errors', () {
    Future<LspFrameException> errorFor(String raw) async {
      final outcome = await decodeChunks([utf8.encode(raw)]);
      expect(outcome.messages, isEmpty);
      return outcome.error as LspFrameException;
    }

    test('rejects a header line without a name', () async {
      final error = await errorFor('Content-Length: 2\r\nbogus\r\n\r\n{}');
      expect(error.kind, LspFrameErrorKind.invalidHeader);
      expect(error.rawValue, 'bogus');
      expect(
        (await errorFor(': 2\r\n\r\n{}')).kind,
        LspFrameErrorKind.invalidHeader,
      );
    });

    test('rejects a header block that is not UTF-8', () async {
      final outcome = await decodeChunks([
        [0xff, 0xfe, ...utf8.encode(': 1\r\n\r\n{')],
      ]);
      expect(outcome.messages, isEmpty);
      expect(
        (outcome.error as LspFrameException).kind,
        LspFrameErrorKind.invalidHeader,
      );
    });

    test('reports truncation inside the header or the body', () async {
      expect(
        (await errorFor('Content-Length: 2\r\n')).kind,
        LspFrameErrorKind.truncated,
      );
      expect(
        (await errorFor('Content-Length: 10\r\n\r\n{}')).kind,
        LspFrameErrorKind.truncated,
      );
    });

    test('accepts Content-Length 0 and ignores empty chunks', () async {
      final outcome = await decodeChunks([
        const [],
        utf8.encode('Content-Length: 0\r\n\r\n'),
        const [],
      ]);
      expect(outcome.error, isNull);
      expect(_bodies(outcome.messages), ['']);
    });
  });

  test('decodes a 10 MB stream fed in 1-4096 byte chunks', () async {
    final random = Random(0x5000);
    final bodies = <String>[];
    var total = 0;
    while (total < 10 * 1024 * 1024) {
      final body = jsonEncode({
        'jsonrpc': '2.0',
        'method': 'textDocument/publishDiagnostics',
        'params': {
          'id': bodies.length,
          'text': '诊断😀' * random.nextInt(2000),
          'blob': 'z' * random.nextInt(120000),
        },
      });
      bodies.add(body);
      total += encodeLspMessage(body).length;
    }
    final bytes = [for (final body in bodies) ...encodeLspMessage(body)];
    final chunks = <List<int>>[];
    for (var i = 0; i < bytes.length;) {
      final end = min(bytes.length, i + 1 + random.nextInt(4096));
      chunks.add(bytes.sublist(i, end));
      i = end;
    }

    final outcome = await decodeChunks(chunks);
    expect(bytes.length, greaterThanOrEqualTo(10 * 1024 * 1024));
    expect(outcome.error, isNull);
    expect(outcome.messages, hasLength(bodies.length));
    expect(_bodies(outcome.messages), bodies);
  });
}

List<String> _bodies(List<LspMessage> messages) => [
  for (final message in messages) message.body,
];

List<Map<String, String>> _headers(List<LspMessage> messages) => [
  for (final message in messages) message.headers,
];
