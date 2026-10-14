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

sealed class Statement {
  const Statement();

  bool get isQuery => this is SelectStatement;

  CompiledQuery compile() {
    final fragment = SqlFragment();
    writeTo(fragment);
    return CompiledQuery(fragment.sql, fragment.args);
  }

  void writeTo(SqlFragment fragment);
}

final class SelectStatement extends Statement {
  /// Empty means `*`.
  final List<Expression> columns;
  final Source? from;
  final List<JoinClause> joins;
  final Expression? where;
  final Grouping? groupBy;
  final List<OrderBy> orderBy;
  final int? limit;
  final int? offset;
  final bool distinct;

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
  final SelectStatement inner;

  const SubquerySource(this.inner);

  @override
  void writeTo(SqlFragment fragment) {
    fragment.write('(');
    inner.writeTo(fragment);
    fragment.write(')');
  }
}

final class InsertStatement extends Statement {
  final TableSource target;
  final List<String> columns;
  final List<List<Object?>> rows;
  final ConflictClause? onConflict;

  /// A `null` value omits the clause; an empty list means `*`.
  final List<Expression>? returning;

  const InsertStatement(
    this.target,
    this.columns,
    this.rows, {
    this.onConflict,
    this.returning,
  });

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

final class ConflictClause {
  final List<String> targetColumns;
  final Map<String, Object?> updates;
  final bool doNothing;

  const ConflictClause({
    this.targetColumns = const [],
    this.updates = const {},
    this.doNothing = false,
  });

  factory ConflictClause.update(
    List<String> targetColumns,
    Map<String, Object?> updates,
  ) => ConflictClause(targetColumns: targetColumns, updates: updates);

  factory ConflictClause.ignore() => const ConflictClause(doNothing: true);

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

final class UpdateStatement extends Statement {
  final TableSource target;
  final Map<String, Object?> values;
  final Expression? where;

  /// A `null` value omits the clause; an empty list means `*`.
  final List<Expression>? returning;

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
  final TableSource target;
  final Expression? where;

  /// A `null` value omits the clause; an empty list means `*`.
  final List<Expression>? returning;

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

final class CreateTableStatement extends Statement {
  final TableSource target;

  /// Pre-rendered SQL definitions, not quoted here.
  final List<String> columnDefinitions;
  final bool ifNotExists;

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
