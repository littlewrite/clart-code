import 'package:clart_code/src/core/input_processor.dart';
import 'package:clart_code/src/core/models.dart';
import 'package:test/test.dart';

void main() {
  group('InputProcessor', () {
    late InputProcessor processor;

    setUp(() {
      processor = const InputProcessor();
    });

    test('parse() returns empty for empty input', () {
      final result = processor.parse('');

      expect(result.kind, ParsedInputKind.empty);
    });

    test('parse() returns exit for exit command', () {
      final result = processor.parse('/exit');

      expect(result.kind, ParsedInputKind.exit);
    });

    test('parse() returns exit for quit command', () {
      final result = processor.parse('quit');

      expect(result.kind, ParsedInputKind.exit);
    });

    test('parse() returns slashCommand for /command', () {
      final result = processor.parse('/help arg1 arg2');

      expect(result.kind, ParsedInputKind.slashCommand);
      expect(result.commandName, 'help');
      expect(result.commandArgs, ['arg1', 'arg2']);
    });

    test('parse() returns query for plain text', () {
      final result = processor.parse('hello world');

      expect(result.kind, ParsedInputKind.query);
      expect(result.isQuery, true);
      expect(result.request, isNotNull);
    });

    test('buildQueryRequest() creates request with user message', () {
      final request = processor.buildQueryRequest('test prompt');

      expect(request.messages, isNotEmpty);
      expect(request.messages.last.role, MessageRole.user);
      expect(request.messages.last.text, 'test prompt');
    });

    test('buildQueryRequest() includes preceding messages', () {
      final preceding = [
        ChatMessage(role: MessageRole.user, text: 'first'),
        ChatMessage(role: MessageRole.assistant, text: 'response'),
      ];

      final request = processor.buildQueryRequest(
        'second',
        precedingMessages: preceding,
      );

      expect(request.messages.length, 3);
      expect(request.messages.first.text, 'first');
      expect(request.messages.last.text, 'second');
    });
  });
}
