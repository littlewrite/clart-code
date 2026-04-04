import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_console/dart_console.dart';
import 'package:interact_cli/interact_cli.dart';
import 'package:mason_logger/mason_logger.dart';

import '../core/app_config.dart';

class TrustDecision {
  const TrustDecision({
    required this.allowed,
    required this.persisted,
  });

  final bool allowed;
  final bool persisted;
}

class TrustStore {
  TrustStore(this.filePath);

  final String filePath;

  Future<bool> isTrusted(String directoryPath) async {
    final data = await _readAll();
    final normalized = _normalizePath(directoryPath);
    return data[normalized] == true;
  }

  Future<void> setTrusted({
    required String directoryPath,
    required bool trusted,
  }) async {
    final data = await _readAll();
    data[_normalizePath(directoryPath)] = trusted;

    final file = File(filePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(data));
  }

  Future<Map<String, dynamic>> _readAll() async {
    final file = File(filePath);
    if (!file.existsSync()) {
      return <String, dynamic>{};
    }

    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      // Keep startup resilient: treat invalid trust file as empty.
    }

    return <String, dynamic>{};
  }

  String _normalizePath(String input) {
    return Directory(input).absolute.path;
  }
}

class StartupExperience {
  StartupExperience({Logger? logger}) : _logger = logger ?? Logger();

  final Logger _logger;

  Future<TrustDecision> ensureTrusted({
    required String directoryPath,
    required TrustStore trustStore,
    required bool assumeTrusted,
    required bool denyTrust,
  }) async {
    if (denyTrust) {
      return const TrustDecision(allowed: false, persisted: false);
    }

    if (await trustStore.isTrusted(directoryPath)) {
      return const TrustDecision(allowed: true, persisted: false);
    }

    if (assumeTrusted) {
      await trustStore.setTrusted(
        directoryPath: directoryPath,
        trusted: true,
      );
      return const TrustDecision(allowed: true, persisted: true);
    }

    if (!stdin.hasTerminal) {
      return const TrustDecision(allowed: false, persisted: false);
    }

    final allowed = _promptForTrust(directoryPath);
    if (!allowed) {
      return const TrustDecision(allowed: false, persisted: false);
    }

    await trustStore.setTrusted(
      directoryPath: directoryPath,
      trusted: true,
    );
    return const TrustDecision(allowed: true, persisted: true);
  }

  void renderWelcome({
    required String cwd,
    required AppConfig config,
  }) {
    final version = '0.3.0';
    final provider = config.provider.name;
    final model = config.model ?? 'default';
    final width = _panelWidth();
    final innerWidth = width - 2;

    print('');
    print('╭${_fillTitle('─── Clart Code v$version ', innerWidth)}╮');
    print('│${_fitLine(' Welcome back!', innerWidth)}│');
    print(
      '│${_fitLine(' Tip: run /init in REPL (or clart_code init) to configure LLM.', innerWidth)}│',
    );
    print('│${_fitLine('', innerWidth)}│');
    print('│${_fitLine(' Provider: $provider', innerWidth)}│');
    print('│${_fitLine(' Model: $model', innerWidth)}│');
    print('│${_fitLine(' Workspace: $cwd', innerWidth)}│');
    print('╰${'─' * innerWidth}╯');
    print('');
    print('  /model to switch model');
    print('');
    print('> Try "create a util logging.py that..."');
  }

  bool _promptForTrust(String directoryPath) {
    final width = _panelWidth();
    final line = '─' * width;

    _logger.info('');
    _logger.info(line);
    _logger.info('Do you trust the files in this folder?');
    _logger.info(directoryPath);
    _logger.warn(
      'Clart Code may read, write, or execute files in this directory.',
      tag: '',
    );

    try {
      final selectedIndex = Select(
        prompt: 'Choose an action',
        options: const ['Yes, proceed', 'No, exit'],
        initialIndex: 1,
      ).interact();
      return selectedIndex == 0;
    } catch (_) {
      reset();
      return false;
    }
  }

  int _panelWidth() {
    if (!stdout.hasTerminal) {
      return 88;
    }

    var columns = stdout.terminalColumns;
    try {
      columns = Console().windowWidth;
    } catch (_) {
      // Fallback to stdout for environments where dart_console is unavailable.
    }

    return max(72, min(columns, 110));
  }

  String _fitLine(String value, int width) {
    if (value.length == width) {
      return value;
    }
    if (value.length < width) {
      return value + (' ' * (width - value.length));
    }
    if (width < 2) {
      return value.substring(0, width);
    }
    return '${value.substring(0, width - 1)}…';
  }

  String _fillTitle(String title, int width) {
    if (title.length >= width) {
      return _fitLine(title, width);
    }
    return title + ('─' * (width - title.length));
  }
}

String defaultTrustStorePath({String? cwd}) {
  final base = cwd ?? Directory.current.path;
  return '$base/.clart/trust.json';
}
