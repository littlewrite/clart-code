import 'dart:async';

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

typedef ToolHandler = FutureOr<ToolExecutionResult> Function(
  ToolInvocation invocation,
);

Tool tool({
  required String name,
  String? title,
  String description = '',
  Map<String, Object?>? inputSchema,
  Map<String, Object?>? annotations,
  ToolExecutionHint executionHint = ToolExecutionHint.serialOnly,
  required ToolHandler run,
}) {
  return CallbackTool(
    name: name,
    title: title,
    description: description,
    inputSchema: inputSchema,
    annotations: annotations,
    executionHint: executionHint,
    run: run,
  );
}

Tool defineTool({
  required String name,
  String? title,
  String description = '',
  Map<String, Object?>? inputSchema,
  Map<String, Object?>? annotations,
  ToolExecutionHint executionHint = ToolExecutionHint.serialOnly,
  required ToolHandler run,
}) {
  return tool(
    name: name,
    title: title,
    description: description,
    inputSchema: inputSchema,
    annotations: annotations,
    executionHint: executionHint,
    run: run,
  );
}

class CallbackTool implements Tool {
  CallbackTool({
    required String name,
    required ToolHandler run,
    this.title,
    this.description = '',
    Map<String, Object?>? inputSchema,
    Map<String, Object?>? annotations,
    this.executionHint = ToolExecutionHint.serialOnly,
  })  : _name = _normalizeToolName(name),
        _run = run,
        _inputSchema = inputSchema == null
            ? null
            : Map<String, Object?>.unmodifiable(
                Map<String, Object?>.from(inputSchema),
              ),
        _annotations = annotations == null
            ? null
            : Map<String, Object?>.unmodifiable(
                Map<String, Object?>.from(annotations),
              );

  final String _name;
  final ToolHandler _run;
  final Map<String, Object?>? _inputSchema;
  final Map<String, Object?>? _annotations;

  @override
  final String? title;

  @override
  final String description;

  @override
  final ToolExecutionHint executionHint;

  @override
  String get name => _name;

  @override
  Map<String, Object?>? get inputSchema => _inputSchema;

  @override
  Map<String, Object?>? get annotations => _annotations;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    return await _run(invocation);
  }
}

String _normalizeToolName(String name) {
  final normalized = name.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(name, 'name', 'tool name cannot be empty');
  }
  return normalized;
}
