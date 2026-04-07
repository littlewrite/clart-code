import 'dart:io';

import 'tool_models.dart';

class ReadTool implements Tool {
  @override
  String get name => 'read';

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
  ToolExecutionHint get executionHint => ToolExecutionHint.parallelSafe;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    final path = invocation.input['path'] as String?;
    if (path == null || path.trim().isEmpty) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'invalid_input',
        errorMessage: 'read tool requires non-empty "path"',
      );
    }

    final file = File(path);
    if (!file.existsSync()) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'file_not_found',
        errorMessage: 'file not found: $path',
      );
    }

    try {
      final content = await file.readAsString();
      return ToolExecutionResult.success(tool: name, output: content);
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
  @override
  String get name => 'write';

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
  ToolExecutionHint get executionHint => ToolExecutionHint.serialOnly;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    final path = invocation.input['path'] as String?;
    final content = invocation.input['content'] as String?;

    if (path == null || path.trim().isEmpty) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'invalid_input',
        errorMessage: 'write tool requires non-empty "path"',
      );
    }

    if (content == null) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'invalid_input',
        errorMessage: 'write tool requires "content"',
      );
    }

    try {
      await File(path).writeAsString(content);
      return ToolExecutionResult.success(tool: name, output: 'WROTE $path');
    } catch (error) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'io_error',
        errorMessage: '$error',
      );
    }
  }
}

class ShellStubTool implements Tool {
  @override
  String get name => 'shell';

  @override
  String get description =>
      'Run a shell command. This SDK phase currently returns a stubbed result.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'command': {
            'type': 'string',
            'description': 'Shell command text to execute.',
          },
        },
        'required': ['command'],
      };

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.serialOnly;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    final command = invocation.input['command'] as String?;
    if (command == null || command.trim().isEmpty) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'invalid_input',
        errorMessage: 'shell tool requires non-empty "command"',
      );
    }

    return ToolExecutionResult.success(
      tool: name,
      output:
          '[NOT_IMPLEMENTED] shell tool is stubbed in this iteration. command="$command"',
    );
  }
}
