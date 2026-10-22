/// Flutter widgets for `fetch_forge`.
///
/// This entrypoint re-exports the core and adds three widgets: [QueryScope],
/// which shares one [QueryClient] with a subtree, [QueryBuilder], which owns a
/// [Query], binds it to a variables signal and rebuilds from the [QueryView]
/// it hands to its builder, and [MutationBuilder], which owns a [Mutation] and
/// rebuilds from the [MutationView] it hands to its builder.
///
/// The layer is optional sugar. Everything here can be written with the core
/// in about twenty lines: a [Query], a `bind` for the variables signal and a
/// [SignalBuilder] over the snapshot.
library;

export 'fetch_forge.dart';
export 'src/flutter/mutation_builder.dart';
export 'src/flutter/query_builder.dart';
export 'src/flutter/query_scope.dart';
