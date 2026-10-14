/// A zero-cost, declarative SQLite query builder for Dart.
///
/// [Column] is a `const` class, so a column reference is canonicalized instead
/// of allocated. Runtime values are always bound as `?` parameters, never
/// inlined, so generated SQL is safe by construction.
///
/// The package ships no driver. Implement [ForgeExecutor] over the binding you
/// already use and pass it to [Forge].
library;

export 'src/clause.dart';
export 'src/executor.dart';
export 'src/expression.dart';
export 'src/forge.dart';
export 'src/schema.dart';
export 'src/shortcuts.dart';
export 'src/sql_fragment.dart';
export 'src/statement.dart';
export 'src/table.dart';
export 'src/write_builder.dart';
