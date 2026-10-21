/// Flutter widgets for `fetch_forge`.
///
/// This entrypoint re-exports the core and adds three widgets: [QueryScope],
/// which shares one [QueryClient] with a subtree, [QueryBuilder], which owns a
/// [Query], binds it to a variables signal and rebuilds from its
/// [Query.snapshot] through signals, and [MutationBuilder], which owns a
/// [Mutation] and rebuilds from its signals.
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

/// A read-only view of a [Mutation] owned by a [MutationBuilder].
///
/// The builder hands this to its `builder` callback: the signals of the
/// mutation, the calls that start a write, and the two calls that tidy up
/// after it. It deliberately hides the [Mutation] itself, so the mutation
/// cannot be disposed from under the widget that owns it.
///
/// ```dart
/// MutationBuilder<int, String>(
///   mutator: createUser,
///   builder: (context, mutation) => ElevatedButton(
///     onPressed: () => mutation.mutate('ada').ignore(),
///     child: Text(mutation.isPending.value ? 'Saving...' : 'Save'),
///   ),
/// );
/// ```
final class MutationView<T, V> {
  MutationView._(this._mutation);

  final Mutation<T, V> _mutation;

  /// The lifecycle state of the write.
  ReadonlySignal<MutationStatus> get status => _mutation.status;

  /// The result of the last successful write, or `null` before one.
  ///
  /// A value survives a later failure: it is only replaced by a new success
  /// or cleared by [reset].
  ReadonlySignal<T?> get data => _mutation.data;

  /// The failure of the last settled write, or `null`.
  ReadonlySignal<Object?> get error => _mutation.error;

  /// Where [error] was raised.
  ReadonlySignal<StackTrace?> get stackTrace => _mutation.stackTrace;

  /// Whether any write is in flight.
  ReadonlySignal<bool> get isPending => _mutation.isPending;

  /// Whether the last settled write succeeded.
  ReadonlySignal<bool> get isSuccess => _mutation.isSuccess;

  /// Whether the last settled write failed.
  ReadonlySignal<bool> get isError => _mutation.isError;

  /// Runs the write and reports the outcome on the signals, never throwing.
  ///
  /// This is the fire-and-forget entry point: the returned future completes
  /// normally even when the write fails, so a button handler needs no
  /// `catchError`. Two concurrent calls run two writes — a mutation is a
  /// one-shot write by definition, so it is never deduplicated.
  Future<void> mutate(V variables) => _mutation.mutate(variables);

  /// Runs the write and resolves with its result, rethrowing on failure.
  ///
  /// Use it when the caller wants the value or wants to handle the failure
  /// itself; [mutate] is the version that never throws.
  Future<T> mutateAsync(V variables) => _mutation.mutateAsync(variables);

  /// Returns the write to its idle state.
  ///
  /// Clears the last value and failure. What the write put in the cache is
  /// untouched — use [invalidateCache] for that.
  void reset() => _mutation.reset();

  /// Drops the cached results this write produced and tells the client.
  ///
  /// With [variables] it drops that key alone; without them it drops every
  /// key this mutation has written. Either way the client notifies its
  /// listeners, so a query watching the same key refetches.
  void invalidateCache([V? variables]) => _mutation.invalidateCache(variables);
}

/// A widget that writes remote data through a [Mutation] it owns.
///
/// Takes an async function and a builder over a [MutationView]. On mount it
/// creates the mutation, wires the [trigger] signal when one is given, and
/// rebuilds through a [SignalBuilder] over the mutation's signals. It disposes
/// the trigger effect and the mutation together on unmount.
///
/// ```dart
/// MutationBuilder<int, String>(
///   mutator: createUser,
///   builder: (context, mutation) => ElevatedButton(
///     onPressed: () => mutation.mutate('ada').ignore(),
///     child: Text(mutation.isPending.value ? 'Saving...' : 'Save'),
///   ),
/// );
/// ```
///
/// ## Two ways to start a write
///
/// The builder can always start the write itself through
/// [MutationView.mutate]. A [trigger] signal adds the declarative way: any
/// change of the trigger runs the write with the current [variables], so a
/// parent can drive the write by bumping a signal instead of wiring a
/// callback.
///
/// ```dart
/// final submit = signal(0);
/// final name = signal('ada');
///
/// MutationBuilder<int, String>(
///   mutator: createUser,
///   variables: name,
///   trigger: submit,
///   builder: (context, mutation) => Text(
///     mutation.isPending.value ? 'Saving...' : 'Save',
///   ),
/// );
///
/// submit.value++; // The write runs with `name.value`.
/// ```
///
/// A [trigger] needs [variables] to run with. The first run of the trigger
/// is skipped — a trigger is a bump, not an initial value — and the
/// variables are read without subscribing, so a variables change alone never
/// starts a write.
///
/// ## Lifecycle
///
/// The mutation is recreated when its arguments change identity — a new
/// [mutator], [client], [retry], [cacheDuration] or [cacheKey] — because the
/// old one no longer describes the write. Changing [builder], [variables] or
/// [trigger] keeps the mutation, so its state and result survive. Only
/// [builder] may be an inline closure; keep [mutator] referentially stable,
/// or the write restarts from an idle state on every parent rebuild.
final class MutationBuilder<T, V> extends StatefulWidget {
  /// Creates a builder of writes performed by [mutator].
  const MutationBuilder({
    super.key,
    required this.mutator,
    required this.builder,
    this.client,
    this.retry,
    this.cacheDuration,
    this.cacheKey,
    this.variables,
    this.trigger,
  }) : assert(
         trigger == null || variables != null,
         'A trigger needs variables to run with: pass the signal that holds '
         'them.',
       );

