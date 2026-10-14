import 'package:sqlite_schema_forge/sqlite_schema_forge.dart';

/// Fake Stub
class Database implements DatabaseExecutor {
  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) {
    // TODO: implement execute
    throw UnimplementedError();
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) {
    // TODO: implement rawQuery
    throw UnimplementedError();
  }

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseExecutor txn) action) {
    // TODO: implement transaction
    throw UnimplementedError();
  }
}

void main() async {
  final appSchema = Schema(
    version: 1,
    tables: [
      Table(
        'wallets',
        [
          Column.id(),
          Column.text('name', nullable: false),
          Column.integer('wallet_type_id', nullable: false),
          Column.integer('is_deleted', nullable: false, defaultValue: 0),
          Column.datetime('created_at', defaultValue: RawSql.currentTimestamp),
          Column.datetime('updated_at', defaultValue: RawSql.currentTimestamp),
        ],
        indexes: [
          Index(columns: ['wallet_type_id']),
        ],
      ),
    ],
  );

  final db = Database();

  SqliteSchemaForge.enableForeignKeys(db);

  final result = await SqliteSchemaForge.migrate(
    db: db,
    targetSchema: appSchema,
  );

  print(result.executedSql);
  print(result.migrated);
}
