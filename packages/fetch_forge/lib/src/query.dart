import 'package:signals/signals.dart';

import 'async_value.dart';
import 'cache_key.dart';
import 'query_client.dart';
import 'retry_policy.dart';
import 'status.dart';

// Private fields are assigned from public parameter names on purpose: the
// constructor's signature is part of the API, `this._fetcher` is not.
// ignore_for_file: prefer_initializing_formals

/// A cached, retryable, reactive read of some remote data.
///
/// `Query<T, V>` takes an asynchronous function of the variables `V` and exposes
/// everything about its progress as [ReadonlySignal]s, so it composes with the
/// rest of `signals` instead of introducing a second observation model.
///
/// ```dart
/// Future<List<String>> fetchUsers(int page) async => ['ada', 'grace', 'alan'];
///
/// final users = Query<List<String>, int>(
///   fetcher: fetchUsers,
///   staleTime: const Duration(seconds: 30),
///   retry: RetryPolicy.exponentialBackoff(),
/// );
/// final page = signal(1);
///
/// // One line wires the variables signal to the fetch, and `dispose` unwires it
/// // again — `bind` is the effect you would otherwise write by hand.
/// users.bind(page);
///
/// // Everything a query exposes is a ReadonlySignal.
/// effect(() => print(users.snapshot.value));
/// ```
///
/// ## Variables are the cache key
///
/// The variables identify the request, so `V` must have structural equality:
/// records, primitives, and value classes that implement `operator ==` all work.
/// `watch([1, 2])` throws a [CacheKeyError] in debug builds, because two lists
/// are never equal and would therefore never share a cache entry. Pass
/// [cacheKey] to derive a different key from the variables when they carry a
/// field that must not take part in the comparison.
///
/// ## Errors are signals
///
/// [watch] and [refetch] never throw. A failed fetch lands on [error] and
/// [stackTrace], and the returned future completes normally, so
/// `effect(() => query.watch(variables).ignore())` is always safe to write.
final class Query<T, V> {
  /// Creates a read of [fetcher].
  ///
  /// [client] is the cache the read shares with other queries; without one the
  /// query owns a private cache. [retry] defaults to no retry at all.
  /// [staleTime] is how long a cached result may be served without a fetch;
  /// `null` means always stale. [cacheTime] is how long an entry stays in the
  /// cache; `null` means until evicted. [enabled] gates fetching: while it is
  /// `false`, [watch] does nothing. [clock] injects time and must be `null` when
  /// a [client] is shared, since the client's clock is the one that stamps its
  /// entries.
  Query({
    required Future<T> Function(V variables) fetcher,
    QueryClient? client,
    RetryPolicy? retry,
    Duration? staleTime,
    Duration? cacheTime,
    Object? Function(V variables)? cacheKey,
    bool enabled = true,
    DateTime Function()? clock,
  }) : assert(
         client == null || clock == null,
         'Pass the clock to the client that stamps the cache entries, '
         'not to every query that reads them.',
       ),
       _fetcher = fetcher,
       _retry = retry ?? const RetryPolicy(),
       _staleTime = staleTime,
       _cacheTime = cacheTime,
       _cacheKey = cacheKey,
       _enabled = enabled,
       _ownsClient = client == null,
       _client = client ?? QueryClient(clock: clock),
       _status = signal(QueryStatus.idle),
       _data = signal<T?>(null),
       _error = signal<Object?>(null),
       _stackTrace = signal<StackTrace?>(null),
       _inFlight = signal(0),
       _fetchedAt = signal<DateTime?>(null),
       _isStale = signal(true) {
    _isFetching = computed(() => _inFlight.value > 0);
    _isLoading = computed(
      () => _status.value == QueryStatus.loading && _data.value == null,
    );
    _isSuccess = computed(() => _status.value == QueryStatus.success);
    _isError = computed(() => _status.value == QueryStatus.error);
    _snapshot = computed(_currentSnapshot);
  }

  final Future<T> Function(V variables) _fetcher;
  final RetryPolicy _retry;
  final Duration? _staleTime;
  final Duration? _cacheTime;
  final Object? Function(V variables)? _cacheKey;
  final bool _enabled;
  final QueryClient _client;
  final bool _ownsClient;

