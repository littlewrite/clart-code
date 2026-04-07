// Server-Sent Events (SSE) parser for streaming HTTP responses.
//
// Provides utilities for parsing SSE streams according to the SSE specification.
import 'dart:async';
import 'dart:convert';

/// Represents a parsed SSE event.
class SseEvent {
  const SseEvent({
    this.event,
    required this.data,
  });

  /// Event type (from "event:" field), null if not specified.
  final String? event;

  /// Event data (from "data:" fields), joined with newlines.
  final String data;

  bool get isEmpty => data.isEmpty;
}

/// Parses an SSE stream into discrete events.
///
/// Handles the SSE protocol: event/data fields, empty line delimiters,
/// and multi-line data accumulation.
class SseParser {
  /// Transforms an HTTP response stream into SSE events.
  ///
  /// Yields [SseEvent] objects as they are parsed from the stream.
  /// Handles UTF-8 decoding and line splitting automatically.
  static Stream<SseEvent> parse(Stream<List<int>> byteStream) async* {
    String? currentEvent;
    final dataLines = <String>[];

    await for (final line in utf8.decoder
        .bind(byteStream)
        .transform(const LineSplitter())) {
      final trimmed = line.trimRight();

      // Empty line signals end of event
      if (trimmed.isEmpty) {
        if (dataLines.isNotEmpty || currentEvent != null) {
          yield SseEvent(
            event: currentEvent,
            data: dataLines.join('\n'),
          );
          dataLines.clear();
          currentEvent = null;
        }
        continue;
      }

      // Parse event type
      if (trimmed.startsWith('event:')) {
        currentEvent = trimmed.substring(6).trim();
        continue;
      }

      // Parse data line
      if (trimmed.startsWith('data:')) {
        dataLines.add(trimmed.substring(5).trim());
      }
    }

    // Emit final event if stream ends without empty line
    if (dataLines.isNotEmpty) {
      yield SseEvent(
        event: currentEvent,
        data: dataLines.join('\n'),
      );
    }
  }
}
