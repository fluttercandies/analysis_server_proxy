import 'dart:io';

import 'package:dart_analysis_server_proxy/src/analyzer_path.dart';

/// Prints the resolved package root, or exits 1 if unavailable.
Future<void> main() async {
  final root = await resolvePackageRoot();
  if (root == null) {
    stderr.writeln('unresolved');
    exitCode = 1;
    return;
  }
  stdout.writeln(root.path);
}
