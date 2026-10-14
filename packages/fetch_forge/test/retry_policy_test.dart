import 'package:fetch_forge/fetch_forge.dart';
import 'package:test/test.dart';

void main() {
  group('RetryPolicy', () {
    test('does not retry by default', () async {
      var calls = 0;

      await expectLater(
        RetryPolicy().run(() async {
          calls++;

          return 1;
        }),
        completion(1),
      );
      expect(calls, 1);
    });

    test('never retries a first-attempt failure by default', () async {
      var calls = 0;

      await expectLater(
        RetryPolicy().run(() async {
          calls++;
          throw FirstError();
        }),
        throwsA(isA<FirstError>()),
      );
      expect(calls, 1);
    });

    test('stops after maxAttempts, which counts the first try', () async {
      var calls = 0;

      await expectLater(
        RetryPolicy(maxAttempts: 3, sleep: _instant).run(() async {
          calls++;
          throw calls == 3 ? SecondError() : FirstError();
        }),
        throwsA(isA<SecondError>()),
      );
      expect(calls, 3);
    });

    test('gives up as soon as an attempt succeeds', () async {
      var calls = 0;

      await expectLater(
        RetryPolicy(maxAttempts: 3, sleep: _instant).run(() async {
          calls++;
          if (calls < 3) throw FirstError();

          return 'ok';
        }),
        completion('ok'),
      );
      expect(calls, 3);
    });

    test('retryIf short-circuits non-retryable errors', () async {
      var calls = 0;

      await expectLater(
        RetryPolicy(
          maxAttempts: 3,
          retryIf: (error) => error is FirstError,
          sleep: _instant,
        ).run(() async {
          calls++;
          throw SecondError();
        }),
        throwsA(isA<SecondError>()),
      );
      expect(calls, 1);
    });

    test('retryIf only sees the caught error', () async {
      final seen = <Object>[];

      await expectLater(
        RetryPolicy(
          maxAttempts: 2,
          retryIf: (error) {
            seen.add(error);

            return true;
          },
          sleep: _instant,
        ).run(() async => throw FirstError('payload')),
        throwsA(isA<FirstError>()),
      );
      expect(seen, [FirstError('payload')]);
    });

    test(
      'delay is called with the 1-indexed attempt that just failed',
      () async {
        final attempts = <int>[];
        final errors = <Object>[];

        await expectLater(
          RetryPolicy(
            maxAttempts: 3,
            delay: (attempt, error) {
              attempts.add(attempt);
              errors.add(error);

              return Duration.zero;
            },
            sleep: _instant,
          ).run(() async => throw FirstError('boom')),
          throwsA(isA<FirstError>()),
        );
        expect(attempts, [1, 2]);
        expect(errors, [FirstError('boom'), FirstError('boom')]);
      },
    );

    test('the backoff is waited out before the next attempt', () async {
      final log = <String>[];

      await expectLater(
        RetryPolicy(
          maxAttempts: 2,
          sleep: (duration) async => log.add('waited $duration'),
        ).run(() async {
          log.add('attempt');

          throw FirstError();
        }),
        throwsA(isA<FirstError>()),
      );
      expect(log, ['attempt', 'waited 0:00:00.250000', 'attempt']);
    });

    test('the default backoff doubles', () async {
      final delays = <Duration>[];

      await expectLater(
        _recording(
          RetryPolicy(maxAttempts: 4),
          delays,
        ).run(() async => throw FirstError()),
        throwsA(isA<FirstError>()),
      );
      expect(delays, [
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 500),
        const Duration(seconds: 1),
      ]);
    });

    test('the default backoff is capped at 30s', () {
      expect(
        RetryPolicy().delay(12, FirstError()),
        const Duration(seconds: 30),
      );
    });

    test('exponentialBackoff grows from initialDelay by factor', () async {
      final policy = RetryPolicy.exponentialBackoff(
        maxAttempts: 4,
        initialDelay: const Duration(milliseconds: 10),
        factor: 3,
      );
      final delays = <Duration>[];

      await expectLater(
        _recording(policy, delays).run(() async => throw FirstError()),
        throwsA(isA<FirstError>()),
      );
      expect(delays, [
        const Duration(milliseconds: 10),
        const Duration(milliseconds: 30),
        const Duration(milliseconds: 90),
      ]);
    });

    test('exponentialBackoff honours maxDelay', () async {
      final policy = RetryPolicy.exponentialBackoff(
        maxAttempts: 3,
        initialDelay: const Duration(milliseconds: 10),
        maxDelay: const Duration(milliseconds: 20),
      );
      final delays = <Duration>[];

      await expectLater(
        _recording(policy, delays).run(() async => throw FirstError()),
        throwsA(isA<FirstError>()),
      );
      expect(delays, [
        const Duration(milliseconds: 10),
        const Duration(milliseconds: 20),
      ]);
    });

    test('none never waits and never retries', () async {
      var calls = 0;

      await expectLater(
        RetryPolicy.none.run(() async {
          calls++;
          throw FirstError();
        }),
        throwsA(isA<FirstError>()),
      );
      expect(calls, 1);
    });

    test('maxAttempts must be positive', () {
      expect(() => RetryPolicy(maxAttempts: 0), throwsA(isA<AssertionError>()));
      expect(
        () => RetryPolicy.exponentialBackoff(maxAttempts: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('initialDelay must be positive', () {
      expect(
        () => RetryPolicy.exponentialBackoff(initialDelay: Duration.zero),
        throwsA(isA<AssertionError>()),
      );
    });

    test('policies are const and shareable', () {
      const policy = RetryPolicy(maxAttempts: 5);

      expect(policy.maxAttempts, 5);
      expect(policy.retryIf, isNull);
      expect(RetryPolicy.none.maxAttempts, 1);
    });
  });
}

/// Runs [policy] with the waits this policy asks for captured instead of slept.
RetryPolicy _recording(RetryPolicy policy, List<Duration> delays) =>
    RetryPolicy(
      maxAttempts: policy.maxAttempts,
      delay: (attempt, error) {
        final duration = policy.delay(attempt, error);
        delays.add(duration);

        return duration;
      },
      retryIf: policy.retryIf,
      sleep: _instant,
    );

Future<void> _instant(Duration duration) async {}

final class FirstError extends Error {
  FirstError([this.message = 'first']);

  final String message;

  @override
  bool operator ==(Object other) =>
      other is FirstError && other.message == message;

  @override
  int get hashCode => message.hashCode;

  @override
  String toString() => 'FirstError: $message';
}

final class SecondError extends Error {
  SecondError();

  @override
  String toString() => 'SecondError';
}
