enum ToolExecutionHint { serialOnly, parallelSafe }

class ToolInvocation {
  ToolInvocation({
    this.id,
    required this.name,
    Map<String, Object?> input = const {},
  }) : input = Map<String, Object?>.unmodifiable(
          Map<String, Object?>.from(input),
        );

  final String? id;
  final String name;
  final Map<String, Object?> input;

  ToolInvocation copyWith({
    String? id,
    String? name,
    Map<String, Object?>? input,
  }) {
    return ToolInvocation(
      id: id ?? this.id,
      name: name ?? this.name,
      input: input ?? this.input,
    );
  }
}

class ToolExecutionResult {
  const ToolExecutionResult({
    required this.tool,
    required this.ok,
    required this.output,
    this.errorCode,
    this.errorMessage,
    this.metadata,
  });

  final String tool;
  final bool ok;
  final String output;
  final String? errorCode;
  final String? errorMessage;
  final Map<String, Object?>? metadata;

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
    Map<String, Object?>? metadata,
  }) {
    return ToolExecutionResult(
      tool: tool,
      ok: false,
      output: '',
      errorCode: errorCode,
      errorMessage: errorMessage,
      metadata: metadata,
    );
  }

  ToolExecutionResult copyWith({
    String? tool,
    bool? ok,
    String? output,
    String? errorCode,
    String? errorMessage,
    Map<String, Object?>? metadata,
  }) {
    return ToolExecutionResult(
      tool: tool ?? this.tool,
      ok: ok ?? this.ok,
      output: output ?? this.output,
      errorCode: errorCode ?? this.errorCode,
      errorMessage: errorMessage ?? this.errorMessage,
      metadata: metadata ?? this.metadata,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'tool': tool,
      'ok': ok,
      'output': output,
      'error_code': errorCode,
      'error_message': errorMessage,
      if (metadata != null) 'metadata': metadata,
    };
  }
}

abstract class Tool {
  String get name;
  String? get title => null;
  String get description => '';
  Map<String, Object?>? get inputSchema => null;
  Map<String, Object?>? get annotations => null;
  ToolExecutionHint get executionHint;

  Future<ToolExecutionResult> run(ToolInvocation invocation);
}
