import 'runtime_error.dart';

enum QueryEventType { turnStart, providerDelta, assistant, error, done }

class QueryEvent {
  const QueryEvent({
    required this.type,
    this.turn,
    this.delta,
    this.output,
    this.model,
    this.error,
    this.turns,
    this.status,
  });

  final QueryEventType type;
  final int? turn;
  final String? delta;
  final String? output;
  final String? model;
  final RuntimeError? error;
  final int? turns;
  final String? status;

  Map<String, Object?> toJson() {
    return {
      'type': type.name,
      'turn': turn,
      'delta': delta,
      'output': output,
      'model': model,
      'error': error?.toJson(),
      'turns': turns,
      'status': status,
    };
  }
}
