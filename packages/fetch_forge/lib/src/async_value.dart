/// A snapshot of the state of an asynchronous operation.
///
/// [AsyncValue] is the single shape that describes everything a consumer needs
/// to render a request: whether it is waiting, what the last successful value
/// was, and what went wrong. It is the only aggregate that crosses the boundary
/// between a data holder and its observers, which is why it is a plain value
/// type rather than another signal.
///
/// Match on it with Dart 3 patterns:
///
/// ```dart
/// final label = switch (snapshot) {
///   AsyncValueIdle() => 'idle',
///   AsyncValueLoading(:final previous) => previous == null ? 'loading' : 'refreshing',
///   AsyncValueData(:final value) => 'got $value',
///   AsyncValueError(:final error) => 'failed: $error',
/// };
/// ```
///
/// Because the hierarchy is `sealed`, the `switch` above is exhaustive: adding
/// a case to [AsyncValue] becomes a compile-time error for every consumer.
///
/// [AsyncValue] intentionally does not implement `operator ==`. Snapshot
/// instances are state machines, not values: two `AsyncValueData` holding the same
/// payload are different moments in time. Compare the payloads if you need
/// equality.
///
/// The cases are named `AsyncValue*` rather than `AsyncData`/`AsyncLoading`/
/// `AsyncError` because `package:signals` exports types with those exact names
/// for its own async state. Importing both packages must stay unambiguous.
sealed class AsyncValue<T> {
  const AsyncValue._();

  /// Creates an [AsyncValueIdle] snapshot: nothing has been requested yet.
  const factory AsyncValue.idle() = AsyncValueIdle<T>;

  /// Creates an [AsyncValueLoading] snapshot: an operation is in flight.
  ///
  /// [previous] carries the last successful value while it is still meaningful,
  /// so a refresh can render as "stale data" instead of "empty".
  const factory AsyncValue.loading({T? previous}) = AsyncValueLoading<T>;

  /// Creates an [AsyncValueData] snapshot: an operation succeeded.
  ///
  /// [isStale] defaults to `false`; the default lives on [AsyncValueData].
  const factory AsyncValue.data(T value, {bool isStale}) = AsyncValueData<T>;

  /// Creates an [AsyncValueError] snapshot: an operation failed.
  const factory AsyncValue.error(Object error, StackTrace stackTrace) =
      AsyncValueError<T>;
}

/// Nothing has been requested yet.
///
/// See [AsyncValue].
final class AsyncValueIdle<T> extends AsyncValue<T> {
  /// Creates an idle snapshot.
  const AsyncValueIdle() : super._();

  @override
  String toString() => 'AsyncValueIdle()';
}

/// An operation is in flight.
///
/// Carries the last successful value in [previous] when there is one, so
/// consumers can tell a first load from a refresh.
///
/// See [AsyncValue].
final class AsyncValueLoading<T> extends AsyncValue<T> {
  /// Creates a loading snapshot, optionally carrying [previous] data.
  const AsyncValueLoading({this.previous}) : super._();

  /// The last successful value, or `null` if the operation has never succeeded.
  final T? previous;

  @override
  String toString() => 'AsyncValueLoading(previous: $previous)';
}

/// An operation succeeded and [value] is its result.
///
/// See [AsyncValue].
final class AsyncValueData<T> extends AsyncValue<T> {
  /// Creates a data snapshot for [value], optionally flagged as stale.
  const AsyncValueData(this.value, {this.isStale = false}) : super._();

  /// The successful result.
  final T value;

  /// Whether [value] is older than the consumer's freshness threshold.
  ///
  /// Stale data is still displayed data: it is the last known good result while
  /// a refresh is in flight or a cache entry has aged out of its window.
  final bool isStale;

  @override
  String toString() => 'AsyncValueData(value: $value, isStale: $isStale)';
}

/// An operation failed with [error].
///
/// See [AsyncValue].
final class AsyncValueError<T> extends AsyncValue<T> {
  /// Creates an error snapshot for [error] and its [stackTrace].
  const AsyncValueError(this.error, this.stackTrace) : super._();

  /// The failure that was raised.
  final Object error;

  /// Where [error] was raised.
  final StackTrace stackTrace;

  @override
  String toString() => 'AsyncValueError(error: $error)';
}
