// HTTP retry logic with exponential backoff.
//
// Provides intelligent retry mechanisms for transient HTTP failures.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../core/runtime_error.dart';

/// Configuration for HTTP retry behavior.
class RetryConfig {
  const RetryConfig({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 10),
    this.timeout = const Duration(seconds: 30),
  });

  final int maxAttempts;
  final Duration initialDelay;
  final Duration maxDelay;
  final Duration timeout;

  /// Default configuration for streaming requests (longer timeout, fewer retries).
  static const streaming = RetryConfig(
    maxAttempts: 2,
    timeout: Duration(seconds: 60),
  );

  /// Default configuration for non-streaming requests.
  static const standard = RetryConfig();
}

/// Determines if an error is retriable.
bool isRetriableError(Object error, {int? statusCode}) {
  // Network errors are retriable
  if (error is SocketException || error is HandshakeException) {
    return true;
  }

  // Timeout errors are retriable
  if (error is TimeoutException) {
    return true;
  }

  if (statusCode != null) {
    // Rate limit (429) and server errors (5xx) are retriable
    if (statusCode == 429 || statusCode >= 500) {
      return true;
    }

    // Client errors (4xx except 429) are not retriable
    if (statusCode >= 400 && statusCode < 500) {
      return false;
    }
  }

  // Default: assume retriable for unknown errors
  return true;
}

/// Executes an HTTP operation with retry logic.
///
/// Automatically retries on transient failures with exponential backoff.
/// Returns the result of the first successful attempt.
Future<T> withRetry<T>({
  required Future<T> Function() operation,
  RetryConfig config = RetryConfig.standard,
  bool Function(Object error, int? statusCode)? shouldRetry,
}) async {
  var attempt = 0;
  var delay = config.initialDelay;

  while (true) {
    attempt++;

    try {
      return await operation().timeout(config.timeout);
    } catch (error) {
      final retriable = shouldRetry != null
          ? shouldRetry(error, null)
          : isRetriableError(error);

      // Don't retry if not retriable or max attempts reached
      if (!retriable || attempt >= config.maxAttempts) {
        rethrow;
      }

      // Wait before retrying (exponential backoff with jitter)
      final jitter = Random().nextDouble() * 0.3; // 0-30% jitter
      final actualDelay = delay * (1 + jitter);
      await Future.delayed(actualDelay);

      // Increase delay for next attempt (exponential backoff)
      delay = Duration(
        milliseconds: min(
          delay.inMilliseconds * 2,
          config.maxDelay.inMilliseconds,
        ),
      );
    }
  }
}

/// Wraps a RuntimeError with retry context.
RuntimeError withRetryContext(
  RuntimeError error, {
  required int attempt,
  required int maxAttempts,
}) {
  final retryInfo = attempt < maxAttempts
      ? ' (attempt $attempt/$maxAttempts, will retry)'
      : ' (attempt $attempt/$maxAttempts, no more retries)';

  return RuntimeError(
    code: error.code,
    message: '${error.message}$retryInfo',
    source: error.source,
    retriable: error.retriable && attempt < maxAttempts,
  );
}
