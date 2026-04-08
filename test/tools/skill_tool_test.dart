import 'package:clart_code/clart_code_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('SkillTool', () {
    test('returns skill prompt and metadata', () async {
      final registry = ClartCodeSkillRegistry(
        skills: [
          ClartCodeSkillDefinition(
            name: 'review',
            description: 'Review code.',
            allowedTools: const ['read', 'grep'],
            disallowedTools: const ['write'],
            effort: ClartCodeReasoningEffort.medium,
            getPrompt: (args, context) async => [
              ClartCodeSkillContentBlock.text(
                'Review carefully.${args.trim().isEmpty ? '' : ' Scope: ${args.trim()}'}',
              ),
            ],
          ),
        ],
      );
      final tool = SkillTool(
        registry: registry,
        cwd: '/tmp/project',
      );

      final result = await tool.run(
        ToolInvocation(
          name: 'skill',
          input: const {
            'skill': 'review',
            'args': 'lib/src',
          },
        ),
      );

      expect(result.ok, isTrue);
      expect(result.output, contains('Skill "review" loaded.'));
      expect(result.output, contains('Scope: lib/src'));
      expect(result.metadata?['skill'], 'review');
      expect(result.metadata?['allowed_tools'], ['read', 'grep']);
      expect(result.metadata?['disallowed_tools'], ['write']);
      expect(result.metadata?['effort'], 'medium');
      expect(result.metadata?['runtime_scope'], 'current_query');
      expect(result.metadata?['cleanup_boundary'], 'query_end');
    });

    test('accepts slash-prefixed skill names', () async {
      final tool = SkillTool(
        registry: ClartCodeSkillRegistry(
          skills: [
            ClartCodeSkillDefinition(
              name: 'review',
              description: 'Review code.',
              getPrompt: (args, context) async =>
                  const [ClartCodeSkillContentBlock.text('review prompt')],
            ),
          ],
        ),
        cwd: '/tmp/project',
      );

      final result = await tool.run(
        ToolInvocation(
          name: 'skill',
          input: const {'skill': '/review'},
        ),
      );

      expect(result.ok, isTrue);
      expect(result.metadata?['skill'], 'review');
      expect(result.output, contains('review prompt'));
    });

    test('returns stable failure for unknown skill', () async {
      final tool = SkillTool(
        registry: ClartCodeSkillRegistry(),
        cwd: '/tmp/project',
      );

      final result = await tool.run(
        ToolInvocation(
          name: 'skill',
          input: const {'skill': 'missing'},
        ),
      );

      expect(result.ok, isFalse);
      expect(result.errorCode, 'skill_not_found');
    });

    test('rejects skills with disable-model-invocation enabled', () async {
      final tool = SkillTool(
        registry: ClartCodeSkillRegistry(
          skills: [
            ClartCodeSkillDefinition(
              name: 'review',
              description: 'Review code.',
              disableModelInvocation: true,
              getPrompt: (args, context) async =>
                  const [ClartCodeSkillContentBlock.text('review prompt')],
            ),
          ],
        ),
        cwd: '/tmp/project',
      );

      final result = await tool.run(
        ToolInvocation(
          name: 'skill',
          input: const {'skill': 'review'},
        ),
      );

      expect(result.ok, isFalse);
      expect(result.errorCode, 'skill_model_invocation_disabled');
      expect(result.errorMessage, contains('disable-model-invocation'));
    });

    test('uses dynamic skill context when contextBuilder is provided',
        () async {
      final tool = SkillTool(
        registry: ClartCodeSkillRegistry(
          skills: [
            ClartCodeSkillDefinition(
              name: 'review',
              description: 'Review code.',
              getPrompt: (args, context) async => [
                ClartCodeSkillContentBlock.text(
                  'turn=${context.turn};model=${context.model};effort=${context.effort?.name};cwd=${context.cwd}',
                ),
              ],
            ),
          ],
        ),
        cwd: '/tmp/project',
        model: 'static-model',
        effort: ClartCodeReasoningEffort.low,
        contextBuilder: () => const ClartCodeSkillContext(
          cwd: '/tmp/dynamic',
          model: 'dynamic-model',
          effort: ClartCodeReasoningEffort.high,
          turn: 7,
        ),
      );

      final result = await tool.run(
        ToolInvocation(
          name: 'skill',
          input: const {'skill': 'review'},
        ),
      );

      expect(result.ok, isTrue);
      expect(result.output, contains('turn=7'));
      expect(result.output, contains('model=dynamic-model'));
      expect(result.output, contains('effort=high'));
      expect(result.output, contains('cwd=/tmp/dynamic'));
      expect(result.output, isNot(contains('static-model')));
    });

    test('executes forked skill through fork runner', () async {
      final tool = SkillTool(
        registry: ClartCodeSkillRegistry(
          skills: [
            ClartCodeSkillDefinition(
              name: 'fork_review',
              description: 'Run review in child agent.',
              context: ClartCodeSkillExecutionContext.fork,
              model: 'child-model',
              allowedTools: const ['read'],
              disallowedTools: const ['write'],
              getPrompt: (args, context) async => const [
                ClartCodeSkillContentBlock.text('child prompt'),
              ],
            ),
          ],
        ),
        cwd: '/tmp/project',
        forkRunner: (skill, args, promptText, context,
            {agentDefinition}) async {
          expect(skill.name, 'fork_review');
          expect(promptText, 'child prompt');
          return SkillForkExecutionResult(
            output: 'child result',
            turns: 1,
            isError: false,
            cascadedMessages: [
              ClartCodeSdkMessage.subagent(
                sessionId: 'child-session',
                parentSessionId: 'parent-session',
                subtype: 'start',
                text: 'child prompt',
                model: 'child-model',
                subagentName: 'fork_review',
              ),
              ClartCodeSdkMessage.subagent(
                sessionId: 'child-session',
                parentSessionId: 'parent-session',
                subtype: 'end',
                terminalSubtype: 'success',
                text: 'child result',
                model: 'child-model',
                subagentName: 'fork_review',
                isError: false,
              ),
            ],
            name: 'fork_review',
            model: 'child-model',
            sessionId: 'child-session',
            parentSessionId: 'parent-session',
          );
        },
      );

      final result = await tool.run(
        ToolInvocation(
          name: 'skill',
          input: const {'skill': 'fork_review'},
        ),
      );

      expect(result.ok, isTrue);
      expect(result.output, contains('completed (forked execution)'));
      expect(result.output, contains('child result'));
      expect(result.metadata?['status'], 'forked');
      expect(result.metadata?['parent_session_id'], 'parent-session');
      expect(result.metadata?['subagent_name'], 'fork_review');
      expect(result.metadata?['subagent_session_id'], 'child-session');
      expect(result.metadata?['subagent_model'], 'child-model');
      expect(result.metadata?['disallowed_tools'], ['write']);
      expect(result.metadata?['runtime_scope'], 'forked_subagent');
      expect(result.metadata?['cleanup_boundary'], 'subagent_end');
      final subagentMessages = result.metadata?['subagent_messages'] as List?;
      expect(subagentMessages, hasLength(2));
      expect((subagentMessages!.first as Map)['type'], 'subagent');
      expect((subagentMessages.first as Map)['subtype'], 'start');
      expect((subagentMessages.last as Map)['type'], 'subagent');
      expect((subagentMessages.last as Map)['subtype'], 'end');
      expect((subagentMessages.last as Map)['terminalSubtype'], 'success');
    });

    test('resolves forked skill agent through named agent definitions',
        () async {
      final tool = SkillTool(
        registry: ClartCodeSkillRegistry(
          skills: [
            ClartCodeSkillDefinition(
              name: 'fork_review',
              description: 'Run review in child agent.',
              context: ClartCodeSkillExecutionContext.fork,
              agent: 'code-reviewer',
              getPrompt: (args, context) async => const [
                ClartCodeSkillContentBlock.text('child prompt'),
              ],
            ),
          ],
        ),
        cwd: '/tmp/project',
        agentResolver: (name) => name == 'code-reviewer'
            ? const ClartCodeAgentDefinition(
                name: 'code-reviewer',
                description: 'Review code.',
                prompt: 'Review carefully.',
                allowedTools: ['read'],
                model: 'review-model',
              )
            : null,
        agentDefinitionsBuilder: () => const [
          ClartCodeAgentDefinition(
            name: 'code-reviewer',
            description: 'Review code.',
            prompt: 'Review carefully.',
          ),
        ],
        forkRunner: (skill, args, promptText, context,
            {agentDefinition}) async {
          expect(agentDefinition?.name, 'code-reviewer');
          expect(agentDefinition?.model, 'review-model');
          return SkillForkExecutionResult(
            output: 'child result',
            turns: 1,
            isError: false,
            name: 'fork_review',
            model: 'review-model',
          );
        },
      );

      final result = await tool.run(
        ToolInvocation(
          name: 'skill',
          input: const {'skill': 'fork_review'},
        ),
      );

      expect(result.ok, isTrue);
      expect(result.metadata?['agent'], 'code-reviewer');
      expect(result.metadata?['resolved_agent'], 'code-reviewer');
    });

    test('returns stable failure for forked skill with unknown named agent',
        () async {
      final tool = SkillTool(
        registry: ClartCodeSkillRegistry(
          skills: [
            ClartCodeSkillDefinition(
              name: 'fork_review',
              description: 'Run review in child agent.',
              context: ClartCodeSkillExecutionContext.fork,
              agent: 'missing-reviewer',
              getPrompt: (args, context) async => const [
                ClartCodeSkillContentBlock.text('child prompt'),
              ],
            ),
          ],
        ),
        cwd: '/tmp/project',
        agentDefinitionsBuilder: () => const [
          ClartCodeAgentDefinition(
            name: 'code-reviewer',
            description: 'Review code.',
            prompt: 'Review carefully.',
          ),
        ],
      );

      final result = await tool.run(
        ToolInvocation(
          name: 'skill',
          input: const {'skill': 'fork_review'},
        ),
      );

      expect(result.ok, isFalse);
      expect(result.errorCode, 'skill_agent_not_found');
      expect(result.errorMessage, contains('missing-reviewer'));
      expect(result.errorMessage, contains('code-reviewer'));
    });

    test('forked child error stays a successful skill tool result', () async {
      final tool = SkillTool(
        registry: ClartCodeSkillRegistry(
          skills: [
            ClartCodeSkillDefinition(
              name: 'fork_review',
              description: 'Run review in child agent.',
              context: ClartCodeSkillExecutionContext.fork,
              model: 'child-model',
              getPrompt: (args, context) async => const [
                ClartCodeSkillContentBlock.text('child prompt'),
              ],
            ),
          ],
        ),
        cwd: '/tmp/project',
        forkRunner: (skill, args, promptText, context,
            {agentDefinition}) async {
          return SkillForkExecutionResult(
            output: 'child terminal error text',
            turns: 2,
            isError: true,
            name: 'fork_review',
            model: 'child-model',
            sessionId: 'child-session',
            parentSessionId: 'parent-session',
            errorCode: 'providerFailure',
            errorMessage: 'child provider exploded',
          );
        },
      );

      final result = await tool.run(
        ToolInvocation(
          name: 'skill',
          input: const {'skill': 'fork_review'},
        ),
      );

      expect(result.ok, isTrue);
      expect(result.errorCode, isNull);
      expect(result.errorMessage, isNull);
      expect(result.output, contains('completed (forked execution)'));
      expect(result.output, contains('child terminal error text'));
      expect(result.metadata?['status'], 'forked');
      expect(result.metadata?['subagent_is_error'], isTrue);
      expect(result.metadata?['subagent_error_code'], 'providerFailure');
      expect(
        result.metadata?['subagent_error_message'],
        'child provider exploded',
      );
    });
  });
}
