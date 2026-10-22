import 'dart:typed_data';

/// What a traced statement did.
enum SqlTraceKind {
  /// A statement that returned rows (`SELECT`).
  select,

  /// A statement that changed rows (`UPDATE`, `DELETE`, DDL).
  execute,

  /// An `INSERT` that returned a new row id.
  insert,
}

/// A record of one statement that reached the database.
///
/// The driver hands one of these to the [SqlTraceSink] in
/// [SqliteDriverConfig.onTrace] after the statement settles, whether it
/// succeeded or failed. It carries the statement as it was executed, the
/// rows it returned, the rows it changed and how long it took.
///
/// A trace holds the **full** result set and the **full** parameter list.
/// [formatSqlTrace] trims them for display; a sink that stores traces
/// somewhere should decide for itself what to keep.
final class SqlTrace {
  /// The SQL text that was executed, verbatim.
  final String sql;

  /// The parameters bound to the statement, in order.
  final List<Object?> args;

  /// What the statement did.
  final SqlTraceKind kind;

  /// The rows the statement returned; empty for statements that return none.
  final List<Map<String, Object?>> rows;

  /// The number of rows the statement changed, when it changed any.
  final int? affectedRows;

  /// The row id of the inserted row, for an [SqlTraceKind.insert].
  final int? lastInsertId;

  /// How long the statement took, including the round trip to the worker
  /// isolate.
  final Duration duration;

  /// The failure that ended the statement, or `null` when it succeeded.
  final Object? error;

  /// Where [error] was raised.
  final StackTrace? stackTrace;

  /// Creates a trace of one executed statement.
  const SqlTrace({
    required this.sql,
    required this.args,
    required this.kind,
    this.rows = const <Map<String, Object?>>[],
    this.affectedRows,
    this.lastInsertId,
    required this.duration,
    this.error,
    this.stackTrace,
  });

  /// Whether the statement failed.
  bool get failed => error != null;

  /// The number of rows the statement returned.
  int get returnedRows => rows.length;

  @override
  String toString() => formatSqlTrace(this);
}

/// Receives one trace per executed statement.
///
/// A sink is called on the isolate that issued the statement, after it
/// settles, so a sink that prints shows the output in the app's debug
/// console.
typedef SqlTraceSink = void Function(SqlTrace trace);

/// Prints a trace to the debug console.
///
/// ```dart
/// final driver = SqliteDriver.file(
///   '/data/app.db',
///   onTrace: const ConsoleSqlTrace(),
/// );
/// ```
///
/// The output is trimmed for reading: the SQL is cut at [maxSqlLength]
/// characters, the parameters and the cells at [maxValueLength], and only
/// the first [maxRows] rows are shown — the reported count is always the
/// true one.
final class ConsoleSqlTrace {
  /// Creates a sink that prints traces.
  const ConsoleSqlTrace({
    this.maxRows = 3,
    this.maxValueLength = 40,
    this.maxSqlLength = 500,
  });

  /// How many result rows are shown.
  final int maxRows;

  /// How many characters a parameter or a cell is cut to.
  final int maxValueLength;

  /// How many characters the SQL is cut to.
  final int maxSqlLength;

  /// Prints [trace] to the debug console.
  void call(SqlTrace trace) {
    print(
      formatSqlTrace(
        trace,
        maxRows: maxRows,
        maxValueLength: maxValueLength,
        maxSqlLength: maxSqlLength,
      ),
    );
  }
}

/// Renders [trace] as a block of text.
///
/// The first line carries the statement and its parameters, the second the
/// outcome — rows returned, rows affected, or the failure — and the rest
/// the trimmed result.
///
/// ```text
/// [sql] SELECT "u"."id" FROM "users" AS "u" WHERE "u"."age" > ? args: [30]
///       → 12 rows returned in 2.1ms
///       [{id: 1}, {id: 2}, {id: 3}]
/// ```
String formatSqlTrace(
  SqlTrace trace, {
  int maxRows = 3,
  int maxValueLength = 40,
  int maxSqlLength = 500,
}) {
  final buffer = StringBuffer();
  final sql = _cut(trace.sql, maxSqlLength);
  final args = trace.args.isEmpty
      ? ''
      : ' args: [${trace.args.map((Object? a) => _formatValue(a, maxValueLength)).join(', ')}]';
  buffer.write('[sql] $sql$args');

  if (trace.failed) {
    buffer.write(
      '\n      → FAILED in ${_formatDuration(trace.duration)}: ${trace.error}',
    );
    return buffer.toString();
  }

  final outcome = switch (trace.kind) {
    SqlTraceKind.select => '${_plural(trace.returnedRows, 'row')} returned',
    SqlTraceKind.execute =>
      '${_plural(trace.affectedRows ?? 0, 'row')} affected',
    SqlTraceKind.insert =>
      '${_plural(trace.affectedRows ?? 0, 'row')} affected, last id ${trace.lastInsertId ?? 0}',
  };
  buffer.write('\n      → $outcome in ${_formatDuration(trace.duration)}');

  if (trace.kind == SqlTraceKind.select && trace.rows.isNotEmpty) {
    final shown = trace.rows.take(maxRows).toList();
    final rendered = shown
        .map(
          (Map<String, Object?> row) =>
              '{${row.entries.map((MapEntry<String, Object?> e) => '${e.key}: ${_formatValue(e.value, maxValueLength)}').join(', ')}}',
        )
        .join(', ');
    final more = trace.rows.length - shown.length;
    buffer.write('\n      $rendered${more > 0 ? ', …$more more' : ''}');
  }

  return buffer.toString();
}

/// Formats a count with a correctly pluralized noun.
String _plural(int count, String noun) =>
    '$count $noun${count == 1 ? '' : 's'}';

/// Formats one bound value for display.
String _formatValue(Object? value, int maxLength) {
  if (value == null) return 'null';
  if (value is String) return _cut("'$value'", maxLength);
  if (value is Uint8List) return '<blob ${value.length} bytes>';
  if (value is List) return '<list ${value.length} items>';
  if (value is Map) return '<map ${value.length} keys>';
  return _cut(value.toString(), maxLength);
}

/// Cuts [text] to [maxLength] characters, marking the cut.
String _cut(String text, int maxLength) {
  if (maxLength <= 0 || text.length <= maxLength) return text;
  return '${text.substring(0, maxLength - 1)}…';
}

/// Formats a duration in the unit that reads best.
String _formatDuration(Duration duration) {
  final micros = duration.inMicroseconds;
  if (micros < 1000) return '$microsµs';
  if (micros < 1000000) return '${(micros / 1000).toStringAsFixed(1)}ms';
  return '${(micros / 1000000).toStringAsFixed(2)}s';
}
