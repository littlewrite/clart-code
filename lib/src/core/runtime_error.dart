enum RuntimeErrorCode {
  securityRejected,
  providerFailure,
  invalidInput,
  permissionDenied,
  toolNotFound,
  toolRuntimeError,
  notImplemented,
  cancelled,
  unknown,
}

class RuntimeError {
  const RuntimeError({
    required this.code,
    required this.message,
    this.source,
    this.retriable = false,
  });

  final RuntimeErrorCode code;
  final String message;
  final String? source;
  final bool retriable;

  Map<String, Object?> toJson() {
    return {
      'code': code.name,
      'message': message,
      'source': source,
      'retriable': retriable,
    };
  }
}