  final Signal<QueryStatus> _status;
  final Signal<T?> _data;
  final Signal<Object?> _error;
  final Signal<StackTrace?> _stackTrace;
  final Signal<int> _inFlight;
  final Signal<DateTime?> _fetchedAt;
  final Signal<bool> _isStale;
  late final Computed<bool> _isFetching;
  late final Computed<bool> _isLoading;
  late final Computed<bool> _isSuccess;
  late final Computed<bool> _isError;
  late final Computed<AsyncValue<T>> _snapshot;

  /// The variables of every key this query has been asked about, so an
  /// invalidation can refetch the request that produced them.
  final Map<Object?, V> _watched = {};

  final Map<Object?, void Function()> _unsubscribes = {};

  /// The effects created by [bind], owned and cleared by [dispose].
  final List<EffectCleanup> _bindings = [];

  bool _disposed = false;

  /// The lifecycle state of the read.
  ReadonlySignal<QueryStatus> get status => _status;

  /// The last successful value, or `null` before the first success.
  ///
  /// A value survives a refetch: it is only replaced once a fetch settles.
  ReadonlySignal<T?> get data => _data;

  /// The failure of the last settled fetch, or `null`.
  ReadonlySignal<Object?> get error => _error;

  /// Where [error] was raised.
  ReadonlySignal<StackTrace?> get stackTrace => _stackTrace;

  /// Whether any fetch is in flight, for any key.
  ReadonlySignal<bool> get isFetching => _isFetching;

  /// Whether the read is loading for the first time: a fetch is in flight and
  /// there is no data to show yet.
  ReadonlySignal<bool> get isLoading => _isLoading;

  /// Whether the last settled fetch succeeded.
  ReadonlySignal<bool> get isSuccess => _isSuccess;

  /// Whether the last settled fetch failed.
  ReadonlySignal<bool> get isError => _isError;

  /// Whether the read is older than [staleTime].
  ///
  /// A signal cannot subscribe to the wall clock and the library spawns no
  /// timers, so staleness is recomputed whenever the query observes time: at
  /// the start of [watch] and [refetch], on every settle, and whenever data is
  /// seeded or invalidated. Reading it after a long pause reports the last
  /// recomputation, which is why [watch] refreshes it before deciding whether
  /// to fetch.
  ReadonlySignal<bool> get isStale => _isStale;

  /// The read as one value, ready to hand to a UI.
  ///
  /// A refetch keeps the last value: the snapshot becomes
  /// [AsyncValueLoading] with [AsyncValueLoading.previous] set, so a consumer
  /// can render stale data instead of a spinner.
  ReadonlySignal<AsyncValue<T>> get snapshot => _snapshot;

  /// Whether [dispose] has been called.
  bool get disposed => _disposed;

  /// Serves [variables] from the cache when it is fresh, and fetches otherwise.
  ///
  /// The returned future never fails: a failure lands on [error]. Concurrent
  /// calls for the same key share one fetch, and every caller settles from
  /// it — a caller that joins another query's in-flight fetch serves the
  /// entry it wrote, or reports its failure, rather than staying idle.
  ///
  /// ```dart
  /// effect(() => query.watch(page.value).ignore());
  /// ```
  Future<void> watch(V variables) {
    if (_disposed) return Future<void>.value();

    final key = cacheKeyFor(variables, mapper: _cacheKey);
    if (!_enabled) return Future<void>.value();
    _remember(key, variables);
    _refreshStaleness();

    final entry = _client.read<T>(key, _cacheTime);
    if (entry != null && _isFresh(entry.fetchedAt)) {
      _serveFromCache(entry);

      return Future<void>.value();
    }

    return _fetchOrJoin(key, variables);
  }

  /// Watches [variables] reactively and returns a cleanup that stops watching.
  ///
  /// This is the `effect(() => watch(variables.value).ignore())` you would
  /// otherwise write by hand, with one difference: the query owns the effect.
  /// [dispose] stops every effect [bind] created, so a caller that binds in
  /// `initState` has exactly one call to remember. Call the returned function to
  /// stop watching while keeping the query alive.
  ///
  /// ```dart
  /// final users = Query<List<String>, int>(fetcher: fetchUsers);
  /// users.bind(page);
  ///
  /// users.snapshot.value; // AsyncValueData(...) once the fetch settles
  ///
  /// users.dispose(); // Stops the effect, then the signals.
  /// ```
  ///
  /// Reading [snapshot] or [data] inside your own effect or `Watch` is what
  /// subscribes the UI; the binding only decides when to fetch.
  EffectCleanup bind(ReadonlySignal<V> variables) {
    if (_disposed) return () {};

    final stop = effect(() => watch(variables.value).ignore());
    _bindings.add(stop);

    return () {
      _bindings.remove(stop);
      stop();
    };
  }

