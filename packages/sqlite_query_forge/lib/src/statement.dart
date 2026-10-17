/// An immutable description compiled into SQL exactly once.
library;

import 'clause.dart';
import 'expression.dart';
import 'sql_fragment.dart';

/// An [Expression] is emitted as written, so it can express a reference such as
/// `excluded."name"`; everything else binds as a parameter.
void _writeValue(SqlFragment fragment, Object? value) {
  if (value is Expression) {
    value.writeTo(fragment);
    return;
  }
  fragment.bind(value);
}

/// A `null` [columns] omits the clause; an empty list means `*`.
void _writeReturning(SqlFragment fragment, List<Expression>? columns) {
  if (columns == null) return;
  if (columns.isEmpty) {
    fragment.write(' RETURNING *');
    return;
  }
  fragment.write(' RETURNING ');
  for (var i = 0; i < columns.length; i++) {
    if (i > 0) fragment.write(', ');
    columns[i].writeTo(fragment);
  }
}

/// A statement that compiles to SQL and its bound arguments.
sealed class Statement {
  /// A const constructor for subclasses.
  const Statement();

  /// Whether this statement returns rows.
  bool get isQuery => this is SelectStatement;

  /// Compiles this statement into a [CompiledQuery].
  CompiledQuery compile() {
    final fragment = SqlFragment();
    writeTo(fragment);
    return CompiledQuery(fragment.sql, fragment.args);
  }

  /// Writes this statement's SQL to [fragment].
  void writeTo(SqlFragment fragment);
}

/// A `SELECT` query.
final class SelectStatement extends Statement {
  /// Empty means `*`.
  final List<Expression> columns;

  /// The table or subquery the rows are read from, if any.
  final Source? from;

  /// The `JOIN` clauses, applied in order.
  final List<JoinClause> joins;

  /// The `WHERE` predicate, if any.
  final Expression? where;

  /// The `GROUP BY` and `HAVING` clauses, if any.
  final Grouping? groupBy;

  /// The `ORDER BY` keys, applied in order.
  final List<OrderBy> orderBy;

  /// The `LIMIT` count, bound as a parameter, if any.
  final int? limit;

  /// The `OFFSET` count, bound as a parameter, if any.
  final int? offset;

  /// Whether `SELECT DISTINCT` is emitted.
  final bool distinct;

  /// Builds a `SELECT` from its clauses.
  const SelectStatement({
    this.columns = const [],
    this.from,
    this.joins = const [],
    this.where,
    this.groupBy,
    this.orderBy = const [],
    this.limit,
    this.offset,
    this.distinct = false,
  });

  /// Derived from this with the given clauses replaced; nulls keep the
  /// current value. Lists are copied.
  SelectStatement copyWith({
    List<Expression>? columns,
    List<JoinClause>? joins,
    Expression? where,
    Grouping? groupBy,
    List<OrderBy>? orderBy,
    int? limit,
    int? offset,
    bool? distinct,
  }) => SelectStatement(
    columns: columns == null ? this.columns : List.of(columns),
    from: from,
    joins: joins == null ? this.joins : List.of(joins),
    where: where ?? this.where,
    groupBy: groupBy ?? this.groupBy,
    orderBy: orderBy == null ? this.orderBy : List.of(orderBy),
    limit: limit ?? this.limit,
    offset: offset ?? this.offset,
    distinct: distinct ?? this.distinct,
  );

