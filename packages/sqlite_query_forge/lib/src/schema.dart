/// Bridges a declared [Table] into a migration schema, so queries and
/// migrations share one declaration.
///
/// The migration types are aliased to `Schema*` names so a table declaration
/// never has to import the schema package, whose own `Column` and `Table`
/// collide with the query side's.
library;

import 'package:sqlite_schema_forge/sqlite_schema_forge.dart' as schema;

import 'executor.dart';

typedef SchemaColumn = schema.Column;

typedef SchemaTable = schema.Table;

typedef SchemaDataType = schema.DataType;

typedef SchemaRawSql = schema.RawSql;

typedef MigrationSchema = schema.Schema;

/// A [ForgeExecutor] presented as a `DatabaseExecutor`, so one driver adapter
/// serves both the query builder and the migrator.
final class ForgeDatabaseExecutor implements schema.DatabaseExecutor {
  ForgeDatabaseExecutor(this._executor);

  final ForgeExecutor _executor;

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => _executor.query(sql, arguments);

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    await _executor.execute(sql, arguments);
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(schema.DatabaseExecutor txn) action,
  ) => _executor.transaction((txn) => action(ForgeDatabaseExecutor(txn)));
}
