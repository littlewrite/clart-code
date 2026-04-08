import 'dart:io';
import 'dart:convert';

import 'tool_models.dart';

List<Tool> builtinBaseTools({String? cwd}) {
  return [
    ReadTool(cwd: cwd),
    WriteTool(cwd: cwd),
    EditTool(cwd: cwd),
    GlobTool(cwd: cwd),
    GrepTool(cwd: cwd),
    ShellTool(cwd: cwd),
  ];
}

class ReadTool implements Tool {
  const ReadTool({this.cwd});

  final String? cwd;

  @override
  String get name => 'read';

  @override
  String? get title => null;

  @override
  String get description => 'Read a UTF-8 text file from the local filesystem.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Absolute or relative file path to read.',
          },
        },
        'required': ['path'],
      };

  @override
  Map<String, Object?>? get annotations => null;

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.parallelSafe;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    try {
      final path = _requiredTrimmedStringInput(
        invocation.input,
        'path',
        tool: name,
      );
      final resolvedPath = _resolvePath(path, cwd: cwd);
      final entityType = FileSystemEntity.typeSync(resolvedPath);
      if (entityType == FileSystemEntityType.notFound) {
        return ToolExecutionResult.failure(
          tool: name,
          errorCode: 'file_not_found',
          errorMessage: 'file not found: $resolvedPath',
          metadata: {
            'path': resolvedPath,
            if (cwd != null) 'cwd': cwd,
          },
        );
      }
      if (entityType != FileSystemEntityType.file) {
        return ToolExecutionResult.failure(
          tool: name,
          errorCode: 'path_is_directory',
          errorMessage: 'read tool requires a file path: $resolvedPath',
          metadata: {
            'path': resolvedPath,
            if (cwd != null) 'cwd': cwd,
          },
        );
      }

      final file = File(resolvedPath);
      final content = await file.readAsString();
      return ToolExecutionResult(
        tool: name,
        ok: true,
        output: content,
        metadata: {
          'path': file.path,
          if (cwd != null) 'cwd': cwd,
        },
      );
    } on FormatException catch (error) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'invalid_input',
        errorMessage: error.message,
      );
    } catch (error) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'io_error',
        errorMessage: '$error',
      );
    }
  }
}

class WriteTool implements Tool {
  const WriteTool({this.cwd});

  final String? cwd;

  @override
  String get name => 'write';

  @override
  String? get title => null;

  @override
  String get description => 'Write UTF-8 text content to a local file path.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Absolute or relative file path to write.',
          },
          'content': {
            'type': 'string',
            'description': 'UTF-8 text content to write to the file.',
          },
        },
        'required': ['path', 'content'],
      };

  @override
  Map<String, Object?>? get annotations => null;

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.serialOnly;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    try {
      final path = _requiredTrimmedStringInput(
        invocation.input,
        'path',
        tool: name,
      );
      final content = _requiredStringInput(
        invocation.input,
        'content',
        tool: name,
      );
      final resolvedPath = _resolvePath(path, cwd: cwd);
      final entityType = FileSystemEntity.typeSync(resolvedPath);
      if (entityType == FileSystemEntityType.directory) {
        return ToolExecutionResult.failure(
          tool: name,
          errorCode: 'path_is_directory',
          errorMessage: 'write tool requires a file path: $resolvedPath',
          metadata: {
            'path': resolvedPath,
            if (cwd != null) 'cwd': cwd,
          },
        );
      }

      final file = File(resolvedPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
      return ToolExecutionResult(
        tool: name,
        ok: true,
        output: 'WROTE ${file.path}',
        metadata: {
          'path': file.path,
          'bytes': utf8.encode(content).length,
          if (cwd != null) 'cwd': cwd,
        },
      );
    } on FormatException catch (error) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'invalid_input',
        errorMessage: error.message,
      );
    } catch (error) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'io_error',
        errorMessage: '$error',
      );
    }
  }
}

class ShellTool implements Tool {
  const ShellTool({
    this.cwd,
    this.defaultTimeout = const Duration(seconds: 30),
  });

  final String? cwd;
  final Duration defaultTimeout;

  @override
  String get name => 'shell';

  @override
  String? get title => null;

