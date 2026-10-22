import 'package:flutter/widgets.dart';
import 'package:signals/signals_flutter.dart';

import '../../fetch_forge.dart';
import 'query_scope.dart';

/// A read-only view of a [Query] owned by a [QueryBuilder].
///
/// The builder hands this to its `builder` callback: the state of the read
/// and the calls that drive it. It deliberately hides the [Query] itself, so
/// the query cannot be disposed from under the widget that owns it, and it
/// hides [Query.bind], because the widget owns the variables binding.
///
/// ```dart
/// QueryBuilder<List<String>, int>(
///   fetcher: fetchUsers,
///   variables: page,
///   builder: (context, query) => switch (query.snapshot.value) {
///     AsyncValueData(:final value) => Text(value.join(', ')),
///     AsyncValueLoading() => const Text('Loading...'),
///     AsyncValueError(:final error) => Text('Failed: $error'),
///     AsyncValueIdle() => const Text('Idle'),
///   },
/// );
/// ```
final class QueryView<T, V> {
  QueryView._(this._query);

  final Query<T, V> _query;

  /// The read as one value, ready to hand to a UI.
  ///
  /// A refetch keeps the last value: the snapshot becomes
  /// [AsyncValueLoading] with [AsyncValueLoading.previous] set, so a consumer
  /// can render stale data instead of a spinner.
  ReadonlySignal<AsyncValue<T>> get snapshot => _query.snapshot;

  /// The lifecycle state of the read.
  ReadonlySignal<QueryStatus> get status => _query.status;

  /// The last successful value, or `null` before the first success.
  ///
  /// A value survives a refetch: it is only replaced once a fetch settles.
  ReadonlySignal<T?> get data => _query.data;

  /// The failure of the last settled fetch, or `null`.
  ReadonlySignal<Object?> get error => _query.error;

  /// Where [error] was raised.
  ReadonlySignal<StackTrace?> get stackTrace => _query.stackTrace;

  /// Whether any fetch is in flight, for any key.
  ReadonlySignal<bool> get isFetching => _query.isFetching;

  /// Whether the read is loading for the first time: a fetch is in flight and
  /// there is no data to show yet.
  ReadonlySignal<bool> get isLoading => _query.isLoading;

  /// Whether the last settled fetch succeeded.
  ReadonlySignal<bool> get isSuccess => _query.isSuccess;

  /// Whether the last settled fetch failed.
  ReadonlySignal<bool> get isError => _query.isError;

  /// Whether the read is older than the query's `staleTime`.
  ReadonlySignal<bool> get isStale => _query.isStale;

  /// Serves [variables] from the cache when it is fresh, and fetches
  /// otherwise.
  ///
  /// This is the same call as [Query.fetch]: the returned future never fails,
  /// a failure lands on [error], and concurrent calls for the same key share
  /// one fetch.
  Future<void> watch(V variables) => _query.watch(variables);

  /// Fetches [variables] even when a fresh cache entry exists.
  ///
  /// This is the explicit fetch: it always goes to the network, and it is the
  /// call a button makes when the user asks for fresh data.
  Future<void> refetch(V variables) => _query.refetch(variables);

  /// Seeds [variables] with [value] without fetching.
  ///
  /// The value is written to the cache and the read moves to success, so it
  /// is the way to seed data optimistically or to prime a result the caller
  /// already holds.
  void setData(T value, V variables) => _query.setData(value, variables);

  /// Drops the cached entry for [variables] and marks the read stale.
  ///
  /// When the read has been asked for [variables] at least once, the
  /// invalidation refetches it.
  void invalidate(V variables) => _query.invalidate(variables);

  /// Invalidates every key the read can see.
  void invalidateAll() => _query.invalidateAll();
}