  /// Alias of [watch].
  Future<void> fetch(V variables) => watch(variables);

  /// Fetches [variables] even when a fresh cache entry exists, and even while
  /// the query is disabled.
  ///
  /// The returned future never fails: a failure lands on [error]. A fetch that
  /// is already in flight for the key is joined rather than duplicated, and
  /// the joiner settles from the shared fetch.
  Future<void> refetch(V variables) {
    if (_disposed) return Future<void>.value();

    final key = cacheKeyFor(variables, mapper: _cacheKey);
    _remember(key, variables);
    _refreshStaleness();

    return _fetchOrJoin(key, variables);
  }

  /// Seeds [variables] with [value] without fetching.
  ///
  /// The value is written to the cache and the query moves to success, so it is
  /// the way to seed data optimistically or to prime a result the caller
  /// already holds. A fetch already in flight for the key still settles on top
  /// of it.
  void setData(T value, V variables) {
    if (_disposed) return;

    final key = cacheKeyFor(variables, mapper: _cacheKey);
    _remember(key, variables);
    final now = _client.clock();

    _client.write(key, value);
    batch(() {
      _data.value = value;
      _error.value = null;
      _stackTrace.value = null;
      _status.value = QueryStatus.success;
      _markFetchedAt(now);
    });
  }

  /// Drops the cached entry for [variables] and marks the read stale.
  ///
  /// When this query has been asked for [variables] at least once — the
  /// "watched" condition of a [watch] call — the invalidation refetches it.
  /// Invalidating a key this query never asked about only clears the shared
  /// cache.
  void invalidate(V variables) {
    if (_disposed) return;

    _client.invalidate(cacheKeyFor(variables, mapper: _cacheKey));
  }

  /// Invalidates every key this query can see.
  ///
  /// With a private cache that is exactly the keys this query wrote. With a
  /// shared [QueryClient] it invalidates every query using that client, and
  /// every one of them refetches the keys it is watching.
  void invalidateAll() => _client.invalidateAll();

  /// Disposes every signal, stops every effect created by [bind] and stops
  /// listening for invalidations.
  ///
  /// A caller that bound a variables signal with [bind] has nothing else to
  /// remember: this one call releases the effect and the signals together. A
  /// fetch already in flight still settles, but its result is discarded instead
  /// of being written to a disposed signal. Disposing twice is a no-op. The cache
  /// is released only when this query created it.
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    for (final unsubscribe in _unsubscribes.values) {
      unsubscribe();
    }
    _unsubscribes.clear();
    _watched.clear();

    final bindings = _bindings.toList();
    _bindings.clear();
    for (final stop in bindings) {
      stop();
    }

    _snapshot.dispose();
    _isStale.dispose();
    _fetchedAt.dispose();
    _inFlight.dispose();
    _stackTrace.dispose();
    _error.dispose();
    _data.dispose();
    _status.dispose();
    _isError.dispose();
    _isSuccess.dispose();
    _isLoading.dispose();
    _isFetching.dispose();

