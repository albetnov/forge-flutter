/// A single cached result, as stored by a [QueryClient].
///
/// Holds the last successful value together with the moment it was written, so
/// freshness can be evaluated on read instead of with a timer.
final class CacheEntry<T> {
  /// Creates an entry for [data], written at [fetchedAt].
  ///
  /// [expiresAt] lets the writer bound its own result: an entry whose expiry
  /// has passed is dropped on read regardless of what the caller asks about.
  const CacheEntry(this.data, this.fetchedAt, {this.expiresAt});

  /// The cached value.
  final T? data;

  /// When [data] was written, according to the owning client's clock.
  final DateTime fetchedAt;

  /// When [data] stops being served, or `null` when only the caller's cache
  /// time decides.
  ///
  /// Set from a writer that knows how long its result stays valid, such as a
  /// mutation with a `cacheDuration`. An entry expires strictly *after* this
  /// moment, the same boundary a reader's cache time uses.
  final DateTime? expiresAt;

  @override
  String toString() => expiresAt == null
      ? 'CacheEntry(data: $data, fetchedAt: $fetchedAt)'
      : 'CacheEntry(data: $data, fetchedAt: $fetchedAt, '
            'expiresAt: $expiresAt)';
}

/// An optional cache shared by several queries.
///
/// Hand the same client to every query that should share results: two queries
/// asking for the same key then hit one entry, invalidating one key invalidates
/// it everywhere, and `invalidateAll` refreshes the whole graph.
///
/// A client owns no timers. Entries expire only when they are read: [read]
/// drops an entry once it is older than the cache time the caller asks about,
/// so a query nobody looks at simply sits in memory until [clear] or [dispose].
///
/// ```dart
/// final client = QueryClient();
/// client.write('users:1', ['ada', 'grace']);
/// print(client.read<List<String>>('users:1', Duration(minutes: 5))?.data);
/// ```
final class QueryClient {
  /// Creates a client.
  ///
  /// [clock] supplies the current time and defaults to [DateTime.now]. Inject a
  /// stable clock in tests to make staleness and expiry deterministic.
  QueryClient({DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  /// The clock this client timestamps entries with.
  final DateTime Function() clock;

  final Map<Object?, CacheEntry<Object?>> _entries = {};

  final Map<Object?, Future<Object?>> _inFlight = {};

  final Map<Object?, Set<void Function()>> _listeners = {};

  bool _disposed = false;

  /// Whether [dispose] has been called.
  bool get disposed => _disposed;

  /// Returns the entry stored for [key], or `null` when there is nothing fresh
  /// to serve.
  ///
  /// An entry stops being served when it is older than the caller's [cacheTime]
  /// *or* past its own [CacheEntry.expiresAt], whichever comes first; either
  /// way it is dropped by the read itself. A `null` [cacheTime] never expires
  /// an entry, and a missing or already expired entry always reports a miss
  /// rather than raising.
  ///
  /// A read never refreshes [CacheEntry.fetchedAt]: freshness belongs to
  /// writes, not reads.
  CacheEntry<T>? read<T>(Object? key, Duration? cacheTime) {
    if (_disposed) return null;

    final entry = _entries[key];
    if (entry == null) return null;

    final now = clock();
    final expiresAt = entry.expiresAt;
    final expiredByWriter = expiresAt != null && now.isAfter(expiresAt);
    final expiredByCaller =
        cacheTime != null && now.difference(entry.fetchedAt) > cacheTime;

    if (expiredByWriter || expiredByCaller) {
      _entries.remove(key);

      return null;
    }

    return entry as CacheEntry<T>;
  }

  /// Stores [value] as the entry for [key], stamped with [clock].
  ///
  /// [expiresIn] bounds the result from the writer's side — the expiry applies
  /// to every reader, not only the one that asked for it. Use it when the
  /// writer knows how long its result stays valid.
  ///
  /// Entries written by one query must be read with the same `T`; the cache
  /// does not type check keys.
  void write<T>(Object? key, T value, {Duration? expiresIn}) {
    if (_disposed) return;

    final now = clock();

    _entries[key] = CacheEntry<T>(
      value,
      now,
      expiresAt: expiresIn == null ? null : now.add(expiresIn),
    );
  }

  /// Runs [task] at most once per [key] at a time.
  ///
  /// The first caller starts the task and every caller that arrives while it is
  /// in flight receives the very same future, so concurrent requests for one
  /// key collapse into a single execution. The task is registered again on the
  /// next call, once the previous one has settled.
  ///
  /// The returned future is the caller's: the error is delivered to the caller
  /// and the bookkeeping attachment is handled here.
  Future<T> dedupe<T>(Object? key, Future<T> Function() task) {
    if (_disposed) return task();

    final existing = _inFlight[key];
    if (existing != null) return existing as Future<T>;

    final future = task();
    _inFlight[key] = future;

    void forget() {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    }

    // The caller owns `future`; this attachment only unblocks the next caller
    // and must not report the failure a second time.
    future.then<void>(
      (_) => forget(),
      onError: (Object _, StackTrace _) => forget(),
    );

    return future;
  }

  /// Drops the entry for [key] and notifies everything watching [key].
  ///
  /// Listeners are notified even when there was no entry to drop: the point is
  /// that anyone holding results for [key] considers them outdated.
  void invalidate(Object? key) {
    _entries.remove(key);
    _notify(key);
  }

  /// Drops every entry and notifies every key that has listeners.
  void invalidateAll() {
    final keys = _listeners.keys.toSet();
    _entries.clear();

    for (final key in keys) {
      _notify(key);
    }
  }

  /// Drops every entry without notifying anyone.
  ///
  /// Use it to reclaim memory, for example in test teardown. Use [invalidate]
  /// or [invalidateAll] when callers should react to the results changing.
  void clear() {
    _entries.clear();
  }

  /// Clears every entry, abandons in-flight bookkeeping and releases every
  /// listener.
  ///
  /// The client keeps working afterwards: reads report misses, writes are
  /// ignored and deduplication degrades to a plain call, so queries that are
  /// still finishing their work cannot fail on a disposed client.
  void dispose() {
    if (_disposed) return;

    _disposed = true;
    _entries.clear();
    _inFlight.clear();
    _listeners.clear();
  }

  /// Calls [listener] whenever [key] is invalidated, and returns a function that
  /// removes it.
  ///
  /// This is how a mutation asks every query holding results for its key to
  /// fetch again, without the client knowing anything about queries. Registering
  /// on a disposed client is a no-op, so nothing outlives the client.
  void Function() onInvalidate(Object? key, void Function() listener) {
    if (_disposed) return () {};

    final listeners = _listeners.putIfAbsent(key, () => <void Function()>{});
    listeners.add(listener);

    return () {
      listeners.remove(listener);
      if (listeners.isEmpty) _listeners.remove(key);
    };
  }

  void _notify(Object? key) {
    final listeners = _listeners[key];
    if (listeners == null || listeners.isEmpty) return;

    for (final listener in listeners.toList()) {
      listener();
    }
  }
}
