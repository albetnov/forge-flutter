import 'clause.dart';
import 'executor.dart';
import 'expression.dart';
import 'statement.dart';

/// `AND` binds tighter than `OR`, so a disjunction needs parens before it is
/// conjoined.
Expression _asConjunct(Expression operand) =>
    operand is Disjunction ? operand.parenthesized : operand;

ForgeExecutor _requireExecutor(ForgeExecutor? executor, String builder) {
  if (executor == null) {
    throw StateError(
      'No executor. Build writes through a Forge instead of constructing a '
      '$builder directly.',
    );
  }
  return executor;
}

int _asRowid(Object? value) => switch (value) {
  int rowid => rowid,
  num rowid => rowid.toInt(),
  _ => throw StateError('Expected a rowid, but got $value.'),
};

/// An `INSERT` chain. Immutable, so a chain can be built conditionally.
final class InsertBuilder {
  /// The table rows are inserted into.
  final TableSource target;

  final ForgeExecutor? _executor;

  final List<Map<String, Object?>> _rows;

  final ConflictClause? _onConflict;

  final List<Expression>? _returning;

  /// Binds the builder to [target], optionally with an executor.
  InsertBuilder(this.target, [this._executor])
    : _rows = const [],
      _onConflict = null,
      _returning = null;

  InsertBuilder._(
    this.target,
    this._executor, {
    required this._rows,
    this._onConflict,
    this._returning,
  });

  /// Column order follows the map's own order.
  InsertBuilder values(Map<String, Object?> row) => InsertBuilder._(
    target,
    _executor,
    rows: [row],
    onConflict: _onConflict,
    returning: _returning,
  );

  /// Many rows in one statement. Every row must name the same columns, since
  /// SQLite takes a single column list for the whole `VALUES` list.
  InsertBuilder valuesAll(List<Map<String, Object?>> rows) => InsertBuilder._(
    target,
    _executor,
    rows: List.of(rows),
    onConflict: _onConflict,
    returning: _returning,
  );

  /// Turns conflicts into `ON CONFLICT DO NOTHING`.
  InsertBuilder onConflictIgnore() => InsertBuilder._(
    target,
    _executor,
    rows: _rows,
    onConflict: ConflictClause.ignore(),
    returning: _returning,
  );

  /// [updates] may hold an [Expression] to write a reference rather than a
  /// bound value, which is how `excluded."email"` is spelled.
  InsertBuilder onConflictUpdate(
    Map<String, Object?> updates, {
    List<Column<Object>>? columns,
  }) => InsertBuilder._(
    target,
    _executor,
    rows: _rows,
    onConflict: ConflictClause.update(
      columns?.map((column) => column.name).toList(growable: false) ?? const [],
      updates,
    ),
    returning: _returning,
  );

  /// Needs SQLite 3.35 or newer, and turns the write into a read: [getMany]
  /// returns the affected rows instead of [execute] returning a rowid. With no
  /// [columns] it emits `RETURNING *`.
  InsertBuilder returning([List<Expression> columns = const []]) =>
      InsertBuilder._(
        target,
        _executor,
        rows: _rows,
        onConflict: _onConflict,
        returning: List.of(columns),
      );

  /// The compiled `INSERT`.
  CompiledQuery compile() => _statement().compile();

  /// The new rowid.
  Future<int> execute() {
    if (_returning != null) {
      throw StateError('A returning insert yields rows; call getMany().');
    }
    final compiled = compile();
    final executor = _requireExecutor(_executor, 'InsertBuilder');
    return executor.insert(compiled.sql, compiled.args);
  }

  /// Runs a returning insert and reads the inserted rows.
  Future<List<Map<String, Object?>>> getMany() {
    if (_returning == null) {
      throw StateError('Call returning() before reading inserted rows.');
    }
    final compiled = compile();
    final executor = _requireExecutor(_executor, 'InsertBuilder');
    return executor.query(compiled.sql, compiled.args);
  }

  /// The rowid SQLite last assigned on this connection.
  ///
  /// Call it immediately after an insert on the same executor: the value is
  /// connection-wide, so any later insert replaces it.
  Future<int> getLastInsertId() async {
    final executor = _requireExecutor(_executor, 'InsertBuilder');
    final rows = await executor.query(_lastInsertId.sql, const []);
    if (rows.isEmpty) return 0;
    return _asRowid(rows.first.values.first);
  }

  static final CompiledQuery _lastInsertId = SelectStatement(
    columns: [const RawSql('last_insert_rowid()')],
  ).compile();

  InsertStatement _statement() {
    final rows = _rows;
    if (rows.isEmpty) {
      throw StateError('Call values() or valuesAll() before an insert.');
    }
    if (rows.first.isEmpty) {
      throw StateError('An inserted row needs at least one column.');
    }

    final columns = rows.first.keys.toSet();
    for (final row in rows) {
      if (row.length != columns.length || !row.keys.every(columns.contains)) {
        throw StateError('valuesAll() needs the same columns in every row.');
      }
    }

    final names = columns.toList(growable: false);
    return InsertStatement(
      target,
      names,
      [
        for (final row in rows) [for (final name in names) row[name]],
      ],
      onConflict: _onConflict,
      returning: _returning,
    );
  }
}

/// An `UPDATE` chain. Immutable, so a chain can be built conditionally.
final class UpdateBuilder {
  /// The table being updated.
  final TableSource target;

