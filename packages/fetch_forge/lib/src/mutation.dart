import 'package:signals/signals.dart';

import 'cache_key.dart';
import 'query_client.dart';
import 'retry_policy.dart';
import 'status.dart';

// Private fields are assigned from public parameter names on purpose: the
// constructor's signature is part of the API, `this._mutator` is not.
// ignore_for_file: prefer_initializing_formals

/// A one-shot write: a single call, with its outcome on the signals.
///
/// Where a query fetches when it is watched, a mutation runs only when it is
/// asked to. Everything it exposes is a [ReadonlySignal], so a button can
/// subscribe to [isPending] and a form to [error] without any callback wiring.
///
/// ```dart
/// Future<int> createUser(String name) async => name.length;
///
/// final createUser = Mutation<int, String>(
///   mutator: createUser,
///   retry: RetryPolicy.exponentialBackoff(maxAttempts: 2),
/// );
///
/// // Fire and forget: a failure lands on `error`, it never throws here.
/// createUser.mutate('ada').ignore();
///
/// // Reactive: everything the mutation exposes is a ReadonlySignal.
/// effect(() => print(createUser.isPending.value));
/// ```
///
/// ## Errors are signals, unless you ask
///
/// [mutate] completes normally even when the write fails — the failure is on
/// [error] and [stackTrace], so `createUser.mutate(name).ignore()` is always
/// safe to write. [mutateAsync] is the opt-in counterpart: it rethrows, so
/// `await createUser.mutateAsync(name)` behaves like calling the API directly.
///
/// ## Caching the result
///
/// A mutation does not have to write anything. Pass `cacheDuration` and the
/// successful result is stored in the [QueryClient] under the variables' key,
/// where a query reading the same key finds it without fetching. `null` means
/// the result is not cached at all.
///
/// [invalidateCache] drops what the mutation wrote — and, through the client,
/// asks every query watching that key to fetch again. That is the "write, then
/// refetch" loop, without the mutation knowing anything about queries.
final class Mutation<T, V> {
  /// Creates a write of [mutator].
  ///
  /// [client] is the cache the result is shared through; without one the
  /// mutation owns a private cache. [retry] defaults to no retry. [cacheDuration]
  /// is how long a successful result stays valid for readers; `null` means the
  /// result is not cached. [cacheKey] derives the key from the variables, with
  /// the same rules as a query's. [clock] injects time and must be `null` when a
  /// [client] is shared, since the client's clock stamps its entries.
  Mutation({
    required Future<T> Function(V variables) mutator,
    QueryClient? client,
    RetryPolicy? retry,
    Duration? cacheDuration,
    Object? Function(V variables)? cacheKey,
    DateTime Function()? clock,
  }) : assert(
         client == null || clock == null,
         'Pass the clock to the client that stamps the cache entries, '
         'not to every mutation that writes them.',
       ),
       _mutator = mutator,
       _retry = retry ?? const RetryPolicy(),
       _cacheDuration = cacheDuration,
       _cacheKey = cacheKey,
       _ownsClient = client == null,
       _client = client ?? QueryClient(clock: clock),
       _status = signal(MutationStatus.idle),
       _data = signal<T?>(null),
       _error = signal<Object?>(null),
       _stackTrace = signal<StackTrace?>(null),
       _inFlight = signal(0) {
    _isPending = computed(() => _inFlight.value > 0);
    _isSuccess = computed(() => _status.value == MutationStatus.success);
    _isError = computed(() => _status.value == MutationStatus.error);
  }

  final Future<T> Function(V variables) _mutator;
  final RetryPolicy _retry;
  final Duration? _cacheDuration;
  final Object? Function(V variables)? _cacheKey;
  final QueryClient _client;
  final bool _ownsClient;

  final Signal<MutationStatus> _status;
  final Signal<T?> _data;
  final Signal<Object?> _error;
  final Signal<StackTrace?> _stackTrace;
  final Signal<int> _inFlight;
  late final Computed<bool> _isPending;
  late final Computed<bool> _isSuccess;
  late final Computed<bool> _isError;

  /// The keys whose results this mutation has written, so
  /// [invalidateCache] can drop exactly those.
  final Set<Object?> _written = {};

  bool _disposed = false;

  /// The lifecycle state of the write.
  ReadonlySignal<MutationStatus> get status => _status;

  /// The result of the last successful write, or `null` before one.
  ///
  /// A value survives a later failure: it is only replaced by a new success or
  /// cleared by [reset].
  ReadonlySignal<T?> get data => _data;

  /// The failure of the last settled write, or `null`.
  ReadonlySignal<Object?> get error => _error;

