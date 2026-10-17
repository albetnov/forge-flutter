/// The execution contract the query forge needs from a SQLite driver.
///
/// The package ships no driver. Implement this over whichever binding you
/// already use and hand it to a [Forge].
abstract interface class ForgeExecutor {
  /// Runs a query and returns the rows as maps of column name to value.
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?>? args]);

  /// Runs a statement returning affected row count.
  Future<int> execute(String sql, [List<Object?>? args]);

  /// Runs an `INSERT` and returns the new rowid.
  Future<int> insert(String sql, [List<Object?>? args]);

  /// Runs [action] in a transaction, rolling back if it throws.
  Future<T> transaction<T>(Future<T> Function(ForgeExecutor txn) action);
}

/// Thrown when a single-row query returns zero or more than one row.
class ForgeCardinalityError extends StateError {
  /// Number of rows actually returned.
  final int actual;

  /// Reports that [actual] rows were returned where exactly one was expected.
  ForgeCardinalityError(this.actual)
    : super(
        actual == 0
            ? 'Expected exactly 1 row, but the query returned none.'
            : 'Expected exactly 1 row, but the query returned $actual.',
      );
}