  @override
  void writeTo(SqlFragment fragment) {
    fragment.write('SELECT ');
    if (distinct) fragment.write('DISTINCT ');

    if (columns.isEmpty) {
      fragment.write('*');
    } else {
      for (var i = 0; i < columns.length; i++) {
        if (i > 0) fragment.write(', ');
        columns[i].writeTo(fragment);
      }
    }

    final source = from;
    if (source != null) {
      fragment.write(' FROM ');
      source.writeTo(fragment);
    }

    for (final join in joins) {
      fragment.write(' ${join.kind.sql} ');
      join.source.writeTo(fragment);
      final on = join.on;
      if (on != null) {
        fragment.write(' ON ');
        on.writeTo(fragment);
      }
    }

    final filter = where;
    if (filter != null) {
      fragment.write(' WHERE ');
      filter.writeTo(fragment);
    }

    final grouping = groupBy;
    if (grouping != null) {
      fragment.write(' GROUP BY ');
      for (var i = 0; i < grouping.expressions.length; i++) {
        if (i > 0) fragment.write(', ');
        grouping.expressions[i].writeTo(fragment);
      }
      final having = grouping.having;
      if (having != null) {
        fragment.write(' HAVING ');
        having.writeTo(fragment);
      }
    }

    if (orderBy.isNotEmpty) {
      fragment.write(' ORDER BY ');
      for (var i = 0; i < orderBy.length; i++) {
        if (i > 0) fragment.write(', ');
        final key = orderBy[i];
        key.expression.writeTo(fragment);
        fragment.write(' ${key.order.sql}');
      }
    }

    final limitValue = limit;
    if (limitValue != null) {
      fragment.write(' LIMIT ');
      fragment.bind(limitValue);
    }

    final offsetValue = offset;
    if (offsetValue != null) {
      fragment.write(' OFFSET ');
      fragment.bind(offsetValue);
    }
  }
}

/// A `SELECT` used in a `FROM` position.
final class SubquerySource extends Source {
  /// The query rendered inside the parentheses.
  final SelectStatement inner;

  /// Wraps [inner] as a `FROM` source.
  const SubquerySource(this.inner);

  @override
  void writeTo(SqlFragment fragment) {
    fragment.write('(');
    inner.writeTo(fragment);
    fragment.write(')');
  }
}

/// An `INSERT` that writes one or more rows.
final class InsertStatement extends Statement {
  /// The table the rows are written to.
  final TableSource target;

  /// The column names, quoted as identifiers.
  final List<String> columns;

  /// The rows of values, one bound parameter per cell.
  final List<List<Object?>> rows;

  /// The `ON CONFLICT` clause, if any.
  final ConflictClause? onConflict;

  /// A `null` value omits the clause; an empty list means `*`.
  final List<Expression>? returning;

  /// Builds an `INSERT` of [rows] into [columns].
  const InsertStatement(
    this.target,
    this.columns,
    this.rows, {
    this.onConflict,
    this.returning,
  });

  /// Builds an `INSERT` of a single row.
  factory InsertStatement.one(
    TableSource target,
    List<String> columns,
    List<Object?> values, {
    ConflictClause? onConflict,
    List<Expression>? returning,
  }) => InsertStatement(
    target,
    columns,
    [values],
    onConflict: onConflict,
    returning: returning,
  );

  @override
  void writeTo(SqlFragment fragment) {
    fragment.write('INSERT INTO ');
    target.writeTo(fragment);
    fragment.write(' (');
    for (var i = 0; i < columns.length; i++) {
      if (i > 0) fragment.write(', ');
      fragment.writeIdentifier(columns[i]);
    }
    fragment.write(') VALUES ');
    for (var r = 0; r < rows.length; r++) {
      if (r > 0) fragment.write(', ');
      fragment.write('(');
      final row = rows[r];
      for (var c = 0; c < row.length; c++) {
        if (c > 0) fragment.write(', ');
        fragment.bind(row[c]);
      }
      fragment.write(')');
    }
    onConflict?.writeTo(fragment);
    _writeReturning(fragment, returning);
  }
}

/// An `ON CONFLICT` clause.
final class ConflictClause {
  /// The conflict target columns, quoted as identifiers.
  final List<String> targetColumns;

  /// The columns assigned by `DO UPDATE SET`.
  final Map<String, Object?> updates;

  /// Whether the clause is `DO NOTHING` instead of an update.
  final bool doNothing;

  /// Builds an `ON CONFLICT` clause.
  const ConflictClause({
    this.targetColumns = const [],
    this.updates = const {},
    this.doNothing = false,
  });

