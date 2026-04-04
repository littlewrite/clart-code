import 'dart:async';

import 'package:clart_code/src/core/models.dart';
import 'package:clart_code/src/core/query_engine.dart';
import 'package:clart_code/src/core/query_events.dart';
import 'package:clart_code/src/core/turn_executor.dart';
import 'package:clart_code/src/providers/llm_provider.dart';
import 'package:clart_code/src/runtime/app_runtime.dart';
import 'package:test/test.dart';

void main() {
  group('TurnExecutor', () {
    late TurnExecutor executor;
    late QueryEngine engine;

    setUp(() {
      final runtime = AppRuntime(
        provider: LocalEchoProvider(),
      );
      engine = QueryEngine(runtime);
      executor = TurnExecutor(engine);
    });

    test('execute() returns success result for valid request', () async {
      final request = QueryRequest(
        messages: [
          ChatMessage(role: MessageRole.user, text: 'hello'),
        ],
      );

      final result = await executor.execute(
        request: request,
        turn: 1,
      );

      expect(result.success, true);
      expect(result.output, isNotEmpty);
      expect(result.modelUsed, 'local-echo');
    });

    test('execute() emits turnStart event', () async {
      final events = <QueryEvent>[];
      final request = QueryRequest(
        messages: [
          ChatMessage(role: MessageRole.user, text: 'test'),
        ],
      );

      await executor.execute(
        request: request,
        turn: 1,
        onEvent: (event) => events.add(event),
      );

      expect(
        events.any((e) => e.type == QueryEventType.turnStart),
        true,
      );
    });

    test('execute() emits assistant event on success', () async {
      final events = <QueryEvent>[];
      final request = QueryRequest(
        messages: [
          ChatMessage(role: MessageRole.user, text: 'test'),
        ],
      );

      await executor.execute(
        request: request,
        turn: 1,
        onEvent: (event) => events.add(event),
      );

      expect(
        events.any((e) => e.type == QueryEventType.assistant),
        true,
      );
    });

    test('execute() handles interruption', () async {
      final controller = StreamController<void>();
      final request = QueryRequest(
        messages: [
          ChatMessage(role: MessageRole.user, text: 'test'),
        ],
      );

      // Schedule interrupt after a short delay
      Future.delayed(Duration(milliseconds: 10), () {
        controller.add(null);
      });

      final result = await executor.execute(
        request: request,
        turn: 1,
        interruptSignals: controller.stream,
      );

      expect(result.interrupted, true);
      await controller.close();
    });
  });
}
