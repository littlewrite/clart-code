import 'package:clart_code/clart_code_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('tool helper DSL', () {
    test('tool() builds a callback-backed Tool with metadata', () async {
      final built = tool(
        name: 'echo_text',
        title: 'Echo Text',
        description: 'Echoes text input.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'text': {'type': 'string'},
          },
          'required': ['text'],
        },
        annotations: const {
          'category': 'test',
        },
        executionHint: ToolExecutionHint.parallelSafe,
        run: (invocation) => ToolExecutionResult.success(
          tool: 'echo_text',
          output: invocation.input['text'] as String? ?? '',
        ),
      );

      final result = await built.run(
        ToolInvocation(
          name: 'echo_text',
          input: const {'text': 'hello'},
        ),
      );

      expect(built.name, 'echo_text');
      expect(built.title, 'Echo Text');
      expect(built.description, 'Echoes text input.');
      expect(built.inputSchema?['type'], 'object');
      expect(built.annotations?['category'], 'test');
      expect(built.executionHint, ToolExecutionHint.parallelSafe);
      expect(result.ok, isTrue);
      expect(result.output, 'hello');
    });

    test('defineTool() is an alias for tool()', () async {
      final built = defineTool(
        name: 'always_fail',
        description: 'Returns a stable failure.',
        run: (_) => ToolExecutionResult.failure(
          tool: 'always_fail',
          errorCode: 'expected_failure',
          errorMessage: 'failed on purpose',
        ),
      );

      final result = await built.run(
        ToolInvocation(name: 'always_fail'),
      );

      expect(result.ok, isFalse);
      expect(result.errorCode, 'expected_failure');
      expect(result.errorMessage, 'failed on purpose');
    });

    test('tool() rejects empty names', () {
      expect(
        () => tool(
          name: '   ',
          run: (_) => ToolExecutionResult.success(
            tool: 'noop',
            output: 'ok',
          ),
        ),
        throwsArgumentError,
      );
    });
  });
}