  /// Updates the given columns when [targetColumns] conflict.
  factory ConflictClause.update(
    List<String> targetColumns,
    Map<String, Object?> updates,
  ) => ConflictClause(targetColumns: targetColumns, updates: updates);

  /// Ignores conflicts with `ON CONFLICT DO NOTHING`.
  factory ConflictClause.ignore() => const ConflictClause(doNothing: true);

  /// Writes this clause's SQL to [fragment].
  void writeTo(SqlFragment fragment) {
    if (doNothing) {
      fragment.write(' ON CONFLICT DO NOTHING');
      return;
    }
    if (targetColumns.isEmpty) {
      fragment.write(' ON CONFLICT');
    } else {
      fragment.write(' ON CONFLICT (');
      for (var i = 0; i < targetColumns.length; i++) {
        if (i > 0) fragment.write(', ');
        fragment.writeIdentifier(targetColumns[i]);
      }
      fragment.write(')');
    }
    fragment.write(' DO UPDATE SET ');
    var first = true;
    updates.forEach((column, value) {
      if (!first) fragment.write(', ');
      first = false;
      fragment.writeIdentifier(column);
      fragment.write(' = ');
      _writeValue(fragment, value);
    });
  }
}

/// An `UPDATE` of one or more columns.
final class UpdateStatement extends Statement {
  /// The table being updated.
  final TableSource target;

  /// The columns and their new values; each value binds unless it is an
  /// [Expression].
  final Map<String, Object?> values;

  /// The `WHERE` predicate restricting the rows, if any.
  final Expression? where;

  /// A `null` value omits the clause; an empty list means `*`.
  final List<Expression>? returning;

  /// Builds an `UPDATE` of [values] on [target].
  const UpdateStatement(this.target, this.values, [this.where, this.returning]);

  @override
  void writeTo(SqlFragment fragment) {
    fragment.write('UPDATE ');
    target.writeTo(fragment);
    fragment.write(' SET ');
    var first = true;
    values.forEach((column, value) {
      if (!first) fragment.write(', ');
      first = false;
      fragment.writeIdentifier(column);
      fragment.write(' = ');
      _writeValue(fragment, value);
    });
    final filter = where;
    if (filter != null) {
      fragment.write(' WHERE ');
      filter.writeTo(fragment);
    }
    _writeReturning(fragment, returning);
  }
}

/// A `null` [where] deletes every row.
final class DeleteStatement extends Statement {
  /// The table rows are deleted from.
  final TableSource target;

  /// The `WHERE` predicate restricting the deletion, if any.
  final Expression? where;

  /// A `null` value omits the clause; an empty list means `*`.
  final List<Expression>? returning;

  /// Builds a `DELETE` on [target].
  const DeleteStatement(this.target, [this.where, this.returning]);

  @override
  void writeTo(SqlFragment fragment) {
    fragment.write('DELETE FROM ');
    target.writeTo(fragment);
    final filter = where;
    if (filter != null) {
      fragment.write(' WHERE ');
      filter.writeTo(fragment);
    }
    _writeReturning(fragment, returning);
  }
}

/// A `CREATE TABLE` statement.
final class CreateTableStatement extends Statement {
  /// The table being created.
  final TableSource target;

  /// Pre-rendered SQL definitions, not quoted here.
  final List<String> columnDefinitions;

  /// Whether `IF NOT EXISTS` is emitted.
  final bool ifNotExists;

  /// Builds a `CREATE TABLE` from pre-rendered [columnDefinitions].
  const CreateTableStatement(
    this.target,
    this.columnDefinitions, {
    this.ifNotExists = true,
  });

  @override
  void writeTo(SqlFragment fragment) {
    fragment.write('CREATE TABLE ');
    if (ifNotExists) fragment.write('IF NOT EXISTS ');
    target.writeTo(fragment);
    fragment.write(' (');
    for (var i = 0; i < columnDefinitions.length; i++) {
      if (i > 0) fragment.write(', ');
      fragment.write(columnDefinitions[i]);
    }
    fragment.write(')');
  }
}
