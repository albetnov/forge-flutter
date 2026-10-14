/// Base for a typed table schema. An immutable, const-constructible
/// descriptor.
library;

import 'clause.dart';
import 'expression.dart';
import 'executor.dart';
import 'schema.dart';
import 'statement.dart';

abstract class Table<T extends Object> {
  /// Named `tableName` so subclasses are free to declare `Column` getters
  /// such as `name` without colliding.
  final String tableName;

  final T Function(Map<String, Object?> row) mapper;

  const Table(this.tableName, {required this.mapper});

  TableSource get source => TableSource(tableName);

  TableSource sourceAs([String? alias]) => TableSource(tableName, alias);

  /// Qualifies [column] against this table, or its [alias].
  QualifiedColumn<R> qualify<R extends Object>(
    Column<R> column, [
    String? alias,
  ]) => QualifiedColumn<R>(alias ?? tableName, column.name);

  List<T> mapRows(List<Map<String, Object?>> rows) =>
      rows.map(mapper).toList(growable: false);

  /// The table's columns, for the migrator. Empty on tables that only take part
  /// in queries.
  List<Column<Object>> get columns => const [];

  /// The table as the migrator sees it.
  SchemaTable toSchemaTable() {
    final tableColumns = columns;
    if (tableColumns.isEmpty) {
      throw StateError(
        '$tableName declares no columns, so it cannot be created.',
      );
    }
    return SchemaTable(tableName, [
      for (final column in tableColumns) _toSchemaColumn(column),
    ]);
  }
}

/// A default of [RawSql] becomes the schema package's, so
/// `CURRENT_TIMESTAMP` is written verbatim rather than quoted.
SchemaColumn _toSchemaColumn(Column<Object> column) {
  final type = column.type;
  if (type == null) {
    throw StateError(
      "Column '${column.name}' declares no type. Build it with Column.integer, "
      'Column.text, Column.real or Column.blob to make it migratable.',
    );
  }

  return SchemaColumn(
    name: column.name,
    type: switch (type) {
      ColumnType.integer => SchemaDataType.integer,
      ColumnType.text => SchemaDataType.text,
      ColumnType.real => SchemaDataType.real,
      ColumnType.blob => SchemaDataType.blob,
    },
    primaryKey: column.primaryKey,
    autoIncrement: column.autoIncrement,
    nullable: column.nullable,
    unique: column.unique,
    defaultValue: column.defaultValue is RawSql
        ? SchemaRawSql((column.defaultValue as RawSql).sql)
        : column.defaultValue,
    referencesTable: column.referencesTable,
    referencesColumn: column.referencesColumn,
  );
}

/// Builds the migration schema from the tables' own declarations.
///
/// Every table in [tables] must declare [Table.columns], since a table with no
/// columns cannot be created.
MigrationSchema schemaOf({
  required int version,
  required List<Table<Object>> tables,
}) => MigrationSchema(
  version: version,
  tables: [for (final table in tables) table.toSchemaTable()],
);

/// An immutable, chainable query. [T] is the *result* type, and only [map]
/// changes it.
final class SelectBuilder<T extends Object> {
  final SelectStatement statement;

  final T Function(Map<String, Object?> row)? _mapper;

  final ForgeExecutor? _executor;

  SelectBuilder(this.statement, [this._mapper, this._executor]);

  /// Alias needed because a bare `COUNT(*)` is keyed by its own expression
  /// text by some drivers.
  static final Expression _countAll = Aggregate('COUNT', [
    const RawSql('*'),
  ]).alias('count');

  SelectBuilder<T> _derive(SelectStatement next) =>
      SelectBuilder<T>(next, _mapper, _executor);

  /// `AND` binds tighter than `OR`, so a disjunction needs parens before it is
  /// conjoined.
  static Expression _asConjunct(Expression operand) =>
      operand is Disjunction ? operand.parenthesized : operand;

  SelectBuilder<T> _join(JoinKind kind, Source source, Expression? on) =>
      _derive(
        statement.copyWith(
          joins: [...statement.joins, JoinClause(kind, source, on)],
        ),
      );

  // ---- projections -------------------------------------------------------

  SelectBuilder<T> select(List<Expression> columns) =>
      _derive(statement.copyWith(columns: List<Expression>.of(columns)));

  SelectBuilder<T> distinct({bool value = true}) =>
      _derive(statement.copyWith(distinct: value));

  // ---- filters -----------------------------------------------------------

  SelectBuilder<T> where(Expression condition) =>
      _derive(statement.copyWith(where: condition));

  /// With no prior [SelectBuilder.where] it behaves as [where].
  SelectBuilder<T> andWhere(Expression condition) {
    final current = statement.where;
    return _derive(
      current == null
          ? statement.copyWith(where: condition)
          : statement.copyWith(
              where: Conjunction(_asConjunct(current), _asConjunct(condition)),
            ),
    );
  }

  /// With no prior [SelectBuilder.where] it behaves as [where].
  SelectBuilder<T> orWhere(Expression condition) {
    final current = statement.where;
    return _derive(
      current == null
          ? statement.copyWith(where: condition)
          : statement.copyWith(where: Disjunction(current, condition)),
    );
  }

