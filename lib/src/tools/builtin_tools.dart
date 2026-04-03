import 'dart:io';

import 'tool_models.dart';

class ReadTool implements Tool {
  @override
  String get name => 'read';

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
