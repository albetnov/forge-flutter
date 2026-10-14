/// Flutter widgets for `fetch_forge`.
///
/// This entrypoint re-exports the core and adds two widgets: [QueryScope],
/// which shares one [QueryClient] with a subtree, and [QueryBuilder], which
/// owns a [Query], binds it to a variables signal and rebuilds from its
/// [Query.snapshot] through signals.
///
/// The layer is optional sugar. Everything here can be written with the core
/// in about twenty lines: a [Query], a `bind` for the variables signal and a
/// [SignalBuilder] over the snapshot.
library;

import 'package:flutter/widgets.dart';
import 'package:signals/signals_flutter.dart';

import 'fetch_forge.dart';

export 'fetch_forge.dart';

/// Shares one [QueryClient] with every [QueryBuilder] below it.
///
/// A [QueryBuilder] with no explicit `client` reads the nearest scope and
/// passes its client to the query it owns, so two builders watching the same
/// variables share one cache entry and deduplicate one fetch. The scope never
/// disposes the client: whoever created it owns it.
///
/// ```dart
/// final client = QueryClient();
/// final page = signal(1);
///
/// QueryScope(
///   client: client,
///   child: QueryBuilder<List<String>, int>(
///     fetcher: fetchUsers,
///     variables: page,
///     builder: (context, snapshot) => const Text('users'),
///   ),
/// );
/// ```
final class QueryScope extends InheritedWidget {
  /// Creates a scope that provides [client] to its descendants.
  const QueryScope({super.key, required this.client, required super.child});

  /// The client descendants share.
  final QueryClient client;

  /// Returns the nearest scope's client, subscribing to scope changes.
  ///
  /// Returns `null` when there is no scope above [context], in which case a
  /// [QueryBuilder] owns a private client instead.
  static QueryClient? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<QueryScope>()?.client;

  /// Returns the nearest scope's client and throws when there is none.
  ///
  /// Prefer [maybeOf] inside widgets that work without a scope.
  static QueryClient of(BuildContext context) {
    final QueryClient? client = maybeOf(context);
    if (client == null) {
      throw StateError(
        'No QueryScope found above this widget. Wrap the subtree in a '
        'QueryScope, or pass a client to the QueryBuilder directly.',
      );
    }
    return client;
  }

  @override
  bool updateShouldNotify(QueryScope oldWidget) => client != oldWidget.client;
}

/// A widget that reads remote data through a [Query] it owns.
///
/// Takes an async function, a [ReadonlySignal] of its variables and a builder
/// over the [AsyncValue] snapshot. On mount it creates the query, binds the
/// variables signal — so a new value refetches — and subscribes to [refresh]
/// when one is given. It rebuilds through a [SignalBuilder] over
/// [Query.snapshot] and disposes the bindings, the refresh effect and the
/// query together on unmount.
///
/// ```dart
/// final page = signal(1);
///
/// QueryBuilder<List<String>, int>(
///   fetcher: fetchUsers,
///   variables: page,
///   builder: (context, snapshot) => switch (snapshot) {
///     AsyncValueData(:final value) => Text(value.join(', ')),
///     AsyncValueLoading() => const Text('Loading...'),
///     AsyncValueError(:final error) => Text('Failed: $error'),
///     AsyncValueIdle() => const Text('Idle'),
///   },
/// );
/// ```
///
/// When its arguments change — a new [fetcher], [staleTime], [cacheTime],
/// [retry], [cacheKey], [enabled], [client], [variables] or [refresh] — the
/// old query no longer describes the request, so the state disposes it and
/// builds a new one. Only [builder] may change without a rebuild.
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
  });

  /// The async function the owned query reads.
  final Future<T> Function(V variables) fetcher;

  /// The variables the fetch runs with; a new value refetches.
  final ReadonlySignal<V> variables;

  /// Builds the UI from the query's snapshot.
  final Widget Function(BuildContext context, AsyncValue<T> snapshot) builder;

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

  @override
  State<QueryBuilder<T, V>> createState() => _QueryBuilderState<T, V>();
}

class _QueryBuilderState<T, V> extends State<QueryBuilder<T, V>> {
  late Query<T, V> _query;
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
    }
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (BuildContext context) =>
          widget.builder(context, _query.snapshot.value),
    );
  }

  @override
  void dispose() {
    _stopRefresh?.call();
    _stopRefresh = null;
    _query.dispose();
    super.dispose();
  }

  /// Drops the owned query and its refresh effect, then wires a new query
  /// from the current widget and scope.
  void _createQuery() {
    if (_started) {
      _stopRefresh?.call();
      _stopRefresh = null;
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
    // Owned by the query: `_query.dispose()` stops the binding together with
    // the signals, so the variables wiring has no second cleanup to remember.
    // The refresh effect below is raw and is stopped explicitly in `dispose`.
    _query.bind(widget.variables);
    final ReadonlySignal<Object?>? refresh = widget.refresh;
    if (refresh != null) {
      _firstRefresh = true;
      _stopRefresh = effect(() {
        // Read on purpose: this is the dependency.
        refresh.value;
        if (_firstRefresh) {
          _firstRefresh = false;
          return;
        }
        // `peek` so this effect subscribes to nothing but the refresh;
        // the variables signal already has its own binding.
        _query.refetch(widget.variables.peek()).ignore();
      });
    }
  }
}