  // ---- grouping ----------------------------------------------------------

  SelectBuilder<T> groupBy(List<Expression> expressions) {
    if (expressions.isEmpty) {
      throw StateError('groupBy() needs at least one expression.');
    }
    return _derive(statement.copyWith(groupBy: Grouping(expressions)));
  }

  SelectBuilder<T> having(Expression condition) {
    final grouping = statement.groupBy;
    if (grouping == null) {
      throw StateError('having() requires a preceding groupBy().');
    }
    return _derive(
      statement.copyWith(groupBy: Grouping(grouping.expressions, condition)),
    );
  }

  // ---- ordering and paging ----------------------------------------------

  /// Replaces the sort keys. See also [thenBy].
  SelectBuilder<T> orderBy(List<OrderBy> keys) =>
      _derive(statement.copyWith(orderBy: keys));

  /// Appends a sort key after any already set.
  SelectBuilder<T> thenBy(
    Expression expression, [
    SortOrder order = SortOrder.asc,
  ]) => _derive(
    statement.copyWith(
      orderBy: [...statement.orderBy, OrderBy(expression, order)],
    ),
  );

  SelectBuilder<T> limit(int count) =>
      _derive(statement.copyWith(limit: count));

  SelectBuilder<T> offset(int count) =>
      _derive(statement.copyWith(offset: count));

  // ---- joins -------------------------------------------------------------

  SelectBuilder<T> join(Source source, {required Expression on}) =>
      _join(JoinKind.inner, source, on);

  SelectBuilder<T> leftJoin(Source source, {required Expression on}) =>
      _join(JoinKind.left, source, on);

  SelectBuilder<T> crossJoin(Source source) =>
      _join(JoinKind.cross, source, null);

  // ---- result mapping ----------------------------------------------------

  /// Re-types the builder around [mapper], which receives the raw row map.
  SelectBuilder<R> map<R extends Object>(
    R Function(Map<String, Object?> row) mapper,
  ) => SelectBuilder<R>(statement, mapper, _executor);

  // ---- terminals ---------------------------------------------------------

  /// The compiled SQL, no executor required.
  CompiledQuery compile() => statement.compile();

  Future<List<T>> getMany() async {
    final rows = await _run();
    final mapper = _mapper;
    if (mapper == null) {
      throw StateError(
        'No row mapper. Build the query through Forge.selectFrom() so the '
        'table mapper is attached.',
      );
    }
    return rows.map(mapper).toList(growable: false);
  }

  /// Throws [ForgeCardinalityError] on 0 or >1 rows. Asks for 2 rows, since
  /// that is enough to tell 0 / 1 / more apart.
  Future<T> getSingle() async {
    final query = statement.limit == null ? limit(2) : this;
    final rows = await query._run();
    if (rows.length != 1) throw ForgeCardinalityError(rows.length);
    return _mapper!(rows.first);
  }

  /// The first row, or `null`. Applies `LIMIT 1` unless the caller set a limit.
  Future<T?> getFirst() async {
    final query = statement.limit == null ? limit(1) : this;
    final rows = await query._run();
    final mapper = _mapper;
    if (rows.isEmpty) return null;
    if (mapper == null) {
      throw StateError(
        'No row mapper. Build the query through Forge.selectFrom() so the '
        'table mapper is attached.',
      );
    }
    return mapper(rows.first);
  }

  /// The number of rows this query matches, without transferring them. A
  /// grouped or `DISTINCT` query is wrapped as a subquery.
  Future<int> count() async {
    final from = statement.from;
    if (from == null) {
      throw StateError('count() requires a FROM clause.');
    }

    final inner = statement;
    final bool needsSubquery = inner.groupBy != null || inner.distinct;
    final counting = needsSubquery
        ? SelectBuilder<T>(
            SelectStatement(
              from: SubquerySource(_stripSortAndPaging()),
              columns: [_countAll],
            ),
            _mapper,
            _executor,
          )
        : _derive(
            SelectStatement(
              from: from,
              joins: inner.joins,
              where: inner.where,
              columns: [_countAll],
            ),
          );

    final rows = await counting._run();
    if (rows.isEmpty) return 0;
    // A driver is free to key the column differently and some return a float.
    final counted = rows.first.values.first;
    return switch (counted) {
      int value => value,
      num value => value.toInt(),
      _ => throw StateError('count() got a non-numeric value: $counted'),
    };
  }

  Future<List<Map<String, Object?>>> _run() async {
    final executor = _executor;
    if (executor == null) {
      throw StateError(
        'No executor. Build queries through Forge.selectFrom() instead of '
        'constructing a SelectBuilder directly.',
      );
    }
    final compiled = statement.compile();
    return executor.query(compiled.sql, compiled.args);
  }

  SelectStatement _stripSortAndPaging() => SelectStatement(
    from: statement.from,
    columns: statement.columns,
    joins: statement.joins,
    where: statement.where,
    groupBy: statement.groupBy,
    distinct: statement.distinct,
  );
}
