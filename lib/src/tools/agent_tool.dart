import '../sdk/sdk_models.dart';
import 'tool_models.dart';

typedef AgentToolRunner = Future<AgentExecutionResult> Function(
  ClartCodeAgentDefinition definition,
  String prompt, {
  String? model,
});

class AgentExecutionResult {
  const AgentExecutionResult({
    required this.output,
    required this.turns,
    required this.isError,
    this.cascadedMessages = const [],
    this.name,
    this.model,
    this.sessionId,
    this.parentSessionId,
    this.errorCode,
    this.errorMessage,
  });

  final String output;
  final int turns;
  final bool isError;
  final List<ClartCodeSdkMessage> cascadedMessages;
  final String? name;
  final String? model;
  final String? sessionId;
  final String? parentSessionId;
  final String? errorCode;
  final String? errorMessage;
}

class AgentTool implements Tool {
  AgentTool({
    required List<ClartCodeAgentDefinition> agents,
    required this.runner,
  }) : _agents = {
          for (final agent in agents) agent.name: agent,
        };

  final Map<String, ClartCodeAgentDefinition> _agents;
  final AgentToolRunner runner;

  @override
  String get name => 'agent';

  @override
  String? get title => null;

  @override
  String get description =>
      'Launch a named subagent to handle a focused delegated task.';

  @override
  Map<String, Object?>? get annotations => null;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'agent': {
            'type': 'string',
            'description':
                'The named agent definition to run, for example "code-reviewer".',
          },
          'prompt': {
            'type': 'string',
            'description': 'The delegated task for the child agent.',
          },
          'model': {
            'type': 'string',
            'description': 'Optional model override for this child agent run.',
          },
        },
        'required': ['agent', 'prompt'],
      };

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.serialOnly;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    final rawAgent = invocation.input['agent'];
    if (rawAgent is! String || rawAgent.trim().isEmpty) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'invalid_input',
        errorMessage: 'agent requires a non-empty "agent" string input',
      );
    }

    final definition = _agents[rawAgent.trim()];
    if (definition == null) {
      final available = _agents.keys.toList()..sort();
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'agent_not_found',
        errorMessage: available.isEmpty
            ? 'unknown agent "${rawAgent.trim()}"'
            : 'unknown agent "${rawAgent.trim()}"; available agents: ${available.join(', ')}',
      );
    }

    final rawPrompt = invocation.input['prompt'];
    if (rawPrompt is! String || rawPrompt.trim().isEmpty) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'invalid_input',
        errorMessage: 'agent requires a non-empty "prompt" string input',
      );
    }

    final rawModel = invocation.input['model'];
    if (rawModel != null && rawModel is! String) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'invalid_input',
        errorMessage: 'agent model must be a string when provided',
      );
    }
    final requestedModel = rawModel is String ? rawModel.trim() : null;

    final result = await runner(
      definition,
      rawPrompt.trim(),
      model: requestedModel == null || requestedModel.isEmpty
          ? null
          : requestedModel,
    );
    final metadata = <String, Object?>{
      'agent': definition.name,
      'resolved_name': definition.name,
      'description': definition.description,
      'allowed_tools': definition.allowedTools,
      'disallowed_tools': definition.disallowedTools,
      'model': requestedModel == null || requestedModel.isEmpty
          ? definition.model
          : requestedModel,
      'effort': definition.effort?.name,
      'parent_session_id': result.parentSessionId,
      'subagent_name': result.name,
      'subagent_session_id': result.sessionId,
      'subagent_turns': result.turns,
      'subagent_model': result.model,
      'subagent_messages':
          result.cascadedMessages.map((message) => message.toJson()).toList(),
    };

    if (result.isError) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: result.errorCode ?? 'subagent_failed',
        errorMessage: result.errorMessage ??
            'named agent "${definition.name}" failed: ${result.output}',
        metadata: metadata,
      );
    }

    return ToolExecutionResult(
      tool: name,
      ok: true,
      output: 'Agent "${definition.name}" completed.\n\n'
          'Result:\n${result.output}',
      metadata: metadata,
    );
  }
}
