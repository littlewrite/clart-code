import 'dart:io';

import 'package:clart_code/clart_code.dart';

Future<void> main(List<String> arguments) async {
  final code = await runCli(arguments);
  exit(code);
}