  @override
  String get description =>
      'Run a shell command in the local environment and return its output.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'command': {
            'type': 'string',
            'description': 'Shell command text to execute.',
          },
          'cwd': {
            'type': 'string',
            'description': 'Optional working directory override.',
          },
          'env': {
            'type': 'object',
            'description': 'Optional environment variable overrides.',
          },
          'timeoutMs': {
            'type': 'integer',
            'description': 'Optional timeout override in milliseconds.',
          },
        },
        'required': ['command'],
      };

  @override
  Map<String, Object?>? get annotations => null;

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.serialOnly;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    try {
      final command = _requiredTrimmedStringInput(
        invocation.input,
        'command',
        tool: name,
      );
      final requestedCwd = _optionalTrimmedStringInput(
        invocation.input,
        'cwd',
        tool: name,
      );
      final workingDirectory = _resolveWorkingDirectory(
            requestedCwd,
            cwd: cwd,
          ) ??
          Directory.current.path;
      final timeoutMs = _optionalPositiveIntInput(
            invocation.input,
            'timeoutMs',
            tool: name,
          ) ??
          defaultTimeout.inMilliseconds;
      final workingDirectoryType = FileSystemEntity.typeSync(workingDirectory);
      if (workingDirectoryType == FileSystemEntityType.notFound) {
        return ToolExecutionResult.failure(
          tool: name,
          errorCode: 'path_not_found',
          errorMessage: 'shell cwd not found: $workingDirectory',
          metadata: {
            'cwd': workingDirectory,
          },
        );
      }
      if (workingDirectoryType != FileSystemEntityType.directory) {
        return ToolExecutionResult.failure(
          tool: name,
          errorCode: 'path_not_directory',
          errorMessage: 'shell cwd must be a directory: $workingDirectory',
          metadata: {
            'cwd': workingDirectory,
          },
        );
      }

      final environment = _parseShellEnvironment(invocation.input['env']);
      final process = await Process.start(
        _shellExecutable(),
        _shellArguments(command),
        workingDirectory: workingDirectory,
        environment: environment,
      );
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();

      var timedOut = false;
      final exitCode = await process.exitCode.timeout(
        Duration(milliseconds: timeoutMs),
        onTimeout: () {
          timedOut = true;
          process.kill();
          return -1;
        },
      );
      final stdout = (await stdoutFuture).trimRight();
      final stderr = (await stderrFuture).trimRight();
      final output = _renderShellOutput(stdout: stdout, stderr: stderr);
      final metadata = <String, Object?>{
        'command': command,
        'cwd': workingDirectory,
        'exitCode': timedOut ? null : exitCode,
        'stdout': stdout,
        'stderr': stderr,
        'timeoutMs': timeoutMs,
      };

      if (timedOut) {
        return ToolExecutionResult.failure(
          tool: name,
          errorCode: 'timeout',
          errorMessage: 'shell command timed out after ${timeoutMs}ms',
          metadata: metadata,
        );
      }

      if (exitCode != 0) {
        final suffix = output.isEmpty ? '' : ': $output';
        return ToolExecutionResult.failure(
          tool: name,
          errorCode: 'command_failed',
          errorMessage: 'shell command exited with code $exitCode$suffix',
          metadata: metadata,
        );
      }

      return ToolExecutionResult(
        tool: name,
        ok: true,
        output: output,
        metadata: metadata,
      );
    } on FormatException catch (error) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'invalid_input',
        errorMessage: error.message,
      );
    } catch (error) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'spawn_failed',
        errorMessage: '$error',
      );
    }
  }
}

@Deprecated('Use ShellTool instead.')
class ShellStubTool extends ShellTool {
  const ShellStubTool({
    super.cwd,
    super.defaultTimeout,
  });
}

class EditTool implements Tool {
  const EditTool({this.cwd});

  final String? cwd;

  @override
  String get name => 'edit';

  @override
  String? get title => null;