  final ForgeExecutor? _executor;

  final Map<String, Object?> _values;

  final Expression? _where;

  final List<Expression>? _returning;

  /// Binds the builder to [target], optionally with an executor.
  UpdateBuilder(this.target, [this._executor])
    : _values = const {},
      _where = null,
      _returning = null;

  UpdateBuilder._(
    this.target,
    this._executor, {
    this._values = const {},
    this._where,
    this._returning,
  });

  /// A value that is an [Expression] is written as a reference rather than
  /// bound.
  UpdateBuilder values(Map<String, Object?> values) {
    if (values.isEmpty) {
      throw StateError('values() needs at least one column to set.');
    }
    return UpdateBuilder._(
      target,
      _executor,
      values: values,
      where: _where,
      returning: _returning,
    );
  }

  /// A missing filter updates every row.
  UpdateBuilder where(Expression condition) => UpdateBuilder._(
    target,
    _executor,
    values: _values,
    where: condition,
    returning: _returning,
  );

  /// With no prior [UpdateBuilder.where] it behaves as [where].
  UpdateBuilder andWhere(Expression condition) {
    final current = _where;
    return UpdateBuilder._(
      target,
      _executor,
      values: _values,
      where: current == null
          ? condition
          : Conjunction(_asConjunct(current), _asConjunct(condition)),
      returning: _returning,
    );
  }

  /// With no prior [UpdateBuilder.where] it behaves as [where].
  UpdateBuilder orWhere(Expression condition) {
    final current = _where;
    return UpdateBuilder._(
      target,
      _executor,
      values: _values,
      where: current == null ? condition : Disjunction(current, condition),
      returning: _returning,
    );
  }

  /// Needs SQLite 3.35 or newer, and turns the write into a read: [getMany]
  /// returns the affected rows instead of [execute] returning a row count. With
  /// no [columns] it emits `RETURNING *`.
  UpdateBuilder returning([List<Expression> columns = const []]) =>
      UpdateBuilder._(
        target,
        _executor,
        values: _values,
        where: _where,
        returning: List.of(columns),
      );

  /// The compiled `UPDATE`.
  CompiledQuery compile() =>
      UpdateStatement(target, _values, _where, _returning).compile();

  /// The number of rows affected.
  Future<int> execute() {
    if (_returning != null) {
      throw StateError('A returning update yields rows; call getMany().');
    }
    final compiled = compile();
    final executor = _requireExecutor(_executor, 'UpdateBuilder');
    return executor.execute(compiled.sql, compiled.args);
  }

  /// Runs a returning update and reads the affected rows.
  Future<List<Map<String, Object?>>> getMany() {
    if (_returning == null) {
      throw StateError('Call returning() before reading updated rows.');
    }
    final compiled = compile();
    final executor = _requireExecutor(_executor, 'UpdateBuilder');
    return executor.query(compiled.sql, compiled.args);
  }
}

/// A `DELETE` chain. Immutable, so a chain can be built conditionally.
final class DeleteBuilder {
  /// The table rows are deleted from.
  final TableSource target;

  final ForgeExecutor? _executor;

  final Expression? _where;

  final List<Expression>? _returning;

  /// Binds the builder to [target], optionally with an executor.
  DeleteBuilder(this.target, [this._executor])
    : _where = null,
      _returning = null;
  DeleteBuilder._(this.target, this._executor, {this._where, this._returning});

  /// A missing filter deletes every row.
  DeleteBuilder where(Expression condition) =>
      DeleteBuilder._(target, _executor, where: condition, returning: _returning);

  /// With no prior [DeleteBuilder.where] it behaves as [where].
  DeleteBuilder andWhere(Expression condition) {
    final current = _where;
    return DeleteBuilder._(
      target,
      _executor,
      where: current == null
          ? condition
          : Conjunction(_asConjunct(current), _asConjunct(condition)),
      returning: _returning,
    );
  }

  /// With no prior [DeleteBuilder.where] it behaves as [where].
  DeleteBuilder orWhere(Expression condition) {
    final current = _where;
    return DeleteBuilder._(
      target,
      _executor,
      where: current == null ? condition : Disjunction(current, condition),
      returning: _returning,
    );
  }

  /// Needs SQLite 3.35 or newer, and turns the write into a read: [getMany]
  /// returns the affected rows instead of [execute] returning a row count. With
  /// no [columns] it emits `RETURNING *`.
  DeleteBuilder returning([List<Expression> columns = const []]) =>
      DeleteBuilder._(
        target,
        _executor,
        where: _where,
        returning: List.of(columns),
      );

  /// The compiled `DELETE`.
  CompiledQuery compile() =>
      DeleteStatement(target, _where, _returning).compile();

  /// The number of rows deleted.
  Future<int> execute() {
    if (_returning != null) {
      throw StateError('A returning delete yields rows; call getMany().');
    }
    final compiled = compile();
    final executor = _requireExecutor(_executor, 'DeleteBuilder');
    return executor.execute(compiled.sql, compiled.args);
  }

  /// Runs a returning delete and reads the affected rows.
  Future<List<Map<String, Object?>>> getMany() {
    if (_returning == null) {
      throw StateError('Call returning() before reading deleted rows.');
    }
    final compiled = compile();
    final executor = _requireExecutor(_executor, 'DeleteBuilder');
    return executor.query(compiled.sql, compiled.args);
  }
}
