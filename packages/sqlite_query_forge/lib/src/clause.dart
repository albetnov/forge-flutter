import 'expression.dart';
import 'sql_fragment.dart';

enum SortOrder {
  asc('ASC'),
  desc('DESC');

  const SortOrder(this.sql);

  final String sql;
}

final class OrderBy {
  final Expression expression;
  final SortOrder order;

  const OrderBy(this.expression, [this.order = SortOrder.asc]);
}

enum JoinKind {
  inner('INNER JOIN'),
  left('LEFT JOIN'),
  leftOuter('LEFT OUTER JOIN'),
  cross('CROSS JOIN');

  const JoinKind(this.sql);

  final String sql;
}

abstract class Source {
  const Source();

  void writeTo(SqlFragment fragment);
}

/// A table reference in a `FROM` or `JOIN` clause, optionally aliased.
final class TableSource extends Source {
  final String name;
  final String? alias;

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

final class JoinClause {
  final JoinKind kind;
  final Source source;
  final Expression? on;

  const JoinClause(this.kind, this.source, [this.on]);

  factory JoinClause.inner(Source source, Expression on) =>
      JoinClause(JoinKind.inner, source, on);

  factory JoinClause.left(Source source, Expression on) =>
      JoinClause(JoinKind.left, source, on);

  factory JoinClause.cross(Source source) => JoinClause(JoinKind.cross, source);
}

final class Grouping {
  final List<Expression> expressions;
  final Expression? having;

  const Grouping(this.expressions, [this.having]);
}

final class CompiledQuery {
  final String sql;
  final List<Object?> args;

  const CompiledQuery(this.sql, this.args);

  @override
  String toString() => args.isEmpty ? sql : '$sql  -- args: $args';
}