    if (_ownsClient) _client.dispose();
  }

  bool _isFresh(DateTime fetchedAt) {
    final staleTime = _staleTime;

    return staleTime != null &&
        _client.clock().difference(fetchedAt) <= staleTime;
  }

  void _serveFromCache(CacheEntry<T> entry) {
    batch(() {
      _data.value = entry.data;
      _error.value = null;
      _stackTrace.value = null;
      _status.value = QueryStatus.success;
      _markFetchedAt(entry.fetchedAt);
    });
  }

  /// Fetches [variables] for [key], joining the in-flight attempt when
  /// another caller already started one.
  ///
  /// The returned future never fails: the attempt reports its own outcome on
  /// the signals, and a joiner settles from the shared fetch. `dedupe` runs
  /// the task synchronously when nothing is in flight, so `led` tells the two
  /// paths apart.
  Future<void> _fetchOrJoin(Object? key, V variables) {
    bool led = false;
    final Future<void> flight = _client.dedupe(key, () {
      led = true;
      return _attempt(key, variables);
    });

    if (led) {
      // The attempt already reported the outcome on the signals; swallowing
      // it here is what keeps `watch` and `refetch` from ever throwing.
      return flight.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    }

    return _join(key, variables, flight);
  }

  /// Settles this query from another caller's in-flight [flight].
  ///
  /// On success the leader has written the entry, so serving it moves this
  /// query to success with the same value; on failure the shared error lands
  /// on [error]. Either way the returned future completes normally.
  Future<void> _join(Object? key, V variables, Future<void> flight) {
    if (_disposed) return Future<void>.value();
    // Every read here is a `peek`: this runs synchronously inside the
    // caller's effect (`effect(() => watch(v).ignore())`), and a `.value`
    // read would subscribe that effect to the query's own signals and
    // re-trigger it on every write below, forever while the flight pends.
    batch(() {
      _inFlight.value = _inFlight.peek() + 1;
      _status.value = QueryStatus.loading;
      _error.value = null;
      _stackTrace.value = null;
    });

    return flight
        .then<void>(
          (_) {
            if (_disposed) return;
            final CacheEntry<T>? entry = _client.read<T>(key, _cacheTime);
            if (entry != null) {
              _serveFromCache(entry);
            } else {
              // The leader was disposed before it could share its result, so
              // there is nothing to serve: fetch alone instead of settling
              // with nothing. This completes in the background; it never throws.
              _fetchOrJoin(key, variables).ignore();
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (_disposed) return;
            batch(() {
              _error.value = error;
              _stackTrace.value = stackTrace;
              _status.value = QueryStatus.error;
            });
          },
        )
        .whenComplete(() {
          if (!_disposed) _inFlight.value = _inFlight.peek() - 1;
        });
  }

  Future<void> _attempt(Object? key, V variables) async {
    if (_disposed) return;
    // Peeked for the same reason as in `_join`: the synchronous prefix of
    // the leading attempt also runs inside the caller's effect.
    batch(() {
      _inFlight.value = _inFlight.peek() + 1;
      _status.value = QueryStatus.loading;
      _error.value = null;
      _stackTrace.value = null;
    });

    try {
      // The client hands the same future to every caller of this key, so
      // concurrent widgets — and queries sharing the client — run one fetch
      // with one retry budget, and then each settles its own signals.
      final value = await _client.dedupe(
        key,
        () => _retry.run(() => _fetcher(variables)),
      );
      if (_disposed) return;

      final now = _client.clock();
      _client.write(key, value);
      batch(() {
        _data.value = value;
        _error.value = null;
        _stackTrace.value = null;
        _status.value = QueryStatus.success;
        _markFetchedAt(now);
      });
    } catch (error, stackTrace) {
      if (_disposed) return;

      batch(() {
        _error.value = error;
        _stackTrace.value = stackTrace;
        _status.value = QueryStatus.error;
      });
      // The outcome is on the signals, but joiners observe this future:
      // rethrow so a caller that joined the fetch reports the same failure.
      // The leading `watch`/`refetch` swallows it again in `_fetchOrJoin`.
      rethrow;
    } finally {
      if (!_disposed) _inFlight.value = _inFlight.peek() - 1;
    }
  }

  void _markFetchedAt(DateTime? value) {
    _fetchedAt.value = value;
    _refreshStaleness();
  }

  void _refreshStaleness() {
    final fetchedAt = _fetchedAt.peek();
    final stale =
        fetchedAt == null ||
        _staleTime == null ||
        _client.clock().difference(fetchedAt) > _staleTime;

    if (stale != _isStale.peek()) _isStale.value = stale;
  }

  void _remember(Object? key, V variables) {
    if (_disposed) return;

    _watched[key] = variables;
    if (_unsubscribes.containsKey(key)) return;

    _unsubscribes[key] = _client.onInvalidate(key, () => _onInvalidated(key));
  }

  void _onInvalidated(Object? key) {
    // A disabled query never fetches on its own; only an explicit refetch does.
    if (_disposed || !_enabled || !_watched.containsKey(key)) return;

    // The entry is gone, so the read is stale by definition.
    _markFetchedAt(null);
    final variables = _watched[key] as V;
    refetch(variables);
  }

  AsyncValue<T> _currentSnapshot() {
    final status = _status.value;

    if (status == QueryStatus.error) {
      final error = _error.value;
      if (error != null) {
        return AsyncValueError(error, _stackTrace.value ?? StackTrace.empty);
      }
    }

    if (status == QueryStatus.loading) {
      final data = _data.value;

      return data == null
          ? const AsyncValueLoading()
          : AsyncValueLoading(previous: data);
    }

    final data = _data.value;

    return data == null
        ? const AsyncValueIdle()
        : AsyncValueData(data, isStale: _isStale.value);
  }
}