  @override
  String get description =>
      'Replace exact text in a UTF-8 file using a single or global replacement.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Absolute or relative file path to edit.',
          },
          'oldText': {
            'type': 'string',
            'description': 'Existing text to replace.',
          },
          'newText': {
            'type': 'string',
            'description': 'Replacement text.',
          },
          'replaceAll': {
            'type': 'boolean',
            'description': 'Replace every occurrence when true.',
          },
        },
        'required': ['path', 'oldText', 'newText'],
      };

  @override
  Map<String, Object?>? get annotations => null;

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.serialOnly;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    try {
      final path = _requiredTrimmedStringInput(
        invocation.input,
        'path',
        tool: name,
      );
      final oldText = _requiredTrimmedStringInput(
        invocation.input,
        'oldText',
        tool: name,
      );
      final newText = _requiredStringInput(
        invocation.input,
        'newText',
        tool: name,
      );
      final replaceAll = _optionalBoolInput(
            invocation.input,
            'replaceAll',
            tool: name,
          ) ??
          false;
      final resolvedPath = _resolvePath(path, cwd: cwd);
      final entityType = FileSystemEntity.typeSync(resolvedPath);
      if (entityType == FileSystemEntityType.notFound) {
        return ToolExecutionResult.failure(
          tool: name,
          errorCode: 'file_not_found',
          errorMessage: 'file not found: $resolvedPath',
          metadata: {
            'path': resolvedPath,
            if (cwd != null) 'cwd': cwd,
          },
        );
      }
      if (entityType != FileSystemEntityType.file) {
        return ToolExecutionResult.failure(
          tool: name,
          errorCode: 'path_is_directory',
          errorMessage: 'edit tool requires a file path: $resolvedPath',
          metadata: {
            'path': resolvedPath,
            if (cwd != null) 'cwd': cwd,
          },
        );
      }

      final file = File(resolvedPath);
      final original = await file.readAsString();
      if (!original.contains(oldText)) {
        return ToolExecutionResult.failure(
          tool: name,
          errorCode: 'text_not_found',
          errorMessage: 'oldText was not found in ${file.path}',
          metadata: {
            'path': file.path,
            if (cwd != null) 'cwd': cwd,
          },
        );
      }
      final replacements = _countOccurrences(original, oldText);
      final updated = replaceAll
          ? original.replaceAll(oldText, newText)
          : original.replaceFirst(oldText, newText);
      await file.writeAsString(updated);
      final appliedCount = replaceAll ? replacements : 1;
      return ToolExecutionResult(
        tool: name,
        ok: true,
        output: 'UPDATED ${file.path} ($appliedCount replacement(s))',
        metadata: {
          'path': file.path,
          'replacements': appliedCount,
          if (cwd != null) 'cwd': cwd,
        },
      );
    } on FormatException catch (error) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'invalid_input',
        errorMessage: error.message,
      );
    } catch (error) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'io_error',
        errorMessage: '$error',
      );
    }
  }
}

class GlobTool implements Tool {
  const GlobTool({this.cwd});

  final String? cwd;

  @override
  String get name => 'glob';

  @override
  String? get title => null;

  @override
  String get description =>
      'List files and directories matching a glob pattern under a workspace path.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'pattern': {
            'type': 'string',
            'description': 'Glob pattern such as "**/*.dart" or "*.md".',
          },
          'cwd': {
            'type': 'string',
            'description': 'Optional search root override.',
          },
        },
        'required': ['pattern'],
      };

  @override
  Map<String, Object?>? get annotations => null;

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.parallelSafe;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    try {
      final pattern = _requiredTrimmedStringInput(
        invocation.input,
        'pattern',
        tool: name,
      );
      final requestedCwd = _optionalTrimmedStringInput(
        invocation.input,
        'cwd',
        tool: name,
      );
      final root = _resolveWorkingDirectory(requestedCwd, cwd: cwd) ??
          Directory.current.path;
      final entityType = FileSystemEntity.typeSync(root);
      if (entityType == FileSystemEntityType.notFound) {
        return ToolExecutionResult.failure(
          tool: name,
          errorCode: 'path_not_found',
          errorMessage: 'glob root not found: $root',
          metadata: {
            'cwd': root,
            'pattern': pattern,
          },
        );
      }
      if (entityType != FileSystemEntityType.directory) {
        return ToolExecutionResult.failure(
          tool: name,
          errorCode: 'path_not_directory',
          errorMessage: 'glob cwd must be a directory: $root',
          metadata: {
            'cwd': root,
            'pattern': pattern,
          },
        );
      }

      final directory = Directory(root);
      final matcher = _globToRegExp(pattern);
      final matches = <String>[];
      await for (final entity
          in directory.list(recursive: true, followLinks: false)) {
        final relativePath = _relativePath(entity.path, directory.path);
        final normalized = _normalizeForMatch(relativePath);
        if (matcher.hasMatch(normalized)) {
          matches.add(relativePath);
        }
      }
      matches.sort();
      return ToolExecutionResult(
        tool: name,
        ok: true,
        output: matches.join('\n'),
        metadata: {
          'count': matches.length,
          'cwd': directory.path,
          'pattern': pattern,
        },
      );
    } on FormatException catch (error) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'invalid_input',
        errorMessage: error.message,
      );
    }
  }
}

class GrepTool implements Tool {
  const GrepTool({this.cwd});

  final String? cwd;

