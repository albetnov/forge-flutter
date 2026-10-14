/// Abstract executor interface so SqliteSchemaForge works with sqflite,
/// sqlite3, or drift.
abstract interface class DatabaseExecutor {
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]);

  Future<void> execute(String sql, [List<Object?>? arguments]);

  Future<T> transaction<T>(Future<T> Function(DatabaseExecutor txn) action);
}
