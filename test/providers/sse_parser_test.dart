import 'package:test/test.dart';
import 'package:clart_code/src/providers/sse_parser.dart';
import 'dart:convert';

void main() {
  group('SseParser', () {
    test('parses single event with data', () async {
      final stream = Stream.value(utf8.encode('data: hello\n\n'));
      final events = await SseParser.parse(stream).toList();

      expect(events, hasLength(1));
      expect(events[0].event, isNull);
      expect(events[0].data, 'hello');
    });

    test('parses event with type', () async {
      final stream = Stream.value(utf8.encode('event: message\ndata: hello\n\n'));
      final events = await SseParser.parse(stream).toList();

      expect(events, hasLength(1));
      expect(events[0].event, 'message');
      expect(events[0].data, 'hello');
    });

    test('parses multi-line data', () async {
      final stream = Stream.value(
        utf8.encode('data: line1\ndata: line2\ndata: line3\n\n'),
      );
      final events = await SseParser.parse(stream).toList();

      expect(events, hasLength(1));
      expect(events[0].data, 'line1\nline2\nline3');
    });

    test('parses multiple events', () async {
      final stream = Stream.value(
        utf8.encode('data: first\n\ndata: second\n\n'),
      );
      final events = await SseParser.parse(stream).toList();

      expect(events, hasLength(2));
      expect(events[0].data, 'first');
      expect(events[1].data, 'second');
    });

    test('handles event without trailing newline', () async {
      final stream = Stream.value(utf8.encode('data: last'));
      final events = await SseParser.parse(stream).toList();

      expect(events, hasLength(1));
      expect(events[0].data, 'last');
    });

    test('ignores empty lines between fields', () async {
      final stream = Stream.value(
        utf8.encode('event: test\n\ndata: value\n\n'),
      );
      final events = await SseParser.parse(stream).toList();

      expect(events, hasLength(2));
      expect(events[0].event, 'test');
      expect(events[0].data, '');
      expect(events[1].data, 'value');
    });

    test('handles mixed event types', () async {
      final stream = Stream.value(
        utf8.encode('event: ping\ndata: 1\n\ndata: 2\n\nevent: pong\ndata: 3\n\n'),
      );
      final events = await SseParser.parse(stream).toList();

      expect(events, hasLength(3));
      expect(events[0].event, 'ping');
      expect(events[0].data, '1');
      expect(events[1].event, isNull);
      expect(events[1].data, '2');
      expect(events[2].event, 'pong');
      expect(events[2].data, '3');
    });
  });
}
