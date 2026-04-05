import 'package:test/test.dart';
import 'package:clart_code/src/providers/http_retry.dart';
import 'dart:async';
import 'dart:io';

void main() {
  group('isRetriableError', () {
    test('returns true for SocketException', () {
      expect(isRetriableError(SocketException('test')), true);
    });

    test('returns true for HandshakeException', () {
      expect(isRetriableError(HandshakeException('test')), true);
    });

    test('returns true for TimeoutException', () {
      expect(isRetriableError(TimeoutException('test')), true);
    });

    test('returns true for 429 status code', () {
      expect(isRetriableError(Exception('test'), statusCode: 429), true);
    });

    test('returns true for 5xx status codes', () {
      expect(isRetriableError(Exception('test'), statusCode: 500), true);
      expect(isRetriableError(Exception('test'), statusCode: 502), true);
      expect(isRetriableError(Exception('test'), statusCode: 503), true);
    });

    test('returns false for 4xx status codes (except 429)', () {
      expect(isRetriableError(Exception('test'), statusCode: 400), false);
      expect(isRetriableError(Exception('test'), statusCode: 401), false);
      expect(isRetriableError(Exception('test'), statusCode: 403), false);
      expect(isRetriableError(Exception('test'), statusCode: 404), false);
    });

    test('returns true for unknown errors', () {
      expect(isRetriableError(Exception('unknown')), true);
    });
  });

  group('withRetry', () {
    test('returns result on first success', () async {
      var attempts = 0;
      final result = await withRetry(
        operation: () async {
          attempts++;
          return 'success';
        },
        config: RetryConfig(maxAttempts: 3),
      );

      expect(result, 'success');
      expect(attempts, 1);
    });

    test('retries on retriable error', () async {
      var attempts = 0;
      final result = await withRetry(
        operation: () async {
          attempts++;
          if (attempts < 3) {
            throw SocketException('test');
          }
          return 'success';
        },
        config: RetryConfig(
          maxAttempts: 3,
          initialDelay: Duration(milliseconds: 10),
        ),
      );

      expect(result, 'success');
      expect(attempts, 3);
    });

    test('throws after max attempts', () async {
      var attempts = 0;
      expect(
        () => withRetry(
          operation: () async {
            attempts++;
            throw SocketException('test');
          },
          config: RetryConfig(
            maxAttempts: 2,
            initialDelay: Duration(milliseconds: 10),
          ),
        ),
        throwsA(isA<SocketException>()),
      );

      await Future.delayed(Duration(milliseconds: 100));
      expect(attempts, 2);
    });

    test('does not retry non-retriable errors', () async {
      var attempts = 0;
      expect(
        () => withRetry(
          operation: () async {
            attempts++;
            throw Exception('non-retriable');
          },
          config: RetryConfig(maxAttempts: 3),
          shouldRetry: (error, statusCode) => false,
        ),
        throwsA(isA<Exception>()),
      );

      expect(attempts, 1);
    });

    test('respects timeout', () async {
      expect(
        () => withRetry(
          operation: () async {
            await Future.delayed(Duration(seconds: 2));
            return 'success';
          },
          config: RetryConfig(
            maxAttempts: 1,
            timeout: Duration(milliseconds: 100),
          ),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