/// A widget that reads remote data through a [Query] it owns.
///
/// Takes an async function, a [ReadonlySignal] of its variables and a builder
/// over a [QueryView]. On mount it creates the query, binds the variables
/// signal — so a new value refetches — and subscribes to [refresh] when one
/// is given. It rebuilds through a [SignalBuilder] over the view's signals
/// and disposes the bindings, the refresh effect and the query together on
/// unmount.
///
/// ```dart
/// final page = signal(1);
///
/// QueryBuilder<List<String>, int>(
///   fetcher: fetchUsers,
///   variables: page,
///   builder: (context, query) => switch (query.snapshot.value) {
///     AsyncValueData(:final value) => Text(value.join(', ')),
///     AsyncValueLoading() => const Text('Loading...'),
///     AsyncValueError(:final error) => Text('Failed: $error'),
///     AsyncValueIdle() => const Text('Idle'),
///   },
/// );
/// ```
///
/// ## Fetching on demand
///
/// By default the read fetches when it mounts, because the variables signal
/// drives it. Set [autoFetch] to `false` and the builder does not bind the
/// variables signal: the read stays [AsyncValueIdle] until something asks for
/// it, either imperatively through [QueryView.refetch] or declaratively
/// through a [refresh] bump.
///
/// ```dart
/// QueryBuilder<List<String>, int>(
///   fetcher: fetchUsers,
///   variables: page,
///   autoFetch: false,
///   builder: (context, query) => FilledButton(
///     onPressed: () => query.refetch(page.value).ignore(),
///     child: Text(query.isFetching.value ? 'Loading...' : 'Load users'),
///   ),
/// );
/// ```
///
/// With [autoFetch] off, a variables change alone never fetches; the next
/// explicit call picks up the current variables. Once a key has been
/// fetched, invalidating it refetches it, exactly as in automatic mode.
///
/// ## Lifecycle
///
/// When its arguments change — a new [fetcher], [staleTime], [cacheTime],
/// [retry], [cacheKey], [enabled], [client], [variables] or [refresh] — the
/// old query no longer describes the request, so the state disposes it and
/// builds a new one. Changing [autoFetch] keeps the query and only rewires
/// the binding. Only [builder] may change without a rebuild.
final class QueryBuilder<T, V> extends StatefulWidget {
  /// Creates a builder of [fetcher] watched through [variables].
  const QueryBuilder({
    super.key,
    required this.fetcher,
    required this.variables,
    required this.builder,
    this.client,
    this.retry,
    this.staleTime,
    this.cacheTime,
    this.cacheKey,
    this.enabled = true,
    this.refresh,
    this.autoFetch = true,
  });

  /// The async function the owned query reads.
  final Future<T> Function(V variables) fetcher;

  /// The variables the fetch runs with; a new value refetches.
  final ReadonlySignal<V> variables;

  /// Builds the UI from the query's view.
  final Widget Function(BuildContext context, QueryView<T, V> query) builder;

  /// The cache the owned query shares, defaulting to the nearest [QueryScope].
  ///
  /// Without a client and without a scope the query owns a private cache.
  final QueryClient? client;

  /// How a failed call is retried; the default never retries.
  final RetryPolicy? retry;

  /// How long a cached result may be served without a fetch; `null` means
  /// always stale.
  final Duration? staleTime;

  /// How long an entry stays in the cache; `null` means until evicted.
  final Duration? cacheTime;

  /// Derives the cache key from the variables, with the same rules as a
  /// query's.
  final Object? Function(V variables)? cacheKey;

  /// Gates fetching: while `false`, watching does nothing.
  final bool enabled;

  /// An optional signal that forces a refetch when bumped.
  ///
  /// Only the bump matters, not the value: any change refetches with the
  /// current variables, even while [enabled] is `false`, the same way an
  /// explicit `refetch` does.
  final ReadonlySignal<Object?>? refresh;

  /// Whether the read fetches on its own.
  ///
  /// While `true` (the default), the variables signal drives the fetch: the
  /// query fetches on mount and a new value refetches. While `false`, the
  /// builder does not bind the variables signal, so the read stays
  /// [AsyncValueIdle] until an explicit call — [QueryView.refetch] or a
  /// [refresh] bump — asks for the data.
  final bool autoFetch;

