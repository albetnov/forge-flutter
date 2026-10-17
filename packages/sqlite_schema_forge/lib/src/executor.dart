/// Abstract executor interface so SqliteSchemaForge works with sqflite,
/// sqlite3, or drift.
abstract interface class DatabaseExecutor {
  /// Runs [sql] and returns each row as a map keyed by column name, binding
  /// [arguments] in order when provided.
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]);

  /// Runs [sql] for its side effects, binding [arguments] in order when
  /// provided.
  Future<void> execute(String sql, [List<Object?>? arguments]);

  /// Runs [action] inside a transaction, passing it a [txn] executor. The
  /// transaction commits when [action] completes and rolls back on error.
  Future<T> transaction<T>(Future<T> Function(DatabaseExecutor txn) action);
}
