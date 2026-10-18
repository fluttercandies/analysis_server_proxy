import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_server_proxy/dart_analysis_server_proxy.dart';

/// Stand-in analysis server for `proxy_stdout_test.dart` and
/// `bridge_full_check_test.dart`.
///
/// - `echo`: answers every request, emits a notification per request and
///   exits 0 on the `exit` notification or when stdin closes.
/// - `crash`: writes two stderr lines and exits 3 without touching stdout.
/// - `diag` / `chatty` / `edit`: publish diagnostics after `initialized`;
///   see below.
Future<void> main(List<String> arguments) async {
  final mode = arguments.isEmpty ? 'echo' : arguments.first;
  if (mode == 'crash') {
    stderr.writeln('boom: upstream failed');
    stderr.writeln('second stderr line');
    await stderr.flush();
    exit(3);
  }

  stderr.writeln('fake upstream ready');
  String? rootUri;
  void send(Map<String, Object?> json) =>
      stdout.add(encodeLspMessage(jsonEncode({'jsonrpc': '2.0', ...json})));
  void publish(String file, String code, int severity) => send({
    'method': 'textDocument/publishDiagnostics',
    'params': {
      'uri': '$rootUri/$file',
      'diagnostics': [
        {
          'code': code,
          'severity': severity,
          'message': code,
          'range': {
            'start': {'line': 0, 'character': 0},
            'end': {'line': 0, 'character': 1},
          },
        },
      ],
    },
  });
  void publishUri(String uri, String code, int severity) => send({
    'method': 'textDocument/publishDiagnostics',
    'params': {
      'uri': uri,
      'diagnostics': [
        {
          'code': code,
          'severity': severity,
          'message': code,
          'range': {
            'start': {'line': 0, 'character': 0},
            'end': {'line': 0, 'character': 1},
          },
        },
      ],
    },
  });
  void status(bool analyzing) => send({
    'method': r'$/analyzerStatus',
    'params': {'isAnalyzing': analyzing},
  });

  await for (final message in stdin.transform(LspMessageReader())) {
    final json = jsonDecode(message.body) as Map<String, Object?>;
    if (json['method'] == 'exit') break;
    final id = json['id'];
    if (mode == 'edit' && json['method'] == 'workspace/didChangeWatchedFiles') {
      // `edit`: like an analyzer that never notices disk edits by itself. On
      // an explicit change notice it runs a pass with a 1.5s publish gap in
      // the middle, then reports an error on the changed file.
      final changes = (json['params'] as Map)['changes'] as List;
      final uri = (changes.first as Map)['uri'] as String;
      status(true);
      publish('lib/a.dart', 'unused_import', 2);
      await stdout.flush();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      publishUri(uri, 'edited_error', 1);
      status(false);
      await stdout.flush();
      continue;
    }
    if (mode == 'diag' || mode == 'chatty' || mode == 'edit') {
      // `diag`: core diagnostics, idle, then a plugin diagnostic 800ms later,
      // like the analysis server running analyzer plugins after it goes idle.
      // `chatty`: keeps publishing every 200ms and never goes quiet.
      if (json['method'] == 'initialize') {
        rootUri = (json['params'] as Map)['rootUri'] as String;
        send({
          'id': id,
          'result': {'capabilities': <String, Object?>{}},
        });
        await stdout.flush();
        continue;
      }
      if (json['method'] == 'initialized') {
        status(true);
        publish('lib/a.dart', 'unused_import', 2);
        status(false);
        await stdout.flush();
        if (mode == 'edit') continue;
        if (mode == 'diag') {
          Timer(const Duration(milliseconds: 800), () {
            publish('lib/b.dart', 'late_plugin_lint', 3);
          });
        } else {
          var n = 0;
          Timer.periodic(const Duration(milliseconds: 200), (_) {
            publish('lib/c${n++}.dart', 'chatty', 3);
          });
        }
        continue;
      }
      if (json['method'] == r'dart/reanalyze') {
        // A full check must not force a cold reanalysis of the IDE workspace.
        send({
          'id': id,
          'error': {'code': -32601, 'message': 'reanalyze is not expected'},
        });
        continue;
      }
    }
    if (id == null) continue;
    stdout.add(
      encodeLspMessage(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'window/logMessage',
          'params': {'type': 3, 'message': '分析 ${json['method']} 😀'},
        }),
      ),
    );
    stdout.add(
      encodeLspMessage(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {'echo': json['method']},
        }),
      ),
    );
    await stdout.flush();
  }
  await stderr.flush();
  exit(0);
}
