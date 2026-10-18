import 'dart:io';
import '../../bin/dana_analysis_server_proxy.dart' as cli;

// Supplies a fake analyzer process while exercising the production CLI parser.
Future<void> main(List<String> arguments) async {
  final fixture = arguments[0];
  final dart = arguments[1];
  await cli.runProxy(
    arguments.skip(2).toList(),
    startUpstream: (args) => Process.start(dart, [fixture, ...args]),
  );
}
