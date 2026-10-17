import 'expression.dart';
import 'sql_fragment.dart';

/// The direction an `ORDER BY` key sorts in.
enum SortOrder {
  /// Ascending, rendered `ASC`.
  asc('ASC'),

  /// Descending, rendered `DESC`.
  desc('DESC');

  /// Binds this order to its [sql] text.
  const SortOrder(this.sql);

  /// The SQL keyword this order renders.
  final String sql;
}

/// An `ORDER BY` key: an expression and its direction.
final class OrderBy {
  /// The expression sorted on.
  final Expression expression;

  /// The sort direction.
  final SortOrder order;

  /// Orders by [expression] in [order].
  const OrderBy(this.expression, [this.order = SortOrder.asc]);
}

/// A join type and the SQL it renders.
enum JoinKind {
  /// An `INNER JOIN`.
  inner('INNER JOIN'),

  /// A `LEFT JOIN`.
  left('LEFT JOIN'),

  /// A `LEFT OUTER JOIN`.
  leftOuter('LEFT OUTER JOIN'),

  /// A `CROSS JOIN`.
  cross('CROSS JOIN');

  /// Binds this join kind to its [sql] text.
  const JoinKind(this.sql);

  /// The SQL join keyword this kind renders.
  final String sql;
}

/// A `FROM` or `JOIN` source that renders SQL.
abstract class Source {
  /// A const constructor for subclasses.
  const Source();

  /// Writes this source's SQL to [fragment].
  void writeTo(SqlFragment fragment);
}

/// A table reference in a `FROM` or `JOIN` clause, optionally aliased.
final class TableSource extends Source {
  /// The table name, quoted as an identifier.
  final String name;

  /// The alias, quoted as an identifier, if any.
  final String? alias;

  /// References [name], optionally under [alias].
  const TableSource(this.name, [this.alias]);

  /// The name the query binds this table under: the alias when present,
  /// otherwise [name]. Columns are qualified against this.
  String get reference => alias ?? name;

  @override
  void writeTo(SqlFragment fragment) {
    fragment.writeIdentifier(name);
    final a = alias;
    if (a != null) {
      fragment.write(' AS ');
      fragment.writeIdentifier(a);
    }
  }
}

/// A `JOIN` clause: a kind, a source, and an optional `ON` predicate.
final class JoinClause {
  /// The join type.
  final JoinKind kind;

  /// The joined source.
  final Source source;

  /// The `ON` predicate, if any.
  final Expression? on;

  /// Joins [source] using [kind] and [on].
  const JoinClause(this.kind, this.source, [this.on]);

  /// An `INNER JOIN` of [source] on [on].
  factory JoinClause.inner(Source source, Expression on) =>
      JoinClause(JoinKind.inner, source, on);

  /// A `LEFT JOIN` of [source] on [on].
  factory JoinClause.left(Source source, Expression on) =>
      JoinClause(JoinKind.left, source, on);

  /// A `CROSS JOIN` of [source].
  factory JoinClause.cross(Source source) => JoinClause(JoinKind.cross, source);
}

/// A `GROUP BY` clause with an optional `HAVING` predicate.
final class Grouping {
  /// The grouping expressions.
  final List<Expression> expressions;

  /// The `HAVING` predicate, if any.
  final Expression? having;

  /// Groups by [expressions], filtering with [having].
  const Grouping(this.expressions, [this.having]);
}

/// A rendered SQL string and the arguments it binds.
final class CompiledQuery {
  /// The SQL text.
  final String sql;

  /// The bound arguments, in order.
  final List<Object?> args;

  /// Pairs [sql] with its bound [args].
  const CompiledQuery(this.sql, this.args);

  @override
  String toString() => args.isEmpty ? sql : '$sql  -- args: $args';
}