  @override
  String get name => 'grep';

  @override
  String? get title => null;

  @override
  String get description =>
      'Search for text inside a file or directory tree and return matching lines.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'pattern': {
            'type': 'string',
            'description': 'Text or regex pattern to search for.',
          },
          'path': {
            'type': 'string',
            'description':
                'Optional file or directory path. Defaults to current cwd.',
          },
          'regex': {
            'type': 'boolean',
            'description':
                'Interpret pattern as a regular expression when true.',
          },
          'caseSensitive': {
            'type': 'boolean',
            'description': 'Case-sensitive matching when true.',
          },
        },
        'required': ['pattern'],
      };

  @override
  Map<String, Object?>? get annotations => null;

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.parallelSafe;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    try {
      final pattern = _requiredTrimmedStringInput(
        invocation.input,
        'pattern',
        tool: name,
      );
      final searchPath = _optionalTrimmedStringInput(
            invocation.input,
            'path',
            tool: name,
          ) ??
          '.';
      final resolvedPath = _resolvePath(searchPath, cwd: cwd);
      final regexEnabled = _optionalBoolInput(
            invocation.input,
            'regex',
            tool: name,
          ) ??
          false;
      final caseSensitive = _optionalBoolInput(
            invocation.input,
            'caseSensitive',
            tool: name,
          ) ??
          true;
      final entityType = FileSystemEntity.typeSync(resolvedPath);
      if (entityType == FileSystemEntityType.notFound) {
        return ToolExecutionResult.failure(
          tool: name,
          errorCode: 'path_not_found',
          errorMessage: 'grep path not found: $resolvedPath',
          metadata: {
            'path': resolvedPath,
            'pattern': pattern,
          },
        );
      }

      RegExp? matcher;
      if (regexEnabled) {
        try {
          matcher =
              RegExp(pattern, caseSensitive: caseSensitive, multiLine: true);
        } catch (error) {
          return ToolExecutionResult.failure(
            tool: name,
            errorCode: 'invalid_regex',
            errorMessage: 'invalid regex: $error',
            metadata: {
              'path': resolvedPath,
              'pattern': pattern,
            },
          );
        }
      }

      final matches = <String>[];
      final rootPath = entityType == FileSystemEntityType.directory
          ? resolvedPath
          : File(resolvedPath).parent.path;
      await for (final file
          in _enumerateSearchFiles(resolvedPath, entityType)) {
        try {
          final lines = await file.readAsLines();
          for (var index = 0; index < lines.length; index++) {
            final line = lines[index];
            final matched = regexEnabled
                ? matcher!.hasMatch(line)
                : _containsPattern(
                    line,
                    pattern,
                    caseSensitive: caseSensitive,
                  );
            if (matched) {
              matches.add(
                '${_relativePath(file.path, rootPath)}:${index + 1}:$line',
              );
            }
          }
        } catch (_) {
          // Skip unreadable or non-text files to keep grep resilient.
        }
      }
      return ToolExecutionResult(
        tool: name,
        ok: true,
        output: matches.join('\n'),
        metadata: {
          'count': matches.length,
          'path': resolvedPath,
          'pattern': pattern,
          'regex': regexEnabled,
          'caseSensitive': caseSensitive,
        },
      );
    } on FormatException catch (error) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'invalid_input',
        errorMessage: error.message,
      );
    }
  }
}

String _requiredTrimmedStringInput(
  Map<String, Object?> input,
  String key, {
  required String tool,
}) {
  final value = input[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$tool tool requires non-empty "$key"');
  }
  return value.trim();
}

String _requiredStringInput(
  Map<String, Object?> input,
  String key, {
  required String tool,
}) {
  final value = input[key];
  if (value is! String) {
    throw FormatException('$tool tool requires string "$key"');
  }
  return value;
}

