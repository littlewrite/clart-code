import 'dart:async';

import '../core/app_config.dart';
import '../core/models.dart';

typedef ClartCodeSkillPromptBuilder = FutureOr<List<ClartCodeSkillContentBlock>>
    Function(
  String args,
  ClartCodeSkillContext context,
);

typedef ClartCodeSkillEnabledPredicate = bool Function();

enum ClartCodeSkillExecutionContext { inline, fork }

class ClartCodeSkillContext {
  const ClartCodeSkillContext({
    required this.cwd,
    this.sessionId,
    this.provider,
    this.model,
    this.effort,
    this.turn,
  });

  final String cwd;
  final String? sessionId;
  final ProviderKind? provider;
  final String? model;
  final ClartCodeReasoningEffort? effort;
  final int? turn;
}

class ClartCodeSkillContentBlock {
  const ClartCodeSkillContentBlock({
    required this.type,
    required this.text,
  });

  const ClartCodeSkillContentBlock.text(String text)
      : this(type: 'text', text: text);

  final String type;
  final String text;

  Map<String, Object?> toJson() {
    return {
      'type': type,
      'text': text,
    };
  }
}

class ClartCodeSkillDefinition {
  const ClartCodeSkillDefinition({
    required this.name,
    required this.description,
    required this.getPrompt,
    this.aliases = const [],
    this.whenToUse,
    this.argumentHint,
    this.allowedTools = const [],
    this.disallowedTools = const [],
    this.agent,
    this.model,
    this.effort,
    this.disableModelInvocation = false,
    this.userInvocable = true,
    this.context = ClartCodeSkillExecutionContext.inline,
    this.cascadeAssistantDeltas = false,
    this.isEnabled,
    this.metadata = const {},
  });

  final String name;
  final String description;
  final List<String> aliases;
  final String? whenToUse;
  final String? argumentHint;
  final List<String> allowedTools;
  final List<String> disallowedTools;
  final String? agent;
  final String? model;
  final ClartCodeReasoningEffort? effort;
  final bool disableModelInvocation;
  final bool userInvocable;
  final ClartCodeSkillExecutionContext context;
  final bool cascadeAssistantDeltas;
  final ClartCodeSkillEnabledPredicate? isEnabled;
  final ClartCodeSkillPromptBuilder getPrompt;
  final Map<String, Object?> metadata;

  bool get enabled => isEnabled?.call() ?? true;

  String get runtimeScope => switch (context) {
        ClartCodeSkillExecutionContext.inline => 'current_query',
        ClartCodeSkillExecutionContext.fork => 'forked_subagent',
      };

  String get cleanupBoundary => switch (context) {
        ClartCodeSkillExecutionContext.inline => 'query_end',
        ClartCodeSkillExecutionContext.fork => 'subagent_end',
      };

  Map<String, Object?> toSummaryJson() {
    return {
      'name': name,
      'description': description,
      'aliases': aliases,
      'whenToUse': whenToUse,
      'argumentHint': argumentHint,
      'allowedTools': allowedTools,
      'disallowedTools': disallowedTools,
      'agent': agent,
      'model': model,
      'effort': effort?.name,
      'disableModelInvocation': disableModelInvocation,
      'userInvocable': userInvocable,
      'context': context.name,
      'runtimeScope': runtimeScope,
      'cleanupBoundary': cleanupBoundary,
      'cascadeAssistantDeltas': cascadeAssistantDeltas,
      'enabled': enabled,
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }
}
