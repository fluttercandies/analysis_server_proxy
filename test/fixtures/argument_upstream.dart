import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  stderr.writeln(jsonEncode(arguments));
  await stdin.drain<void>();
  exitCode = 23;
}
