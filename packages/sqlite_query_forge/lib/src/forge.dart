import 'clause.dart';
import 'executor.dart';
import 'statement.dart';
import 'table.dart';
import 'write_builder.dart';

/// The entry point bound to one [ForgeExecutor]: reads, writes and
/// transactions all start here.
final class Forge {
  /// Binds the forge to a [ForgeExecutor].
  Forge(this._executor);

  Forge._scope(this._executor, this._open);

  final ForgeExecutor _executor;

  ForgeExecutor? _open;

  ForgeExecutor get _bound => _open ?? _executor;

  /// Starts a query returning rows mapped by [table]'s own mapper.
  SelectBuilder<T> selectFrom<T extends Object>(Table<T> table) =>
      SelectBuilder<T>(
        SelectStatement(from: table.source),
        table.mapper,
        _bound,
      );

  /// Starts a query from a raw source, untyped until [SelectBuilder.map].
  SelectBuilder<T> selectFromSource<T extends Object>(
    Source source,
    T Function(Map<String, Object?> row) mapper,
  ) => SelectBuilder<T>(SelectStatement(from: source), mapper, _bound);

  /// Starts an `INSERT` into [table].
  InsertBuilder insertInto(Table<Object> table) =>
      InsertBuilder(table.source, _bound);

  /// Starts an `UPDATE` against [table].
  UpdateBuilder update(Table<Object> table) =>
      UpdateBuilder(table.source, _bound);

  /// Starts a `DELETE` from [table].
  DeleteBuilder deleteFrom(Table<Object> table) =>
      DeleteBuilder(table.source, _bound);

  /// Compiles [statement] and returns the rows it produces.
  Future<List<Map<String, Object?>>> query(Statement statement) async {
    final compiled = statement.compile();
    return _bound.query(compiled.sql, compiled.args);
  }

  /// Compiles [statement] and returns the affected row count.
  Future<int> execute(Statement statement) async {
    final compiled = statement.compile();
    return _bound.execute(compiled.sql, compiled.args);
  }

  /// Compiles [statement] and returns the new rowid.
  Future<int> insert(Statement statement) async {
    final compiled = statement.compile();
    return _bound.insert(compiled.sql, compiled.args);
  }

  /// Runs [action] inside a transaction, rolling back if it throws.
  ///
  /// A nested call joins the transaction already open on this [Forge], so it
  /// issues no second `BEGIN`.
  Future<R> transaction<R>(Future<R> Function(Forge txn) action) {
    final open = _open;
    if (open != null) return action(Forge._scope(_executor, open));

    return _executor.transaction((txn) {
      final scope = Forge._scope(_executor, txn);
      _open = txn;
      return action(scope).whenComplete(() => _open = null);
    });
  }
}
