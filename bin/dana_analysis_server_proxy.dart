import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:dart_analysis_server_proxy/dart_analysis_server_proxy.dart';

Future<void> main(List<String> arguments) => runProxy(arguments);

/// Runs command parsing and transparent forwarding with an optional process factory.
Future<void> runProxy(
  List<String> arguments, {
  Future<Process> Function(List<String> arguments)? startUpstream,
}) async {
  final runner = _ProxyRunner();
  // Management/help are explicit; analyzer flags and an empty argument list
  // keep the SDK's transparent forwarding contract.
  if (_isManagementInvocation(runner, arguments)) {
    try {
      await runner.run(arguments);
    } on UsageException catch (error) {
      stderr.writeln(error);
      exitCode = 64;
    }
    return;
  }
  final parser = runner.argParser;
  final separator = arguments.indexOf('--');
  final proxyArguments =
      separator < 0 ? const <String>[] : arguments.take(separator);
  final forwarded =
      separator < 0
          ? arguments
          : arguments.skip(separator + 1).toList(growable: false);
  ArgResults parsed;
  try {
    parsed = parser.parse(proxyArguments);
    if (parsed.command != null || parsed.rest.isNotEmpty) {
      throw FormatException('Only proxy options may precede --.');
    }
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(runner.usage);
    exitCode = 64;
    return;
  }
  if (parsed['help'] as bool) {
    runner.printUsage();
    return;
  }
  final upstreamExecutable = parsed['upstream-executable'] as String?;
  final proxy = LspProxy.languageServer(
    upstreamExecutable: upstreamExecutable,
    startUpstream: startUpstream,
  );
  exitCode = await proxy.run(forwarded);
}

/// Whether [arguments] address the management CLI rather than the analyzer:
/// a registered command (including `help`) first, or the runner's help flag
/// alone. Names come from the runner, so a new command needs no change here.
bool _isManagementInvocation(
  CommandRunner<void> runner,
  List<String> arguments,
) {
  if (arguments.isEmpty) return false;
  if (runner.commands.containsKey(arguments.first)) return true;
  final help = runner.argParser.options['help'];
  return arguments.length == 1 &&
      help != null &&
      (arguments.single == '--${help.name}' ||
          (help.abbr != null && arguments.single == '-${help.abbr}'));
}

class _ProxyRunner extends CommandRunner<void> {
  _ProxyRunner()
    : super('dana_analysis_server', 'Transparent Dart analysis server proxy.') {
    argParser.addOption(
      'upstream-executable',
      help: 'Dart executable used to run language-server.',
    );
    addCommand(_AnalyzerPathCommand());
  }
  @override
  String get usageFooter => '''
Proxy options precede --; arguments after -- are forwarded unchanged.
Without --, analyzer arguments (including an empty list) use transparent SDK mode.

Examples:
  dana_analysis_server analyzer-path --output .dart_tool/dana/dana_analysis_server_proxy.dill
  dana_analysis_server --upstream-executable <dart> -- --lsp''';
}

class _AnalyzerPathCommand extends Command<void> {
  @override
  String get name => 'analyzer-path';
  @override
  String get description =>
      'Compile the proxy for Dart-Code dart.analyzerPath and print the setting.';
  @override
  final ArgParser argParser = buildAnalyzerPathParser();
  @override
  bool get takesArguments => false;
  @override
  Future<void> run() async {
    exitCode = await runAnalyzerPath(argResults!);
  }
}
