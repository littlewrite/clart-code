enum ToolExecutionHint { serialOnly, parallelSafe }

class ToolInvocation {
  const ToolInvocation({
    required this.name,
    this.input = const {},
  });

  final String name;
  final Map<String, Object?> input;
}

class ToolExecutionResult {
  const ToolExecutionResult({
    required this.tool,
    required this.ok,
    required this.output,
    this.errorCode,
    this.errorMessage,
  });

  final String tool;
  final bool ok;
  final String output;
  final String? errorCode;
  final String? errorMessage;

  factory ToolExecutionResult.success({
    required String tool,
    required String output,
  }) {
    return ToolExecutionResult(tool: tool, ok: true, output: output);
  }

  factory ToolExecutionResult.failure({
    required String tool,
    required String errorCode,
    required String errorMessage,
  }) {
    return ToolExecutionResult(
      tool: tool,
      ok: false,
      output: '',
      errorCode: errorCode,
      errorMessage: errorMessage,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'tool': tool,
      'ok': ok,
      'output': output,
      'error_code': errorCode,
      'error_message': errorMessage,
    };
  }
}

abstract class Tool {
  String get name;
  String get description => '';
  Map<String, Object?>? get inputSchema => null;
  ToolExecutionHint get executionHint;

  Future<ToolExecutionResult> run(ToolInvocation invocation);
}
