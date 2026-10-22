import 'package:flutter/widgets.dart';
import 'package:signals/signals_flutter.dart';

import '../../fetch_forge.dart';
import 'query_scope.dart';

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
