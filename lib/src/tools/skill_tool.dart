import '../core/app_config.dart';
import '../core/models.dart';
import '../skills/skill_models.dart';
import '../skills/skill_registry.dart';
import '../sdk/sdk_models.dart';
import 'tool_models.dart';

typedef SkillForkRunner = Future<SkillForkExecutionResult> Function(
  ClartCodeSkillDefinition skill,
  String args,
  String promptText,
  ClartCodeSkillContext context, {
  ClartCodeAgentDefinition? agentDefinition,
});

typedef SkillContextBuilder = ClartCodeSkillContext Function();
typedef SkillAgentResolver = ClartCodeAgentDefinition? Function(String name);
typedef SkillAgentDefinitionsBuilder = List<ClartCodeAgentDefinition>
    Function();

class SkillForkExecutionResult {
  const SkillForkExecutionResult({
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

class SkillTool implements Tool {
  SkillTool({
    required this.registry,
    required this.cwd,
    this.sessionId,
    this.provider,
    this.model,
    this.effort,
    this.contextBuilder,
    this.agentResolver,
    this.agentDefinitionsBuilder,
    this.forkRunner,
  });

  final ClartCodeSkillRegistry registry;
  final String cwd;
  final String? sessionId;
  final ProviderKind? provider;
  final String? model;
  final ClartCodeReasoningEffort? effort;
  final SkillContextBuilder? contextBuilder;
  final SkillAgentResolver? agentResolver;
  final SkillAgentDefinitionsBuilder? agentDefinitionsBuilder;
  final SkillForkRunner? forkRunner;

  Map<String, Object?> _lifecycleMetadata(ClartCodeSkillDefinition skill) {
    return {
      'runtime_scope': skill.runtimeScope,
      'cleanup_boundary': skill.cleanupBoundary,
    };
  }

  @override
  String get name => 'skill';

  @override
  String? get title => null;

  @override
  String get description =>
      'Load a reusable skill prompt for the current task. Use when an available skill matches the user request.';

  @override
  Map<String, Object?>? get annotations => null;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'skill': {
            'type': 'string',
            'description':
                'The skill name to invoke, for example "review", "/review", or "debug".',
          },
          'args': {
            'type': 'string',
            'description': 'Optional arguments passed to the skill.',
          },
        },
        'required': ['skill'],
      };

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.serialOnly;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    final rawSkill = invocation.input['skill'];
    final requestedSkill =
        rawSkill is String ? _normalizeString(rawSkill) : null;
    if (requestedSkill == null) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'invalid_input',
        errorMessage: 'skill requires a non-empty "skill" string input',
      );
    }

    final skill = registry.lookup(requestedSkill);
    if (skill == null) {
      final available =
          registry.modelInvocable.map((item) => item.name).toList()..sort();
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'skill_not_found',
        errorMessage: available.isEmpty
            ? 'unknown skill "$requestedSkill"'
            : 'unknown skill "$requestedSkill"; available skills: ${available.join(', ')}',
      );
    }

    if (!skill.enabled) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'skill_disabled',
        errorMessage: 'skill "${skill.name}" is currently disabled',
      );
    }

    if (skill.disableModelInvocation) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'skill_model_invocation_disabled',
        errorMessage:
            'skill "${skill.name}" cannot be invoked by the model because disable-model-invocation is enabled',
      );
    }

    final args = invocation.input['args'];
    if (args != null && args is! String) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'invalid_input',
        errorMessage: 'skill args must be a string when provided',
      );
    }

    final skillContext = contextBuilder?.call() ??
        ClartCodeSkillContext(
          cwd: cwd,
          sessionId: sessionId,
          provider: provider,
          model: model,
          effort: effort,
        );
    final promptBlocks = await skill.getPrompt(
      args as String? ?? '',
      skillContext,
    );
    final promptText = promptBlocks
        .where((block) => block.type == 'text')
        .map((block) => block.text.trim())
        .where((block) => block.isNotEmpty)
        .join('\n\n');
    if (promptText.isEmpty) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'empty_skill_prompt',
        errorMessage: 'skill "${skill.name}" produced no text prompt',
      );
    }

    final status = skill.context == ClartCodeSkillExecutionContext.fork
        ? 'forked'
        : 'inline';
    final requestedAgent = _normalizeString(skill.agent);
    ClartCodeAgentDefinition? agentDefinition;
    if (skill.context == ClartCodeSkillExecutionContext.fork &&
        requestedAgent != null) {
      agentDefinition = agentResolver?.call(requestedAgent);
      if (agentDefinition == null) {
        final available = (agentDefinitionsBuilder?.call() ?? const [])
            .map((item) => item.name)
            .toSet()
            .toList()
          ..sort();
        return ToolExecutionResult.failure(
          tool: name,
          errorCode: 'skill_agent_not_found',
          errorMessage: available.isEmpty
              ? 'skill "${skill.name}" references unknown agent "$requestedAgent"'
              : 'skill "${skill.name}" references unknown agent "$requestedAgent"; available agents: ${available.join(', ')}',
        );
      }
    }
    if (skill.context == ClartCodeSkillExecutionContext.fork &&
        forkRunner != null) {
      final forked = await forkRunner!(
        skill,
        args ?? '',
        promptText,
        skillContext,
        agentDefinition: agentDefinition,
      );
      return ToolExecutionResult(
        tool: name,
        ok: true,
        output: 'Skill "${skill.name}" completed (forked execution).\n\n'
            'Result:\n${forked.output}',
        metadata: {
          'skill': skill.name,
          'resolved_name': skill.name,
          'context': skill.context.name,
          'status': status,
          'argument_hint': skill.argumentHint,
          'allowed_tools': skill.allowedTools,
          'disallowed_tools': skill.disallowedTools,
          'agent': requestedAgent,
          'resolved_agent': agentDefinition?.name,
          'model': skill.model,
          'effort': skill.effort?.name,
          'disable_model_invocation': skill.disableModelInvocation,
          'aliases': skill.aliases,
          ..._lifecycleMetadata(skill),
          'parent_session_id': forked.parentSessionId,
          'subagent_name': forked.name,
          'subagent_session_id': forked.sessionId,
          'subagent_turns': forked.turns,
          'subagent_model': forked.model,
          'subagent_is_error': forked.isError,
          'subagent_error_code': forked.errorCode,
          'subagent_error_message': forked.errorMessage,
          'subagent_messages': forked.cascadedMessages
              .map((message) => message.toJson())
              .toList(),
          ...skill.metadata,
        },
      );
    }

    final buffer = StringBuffer()
      ..writeln('Skill "${skill.name}" loaded.')
      ..writeln('Apply the following instructions to the current task:')
      ..writeln()
      ..write(promptText);

    return ToolExecutionResult(
      tool: name,
      ok: true,
      output: buffer.toString().trimRight(),
      metadata: {
        'skill': skill.name,
        'resolved_name': skill.name,
        'context': skill.context.name,
        'status': status,
        'argument_hint': skill.argumentHint,
        'allowed_tools': skill.allowedTools,
        'disallowed_tools': skill.disallowedTools,
        'agent': requestedAgent,
        'resolved_agent': agentDefinition?.name,
        'model': skill.model,
        'effort': skill.effort?.name,
        'disable_model_invocation': skill.disableModelInvocation,
        'aliases': skill.aliases,
        ..._lifecycleMetadata(skill),
        ...skill.metadata,
      },
    );
  }

  String? _normalizeString(String? value) {
    if (value == null) {
      return null;
    }
    var trimmed = value.trim();
    if (trimmed.startsWith('/')) {
      trimmed = trimmed.substring(1).trimLeft();
    }
    return trimmed.isEmpty ? null : trimmed;
  }
}