  /// The async function the owned mutation writes through.
  final Future<T> Function(V variables) mutator;

  /// Builds the UI from the mutation's view.
  final Widget Function(BuildContext context, MutationView<T, V> view) builder;

  /// The cache the owned mutation shares, defaulting to the nearest
  /// [QueryScope].
  ///
  /// Without a client and without a scope the mutation owns a private cache.
  final QueryClient? client;

  /// How a failed write is retried; the default never retries.
  final RetryPolicy? retry;

  /// How long a successful result stays valid for readers; `null` means the
  /// result is not cached.
  final Duration? cacheDuration;

  /// Derives the cache key from the variables, with the same rules as a
  /// query's.
  final Object? Function(V variables)? cacheKey;

  /// The variables a [trigger] runs the write with.
  ///
  /// The signal is read without subscribing when the trigger fires, so a
  /// change of the variables alone never starts a write.
  final ReadonlySignal<V>? variables;

  /// An optional signal that starts the write when bumped.
  ///
  /// Only the bump matters, not the value: any change runs the write with the
  /// current [variables]. The first run is skipped, because a trigger is a
  /// bump and not an initial value.
  final ReadonlySignal<Object?>? trigger;

  @override
  State<MutationBuilder<T, V>> createState() => _MutationBuilderState<T, V>();
}

class _MutationBuilderState<T, V> extends State<MutationBuilder<T, V>> {
  late Mutation<T, V> _mutation;
  late MutationView<T, V> _view;
  EffectCleanup? _stopTrigger;
  QueryClient? _scopeClient;
  bool _started = false;
  bool _firstTrigger = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final QueryClient? scopeClient = QueryScope.maybeOf(context);
    if (!_started) {
      _scopeClient = scopeClient;
      _createMutation();
      _started = true;
    } else if (widget.client == null && scopeClient != _scopeClient) {
      _scopeClient = scopeClient;
      _createMutation();
    }
  }

  @override
  void didUpdateWidget(covariant MutationBuilder<T, V> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.mutator != oldWidget.mutator ||
        widget.client != oldWidget.client ||
        widget.retry != oldWidget.retry ||
        widget.cacheDuration != oldWidget.cacheDuration ||
        widget.cacheKey != oldWidget.cacheKey) {
      _createMutation();
    } else if (widget.trigger != oldWidget.trigger) {
      // The trigger is rewired, the mutation is kept: its state and result
      // still describe the write.
      _stopTrigger?.call();
      _stopTrigger = null;
      _wireTrigger();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      // Read on purpose: the widget rebuilds on every state change of the
      // mutation, even when the builder reads no signal of its own.
      dependencies: <ReadonlySignal<dynamic>>[
        _view.status,
        _view.data,
        _view.error,
      ],
      builder: (BuildContext context) => widget.builder(context, _view),
    );
  }

  @override
  void dispose() {
    _stopTrigger?.call();
    _stopTrigger = null;
    _mutation.dispose();
    super.dispose();
  }

  /// Drops the owned mutation and its trigger effect, then wires a new
  /// mutation from the current widget and scope.
  void _createMutation() {
    _stopTrigger?.call();
    _stopTrigger = null;
    if (_started) _mutation.dispose();
    _mutation = Mutation<T, V>(
      mutator: widget.mutator,
      client: widget.client ?? _scopeClient,
      retry: widget.retry,
      cacheDuration: widget.cacheDuration,
      cacheKey: widget.cacheKey,
    );
    _view = MutationView<T, V>._(_mutation);
    _wireTrigger();
  }

  /// Wires the trigger signal, when there is one, to the owned mutation.
  void _wireTrigger() {
    final ReadonlySignal<Object?>? trigger = widget.trigger;
    if (trigger == null) return;

    _firstTrigger = true;
    _stopTrigger = effect(() {
      // Read on purpose: this is the dependency.
      trigger.value;
      if (_firstTrigger) {
        _firstTrigger = false;
        return;
      }
      final ReadonlySignal<V>? variables = widget.variables;
      if (variables == null) return;
      // `peek` so this effect subscribes to nothing but the trigger: a
      // variables change must not start a write on its own, and the
      // mutation's own signals are never read here.
      _view.mutate(variables.peek()).ignore();
    });
  }
}
