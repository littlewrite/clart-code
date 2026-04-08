import 'package:clart_code/clart_code_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('AgentTool', () {
    test('returns stable failure for unknown named agent', () async {
      final tool = AgentTool(
        agents: const [],
        runner: (definition, prompt, {model}) async {
          throw UnimplementedError();
        },
      );

      final result = await tool.run(
        ToolInvocation(
          name: 'agent',
          input: const {
            'agent': 'missing',
            'prompt': 'inspect this file',
          },
        ),
      );

      expect(result.ok, isFalse);
      expect(result.errorCode, 'agent_not_found');
    });

    test('executes named agent through runner and returns metadata', () async {
      final tool = AgentTool(
        agents: const [
          ClartCodeAgentDefinition(
            name: 'code-reviewer',
            description: 'Focused code reviewer.',
            prompt: 'Review the requested target carefully.',
            allowedTools: ['read', 'grep'],
            model: 'review-model',
            effort: ClartCodeReasoningEffort.high,
          ),
        ],
        runner: (definition, prompt, {model}) async {
          expect(definition.name, 'code-reviewer');
          expect(prompt, 'inspect lib/src');
          expect(model, 'override-model');
          return AgentExecutionResult(
            output: 'review result',
            turns: 2,
            isError: false,
            cascadedMessages: [
              ClartCodeSdkMessage.subagent(
                sessionId: 'child-agent-session',
                parentSessionId: 'parent-session',
                subtype: 'start',
                text: 'inspect lib/src',
                model: 'override-model',
                subagentName: 'code-reviewer',
              ),
              ClartCodeSdkMessage.subagent(
                sessionId: 'child-agent-session',
                parentSessionId: 'parent-session',
                subtype: 'end',
                terminalSubtype: 'success',
                text: 'review result',
                model: 'override-model',
                subagentName: 'code-reviewer',
                isError: false,
              ),
            ],
            name: 'code-reviewer',
            model: 'override-model',
            sessionId: 'child-agent-session',
            parentSessionId: 'parent-session',
          );
        },
      );

      final result = await tool.run(
        ToolInvocation(
          name: 'agent',
          input: const {
            'agent': 'code-reviewer',
            'prompt': 'inspect lib/src',
            'model': 'override-model',
          },
        ),
      );

      expect(result.ok, isTrue);
      expect(result.output, contains('Agent "code-reviewer" completed.'));
      expect(result.output, contains('review result'));
      expect(result.metadata?['agent'], 'code-reviewer');
      expect(result.metadata?['allowed_tools'], ['read', 'grep']);
      expect(result.metadata?['effort'], 'high');
      expect(result.metadata?['parent_session_id'], 'parent-session');
      expect(result.metadata?['subagent_name'], 'code-reviewer');
      expect(result.metadata?['subagent_session_id'], 'child-agent-session');
      expect(result.metadata?['subagent_model'], 'override-model');
      final subagentMessages = result.metadata?['subagent_messages'] as List?;
      expect(subagentMessages, hasLength(2));
      expect((subagentMessages!.first as Map)['type'], 'subagent');
      expect((subagentMessages.first as Map)['subtype'], 'start');
      expect((subagentMessages.last as Map)['type'], 'subagent');
      expect((subagentMessages.last as Map)['subtype'], 'end');
      expect((subagentMessages.last as Map)['terminalSubtype'], 'success');
    });
  });
}