  @override
  State<QueryBuilder<T, V>> createState() => _QueryBuilderState<T, V>();
}

class _QueryBuilderState<T, V> extends State<QueryBuilder<T, V>> {
  late Query<T, V> _query;
  late QueryView<T, V> _view;
  EffectCleanup? _stopBind;
  EffectCleanup? _stopRefresh;
  QueryClient? _scopeClient;
  bool _started = false;
  bool _firstRefresh = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final QueryClient? scopeClient = QueryScope.maybeOf(context);
    if (!_started) {
      _scopeClient = scopeClient;
      _createQuery();
      _started = true;
    } else if (widget.client == null && scopeClient != _scopeClient) {
      _scopeClient = scopeClient;
      _createQuery();
    }
  }

  @override
  void didUpdateWidget(covariant QueryBuilder<T, V> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fetcher != oldWidget.fetcher ||
        widget.variables != oldWidget.variables ||
        widget.client != oldWidget.client ||
        widget.retry != oldWidget.retry ||
        widget.staleTime != oldWidget.staleTime ||
        widget.cacheTime != oldWidget.cacheTime ||
        widget.cacheKey != oldWidget.cacheKey ||
        widget.enabled != oldWidget.enabled ||
        widget.refresh != oldWidget.refresh) {
      _createQuery();
    } else if (widget.autoFetch != oldWidget.autoFetch) {
      // Only the binding changes: the query, and the data it already holds,
      // still describe the request.
      _applyAutoFetch();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      // Read on purpose: the widget rebuilds on every state change of the
      // query, even when the builder reads no signal of its own. The
      // snapshot is a computed over the status, the data, the error and the
      // staleness, so it changes whenever any of them does.
      dependencies: <ReadonlySignal<dynamic>>[_view.snapshot],
      builder: (BuildContext context) => widget.builder(context, _view),
    );
  }

  @override
  void dispose() {
    _stopRefresh?.call();
    _stopRefresh = null;
    _stopBind?.call();
    _stopBind = null;
    _query.dispose();
    super.dispose();
  }

  /// Drops the owned query, its binding and its refresh effect, then wires a
  /// new query from the current widget and scope.
  void _createQuery() {
    if (_started) {
      _stopRefresh?.call();
      _stopRefresh = null;
      _stopBind?.call();
      _stopBind = null;
      _query.dispose();
    }
    _query = Query<T, V>(
      fetcher: widget.fetcher,
      client: widget.client ?? _scopeClient,
      retry: widget.retry,
      staleTime: widget.staleTime,
      cacheTime: widget.cacheTime,
      cacheKey: widget.cacheKey,
      enabled: widget.enabled,
    );
    _view = QueryView<T, V>._(_query);
    _applyAutoFetch();
    _wireRefresh();
  }

  /// Binds the variables signal while the read fetches on its own, and
  /// unbinds it otherwise.
  ///
  /// The binding is owned by the query — `_query.dispose()` stops it
  /// together with the signals — but it is stopped explicitly here, because
  /// unbinding has to happen without disposing the query.
  void _applyAutoFetch() {
    if (widget.autoFetch) {
      _stopBind ??= _query.bind(widget.variables);
    } else {
      _stopBind?.call();
      _stopBind = null;
    }
  }

  /// Wires the refresh signal, when there is one, to the owned query.
  void _wireRefresh() {
    final ReadonlySignal<Object?>? refresh = widget.refresh;
    if (refresh == null) return;

    _firstRefresh = true;
    _stopRefresh = effect(() {
      // Read on purpose: this is the dependency.
      refresh.value;
      if (_firstRefresh) {
        _firstRefresh = false;
        return;
      }
      // `peek` so this effect subscribes to nothing but the refresh;
      // the variables signal has its own binding.
      _query.refetch(widget.variables.peek()).ignore();
    });
  }
}
