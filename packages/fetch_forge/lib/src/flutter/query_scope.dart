import 'package:flutter/widgets.dart';

import '../../fetch_forge.dart';
import 'query_builder.dart';

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