String? _optionalTrimmedStringInput(
  Map<String, Object?> input,
  String key, {
  required String tool,
}) {
  final value = input[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw FormatException('$tool tool "$key" must be a string');
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

bool? _optionalBoolInput(
  Map<String, Object?> input,
  String key, {
  required String tool,
}) {
  final value = input[key];
  if (value == null) {
    return null;
  }
  if (value is! bool) {
    throw FormatException('$tool tool "$key" must be a boolean');
  }
  return value;
}

int? _optionalPositiveIntInput(
  Map<String, Object?> input,
  String key, {
  required String tool,
}) {
  final value = input[key];
  if (value == null) {
    return null;
  }
  if (value is! num || !value.isFinite || value % 1 != 0) {
    throw FormatException('$tool tool "$key" must be a positive integer');
  }
  final intValue = value.toInt();
  if (intValue < 1) {
    throw FormatException('$tool tool "$key" must be a positive integer');
  }
  return intValue;
}

String _resolvePath(String path, {String? cwd}) {
  final trimmed = path.trim();
  if (trimmed.isEmpty || File(trimmed).isAbsolute) {
    return trimmed;
  }
  final base = cwd?.trim();
  if (base == null || base.isEmpty) {
    return trimmed;
  }
  return Directory(base).uri.resolve(trimmed).toFilePath();
}

String? _resolveWorkingDirectory(String? requested, {String? cwd}) {
  final trimmed = requested?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return cwd;
  }
  return _resolvePath(trimmed, cwd: cwd);
}

Map<String, String>? _parseShellEnvironment(Object? raw) {
  if (raw == null) {
    return null;
  }
  if (raw is! Map) {
    throw const FormatException('shell tool "env" must be an object');
  }
  final parsed = <String, String>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is! String || key.trim().isEmpty) {
      throw const FormatException(
        'shell tool "env" keys must be non-empty strings',
      );
    }
    final value = entry.value;
    if (value is! String) {
      throw FormatException(
        'shell tool env "$key" must be a string',
      );
    }
    parsed[key] = value;
  }
  return parsed;
}

String _shellExecutable() {
  if (Platform.isWindows) {
    return 'cmd.exe';
  }
  return '/bin/sh';
}

List<String> _shellArguments(String command) {
  if (Platform.isWindows) {
    return ['/c', command];
  }
  return ['-lc', command];
}

String _renderShellOutput({
  required String stdout,
  required String stderr,
}) {
  if (stdout.isEmpty && stderr.isEmpty) {
    return '';
  }
  if (stderr.isEmpty) {
    return stdout;
  }
  if (stdout.isEmpty) {
    return '[stderr]\n$stderr';
  }
  return '$stdout\n[stderr]\n$stderr';
}

int _countOccurrences(String text, String needle) {
  var count = 0;
  var start = 0;
  while (true) {
    final index = text.indexOf(needle, start);
    if (index < 0) {
      return count;
    }
    count += 1;
    start = index + needle.length;
  }
}

String _normalizeForMatch(String path) => path.replaceAll('\\', '/');

String _relativePath(String path, String root) {
  final normalizedPath = path.replaceAll('\\', Platform.pathSeparator);
  final normalizedRoot = root.replaceAll('\\', Platform.pathSeparator);
  if (normalizedPath == normalizedRoot) {
    return '.';
  }
  final prefix = normalizedRoot.endsWith(Platform.pathSeparator)
      ? normalizedRoot
      : '$normalizedRoot${Platform.pathSeparator}';
  if (normalizedPath.startsWith(prefix)) {
    return normalizedPath.substring(prefix.length);
  }
  return normalizedPath;
}

RegExp _globToRegExp(String pattern) {
  final normalized = _normalizeForMatch(pattern);
  final buffer = StringBuffer('^');
  for (var index = 0; index < normalized.length; index++) {
    final char = normalized[index];
    if (char == '*') {
      final nextIsStar =
          index + 1 < normalized.length && normalized[index + 1] == '*';
      final slashAfterStar =
          index + 2 < normalized.length && normalized[index + 2] == '/';
      if (nextIsStar && slashAfterStar) {
        buffer.write(r'(?:.*/)?');
        index += 2;
        continue;
      }
      if (nextIsStar) {
        buffer.write('.*');
        index += 1;
        continue;
      }
      buffer.write(r'[^/]*');
      continue;
    }
    if (char == '?') {
      buffer.write(r'[^/]');
      continue;
    }
    buffer.write(RegExp.escape(char));
  }
  buffer.write(r'$');
  return RegExp(buffer.toString());
}

Stream<File> _enumerateSearchFiles(
  String resolvedPath,
  FileSystemEntityType entityType,
) async* {
  if (entityType == FileSystemEntityType.file) {
    yield File(resolvedPath);
    return;
  }
  await for (final entity
      in Directory(resolvedPath).list(recursive: true, followLinks: false)) {
    if (entity is File) {
      yield entity;
    }
  }
}

bool _containsPattern(
  String line,
  String pattern, {
  required bool caseSensitive,
}) {
  if (caseSensitive) {
    return line.contains(pattern);
  }
  return line.toLowerCase().contains(pattern.toLowerCase());
}
