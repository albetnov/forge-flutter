import 'dart:math' as math;

/// Computes how long to wait before retry attempt [attempt].
///
/// [attempt] is 1-indexed and counts the failure that just happened: the delay
/// passed as `1` is the wait before the second overall attempt.
typedef RetryDelay = Duration Function(int attempt, Object error);

/// Decides whether [error] is worth retrying.
typedef RetryPredicate = bool Function(Object error);

/// Waits for [duration] before the next attempt.
///
/// Injectable so tests can run retries against a virtual clock; production code
/// leaves it at its default, `Future.delayed`.
typedef RetrySleep = Future<void> Function(Duration duration);

/// Describes how a failed asynchronous operation is retried.
///
/// A policy is inert data: it only waits and retries when [run] is called, so
/// the same instance can be shared by any number of operations.
///
/// ```dart
/// final policy = RetryPolicy.exponentialBackoff(maxAttempts: 3);
/// final value = await policy.run(() => Future.value('ok'));
/// print(value); // ok
/// ```
///
/// The default [RetryPolicy] does not retry at all: retrying is a policy the
/// caller opts into, never a hidden default.
final class RetryPolicy {
  /// Creates a retry policy.
  ///
  /// [maxAttempts] counts the first attempt, so `1` means "never retry" and
  /// `3` means "at most two retries".
  const RetryPolicy({
    this.maxAttempts = 1,
    this.delay = _defaultDelay,
    this.retryIf,
    this.sleep = _defaultSleep,
  }) : assert(maxAttempts > 0, 'maxAttempts must be greater than zero');

  /// Creates a policy with exponential backoff.
  ///
  /// The wait grows from [initialDelay] by [factor] per attempt, capped at
  /// [maxDelay]: one second, two seconds, four seconds, ...
  factory RetryPolicy.exponentialBackoff({
    int maxAttempts = 3,
    Duration initialDelay = const Duration(seconds: 1),
    double factor = 2,
    Duration maxDelay = const Duration(seconds: 30),
  }) {
    assert(maxAttempts > 0, 'maxAttempts must be greater than zero');
    assert(initialDelay > Duration.zero, 'initialDelay must be positive');

    return RetryPolicy(
      maxAttempts: maxAttempts,
      delay: (attempt, error) {
        final backoff = initialDelay * math.pow(factor, attempt - 1);
        return backoff > maxDelay ? maxDelay : backoff;
      },
    );
  }

  /// A policy that never retries.
  static const RetryPolicy none = RetryPolicy();

  /// The maximum number of attempts, including the first one.
  final int maxAttempts;

  /// How long to wait before the next attempt, given the failure that just
  /// happened.
  final RetryDelay delay;

  /// An optional predicate that decides whether [error] may be retried.
  ///
  /// When it returns `false`, the error surfaces immediately even if attempts
  /// remain. Use it to avoid retrying client errors, cancellations or failures
  /// that cannot succeed on a second try.
  final RetryPredicate? retryIf;

  /// How the computed backoff is waited out.
  ///
  /// Pass a no-op in tests to run retries instantly while still asserting on
  /// the durations this policy asked for.
  final RetrySleep sleep;

  /// Runs [task], retrying it while this policy allows.
  ///
  /// The returned future does not settle until [task] succeeds or the last
  /// attempt fails. The failure that surfaces is the one from the final attempt,
  /// with its original stack trace intact; intermediate failures are handed to
  /// [delay] and [retryIf] rather than discarded.
  Future<T> run<T>(Future<T> Function() task) async {
    var attempt = 0;

    while (true) {
      attempt++;
      try {
        return await task();
      } catch (error, stackTrace) {
        if (attempt >= maxAttempts) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        final retryable = retryIf?.call(error) ?? true;
        if (!retryable) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        await sleep(delay(attempt, error));
      }
    }
  }

  /// The default backoff: 250ms, 500ms, 1s, ... capped at 30s.
  static Duration _defaultDelay(int attempt, Object error) {
    final exponent = math.min(attempt - 1, 10);
    final backoff = const Duration(milliseconds: 250) * math.pow(2, exponent);
    const cap = Duration(seconds: 30);

    return backoff > cap ? cap : backoff;
  }

  /// The default wait: a real timer, owned by the caller's event loop.
  static Future<void> _defaultSleep(Duration duration) =>
      Future<void>.delayed(duration);
}
