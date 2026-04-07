class TelemetryService {
  const TelemetryService();

  void logEvent(String name, [Map<String, Object?> payload = const {}]) {
    // Intentionally no-op.
  }

  void logError(Object error, [StackTrace? stackTrace]) {
    // Intentionally no-op.
  }
}