  /// Where [error] was raised.
  ReadonlySignal<StackTrace?> get stackTrace => _stackTrace;

  /// Whether any write is in flight.
  ReadonlySignal<bool> get isPending => _isPending;

  /// Whether the last settled write succeeded.
  ReadonlySignal<bool> get isSuccess => _isSuccess;

  /// Whether the last settled write failed.
  ReadonlySignal<bool> get isError => _isError;

  /// Whether [dispose] has been called.
  bool get disposed => _disposed;

  /// Runs [mutator] and reports the outcome on the signals, never throwing.
  ///
  /// This is the fire-and-forget entry point: the returned future completes
  /// normally even when the write fails, so a button handler or an effect needs
  /// no `catchError`. Two concurrent calls run two writes — a mutation is a
  /// one-shot write by definition, so it is never deduplicated.
  ///
  /// ```dart
  /// ElevatedButton(
  ///   onPressed: () => createUser.mutate(nameController.text).ignore(),
  /// );
  /// ```
  Future<void> mutate(V variables) {
    final key = cacheKeyFor(variables, mapper: _cacheKey);
    if (_disposed) return Future<void>.value();

    // The failure is already on `error` and `stackTrace`; swallowing it here
    // is what makes `mutate` safe to ignore.
    return _execute(
      key,
      variables,
    ).then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }

  /// Runs [mutator] and resolves with its result, rethrowing on failure.
  ///
  /// Use it when the caller wants the value or wants to handle the failure
  /// itself; [mutate] is the version that never throws. A mutation that has
  /// been [dispose]d throws a [StateError] instead of resolving, because it has
  /// no result to hand back.
  Future<T> mutateAsync(V variables) {
    final key = cacheKeyFor(variables, mapper: _cacheKey);
    if (_disposed) {
      throw StateError(
        'This mutation has been disposed. Create a new one, or check '
        '"disposed" before running a write.',
      );
    }

    return _execute(key, variables);
  }

  /// Returns the mutation to its idle state.
  ///
  /// Clears the last value and failure. What the mutation wrote to the cache is
  /// untouched — use [invalidateCache] for that.
  void reset() {
    if (_disposed) return;

    batch(() {
      _status.value = MutationStatus.idle;
      _data.value = null;
      _error.value = null;
      _stackTrace.value = null;
    });
  }

  /// Drops the cached results this mutation wrote and tells the client.
  ///
  /// With [variables] it drops that key alone; without them it drops every key
  /// this mutation has written. Either way the client notifies its listeners,
  /// so a query watching the same key refetches — that is how a write turns
  /// into a refetch without the mutation knowing anything about queries.
  void invalidateCache([V? variables]) {
    if (_disposed) return;

    if (variables != null) {
      final key = cacheKeyFor(variables, mapper: _cacheKey);
      _written.remove(key);
      _client.invalidate(key);

      return;
    }

    for (final key in _written.toSet()) {
      _client.invalidate(key);
    }
    _written.clear();
  }

  /// Disposes every signal and releases the cache this mutation owns.
  ///
  /// A write already in flight still settles, but its result is discarded
  /// instead of being written to a disposed signal. Disposing twice is a no-op.
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    _written.clear();

    _isError.dispose();
    _isSuccess.dispose();
    _isPending.dispose();
    _inFlight.dispose();
    _stackTrace.dispose();
    _error.dispose();
    _data.dispose();
    _status.dispose();

    if (_ownsClient) _client.dispose();
  }

  Future<T> _execute(Object? key, V variables) async {
    // Every read here is a `peek`: like a query, a mutation may run inside
    // an effect, and a `.value` read would subscribe that effect to the
    // mutation's own signals and re-trigger it on every write below.
    batch(() {
      _inFlight.value = _inFlight.peek() + 1;
      _status.value = MutationStatus.pending;
      _error.value = null;
      _stackTrace.value = null;
    });

    try {
      final value = await _retry.run(() => _mutator(variables));
      if (_disposed) return value;

      batch(() {
        _data.value = value;
        _error.value = null;
        _stackTrace.value = null;
        _status.value = MutationStatus.success;
      });
      _rememberResult(key, value);

      return value;
    } catch (error, stackTrace) {
      if (!_disposed) {
        batch(() {
          _error.value = error;
          _stackTrace.value = stackTrace;
          _status.value = MutationStatus.error;
        });
      }
      rethrow;
    } finally {
      if (!_disposed) _inFlight.value = _inFlight.peek() - 1;
    }
  }

  void _rememberResult(Object? key, T value) {
    final duration = _cacheDuration;
    if (duration == null) return;

    _client.write(key, value, expiresIn: duration);
    _written.add(key);
  }
}
