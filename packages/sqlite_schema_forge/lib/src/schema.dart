/// SQLite storage class of a [Column].
enum DataType {
  /// 64-bit signed integer (`INTEGER`).
  integer,

  /// Text (`TEXT`).
  text,

  /// 64-bit IEEE floating point (`REAL`).
  real,

  /// Uninterpreted bytes (`BLOB`).
  blob,
}

/// Identifiers cannot be bound, so they are quoted in exactly one place.
String _quote(String name) => '"${name.replaceAll('"', '""')}"';

/// Column definition
/// Prefer to use the factory helpers [Column.id], [Column.text], etc.
final class Column {
  /// Column name as written in SQL; quoted when rendered.
  final String name;

  /// Storage class of the column.
  final DataType type;

  /// Whether the column is the table's primary key.
  final bool primaryKey;

  /// Whether the primary key auto-increments (`AUTOINCREMENT`).
  final bool autoIncrement;

  /// Whether the column accepts `NULL`.
  final bool nullable;

  /// Whether values in the column must be unique.
  final bool unique;

  /// SQL default expression: a [String] is quoted, a [RawSql] is inlined
  /// verbatim, and numbers/booleans are emitted as-is.
  final Object? defaultValue;

  /// Table referenced by a foreign key, when set.
  final String? referencesTable;

  /// Column referenced by a foreign key, when set.
  final String? referencesColumn;

  /// Creates a column with explicit DDL flags.
  ///
  /// Prefer the named factories ([Column.id], [Column.text],
  /// [Column.integer], [Column.real], [Column.datetime]) for common cases.
  const Column({
    required this.name,
    required this.type,
    this.primaryKey = false,
    this.autoIncrement = false,
    this.nullable = true,
    this.unique = false,
    this.defaultValue,
    this.referencesTable,
    this.referencesColumn,
  });

  /// Factory helpers for conciseness
  factory Column.id([String name = 'id']) => Column(
    name: name,
    type: DataType.integer,
    primaryKey: true,
    autoIncrement: true,
    nullable: false,
  );

  /// Creates a `TEXT` column that is nullable by default, optionally [unique]
  /// or carrying a string [defaultValue].
  factory Column.text(
    String name, {
    bool nullable = true,
    bool unique = false,
    String? defaultValue,
  }) => Column(
    name: name,
    type: DataType.text,
    nullable: nullable,
    unique: unique,
    defaultValue: defaultValue,
  );

  /// Creates an `INTEGER` column, optionally a [primaryKey] that
  /// [autoIncrement]s, [unique], or a foreign key to [refTable].[refCol].
  factory Column.integer(
    String name, {
    bool primaryKey = false,
    bool autoIncrement = false,
    bool nullable = true,
    bool unique = false,
    int? defaultValue,
    String? refTable,
    String? refCol,
  }) => Column(
    name: name,
    type: DataType.integer,
    primaryKey: primaryKey,
    autoIncrement: autoIncrement,
    nullable: nullable,
    unique: unique,
    defaultValue: defaultValue,
    referencesTable: refTable,
    referencesColumn: refCol,
  );

  /// Creates a `REAL` column that is nullable by default, with an optional
  /// numeric [defaultValue].
  factory Column.real(
    String name, {
    bool nullable = true,
    double? defaultValue,
  }) => Column(
    name: name,
    type: DataType.real,
    nullable: nullable,
    defaultValue: defaultValue,
  );

  /// Creates a `TEXT` column for date/time values, with an optional
  /// [defaultValue] such as [RawSql.currentTimestamp] or `'2026-01-01'`.
  factory Column.datetime(
    String name, {
    bool nullable = true,
    Object? defaultValue, // e.g. RawSql.currentTimestamp or '2026-01-01'
  }) => Column(
    name: name,
    type: DataType.text,
    nullable: nullable,
    defaultValue: defaultValue,
  );

  String _formatDefaultValue() {
    if (defaultValue == null) return '';
    if (defaultValue is RawSql) return ' DEFAULT $defaultValue';
    if (defaultValue is String) return " DEFAULT '$defaultValue'";
    return ' DEFAULT $defaultValue';
  }

  /// Renders this column's `CREATE TABLE` fragment, quoting identifiers and
  /// never inlining runtime values.
  String toSql() {
    final sb = StringBuffer('${_quote(name)} ${type.name.toUpperCase()}');
    if (primaryKey) sb.write(' PRIMARY KEY');
    if (autoIncrement) sb.write(' AUTOINCREMENT');
    if (!nullable) sb.write(' NOT NULL');
    if (unique) sb.write(' UNIQUE');
    if (defaultValue != null) sb.write(_formatDefaultValue());
    final references = referencesTable;
    final referencesKey = referencesColumn;
    if (references != null && referencesKey != null) {
      sb.write(' REFERENCES ${_quote(references)}(${_quote(referencesKey)})');
    }
    return sb.toString();
  }
}

/// Index over one or more [columns] of a table.
final class Index {
  /// Explicit index name, or `null` to derive one from the table and columns.
  final String? name;

  /// Columns included in the index, in order.
  final List<String> columns;

  /// Whether this is a `UNIQUE` index.
  final bool unique;

  /// Creates an index; when [name] is omitted it falls back to
  /// [resolvedName].
  const Index({this.name, required this.columns, this.unique = false});

  /// Derives the index name if none was explicitly provided
  String resolvedName(String tableName) {
    if (name != null && name!.isNotEmpty) return name!;
    final prefix = unique ? 'uniq' : 'idx';
    return '${prefix}_${tableName}_${columns.join('_')}';
  }

  /// Renders the `CREATE INDEX` statement for [tableName].
  String toSql(String tableName) {
    final u = unique ? 'UNIQUE ' : '';
    final idxName = resolvedName(tableName);
    return 'CREATE ${u}INDEX IF NOT EXISTS ${_quote(idxName)} '
        'ON ${_quote(tableName)} (${columns.map(_quote).join(', ')});';
  }
}

/// A table definition: a name, its [columns], and any [indexes].
final class Table {
  /// Table name as written in SQL.
  final String name;

  /// Columns of the table, in declaration order.
  final List<Column> columns;

  /// Indexes created alongside the table.
  final List<Index> indexes;

  /// Creates a table named [name] with the given [columns] and [indexes].
  const Table(this.name, this.columns, {this.indexes = const []});

  /// Renders the `CREATE TABLE IF NOT EXISTS` statement.
  String toCreateTableSql() {
    final colsSql = columns.map((c) => c.toSql()).join(', ');
    return 'CREATE TABLE IF NOT EXISTS ${_quote(name)} ($colsSql);';
  }
}

/// A versioned schema: the desired [tables], [virtualTables], and [triggers].
final class Schema {
  /// Monotonic schema version, persisted via `PRAGMA user_version`.
  final int version;

  /// Regular tables in the schema.
  final List<Table> tables;

  /// FTS/RTree virtual tables in the schema.
  final List<VirtualTable> virtualTables;

  /// Triggers in the schema.
  final List<Trigger> triggers;

  /// Creates a schema at [version] from the given tables and triggers.
  const Schema({
    required this.version,
    required this.tables,
    this.virtualTables = const [],
    this.triggers = const [],
  });
}

/// Represents unquoted raw SQL expressions (e.g. CURRENT_TIMESTAMP, NULL, (col_a + col_b))
final class RawSql {
  /// The raw SQL text emitted verbatim.
  final String expression;

  /// Wraps [expression] so it renders unquoted.
  const RawSql(this.expression);

  /// `CURRENT_TIMESTAMP`, for default values.
  static const currentTimestamp = RawSql('CURRENT_TIMESTAMP');

  /// `CURRENT_DATE`, for default values.
  static const currentDate = RawSql('CURRENT_DATE');

  /// `CURRENT_TIME`, for default values.
  static const currentTime = RawSql('CURRENT_TIME');

  @override
  String toString() => expression;
}

/// A virtual table backed by a module such as `fts5` or `rtree`.
final class VirtualTable {
  /// Virtual table name.
  final String name;

  /// SQLite module name, e.g. `'fts5'`, `'fts4'`, or `'rtree'`.
  final String module; // 'fts5', 'fts4', or 'rtree'

  /// Columns exposed by the virtual table.
  final List<String> columns;

  /// External content table, or `null` for a standalone table.
  final String? contentTable;

  /// Column used as the content row id.
  final String? contentRowId;

  /// Creates an `fts5` virtual table named [name] over [columns].
  const VirtualTable.fts5(
    this.name, {
    required this.columns,
    this.contentTable,
    this.contentRowId = 'id',
  }) : module = 'fts5';

  /// Renders the `CREATE VIRTUAL TABLE IF NOT EXISTS` statement.
  String toCreateTableSql() {
    final args = <String>[...columns];
    if (contentTable != null) args.add("content='$contentTable'");
    if (contentRowId != null) args.add("content_rowid='$contentRowId'");
    return 'CREATE VIRTUAL TABLE IF NOT EXISTS $name USING $module(${args.join(', ')});';
  }
}

/// Event a [Trigger] fires on.
enum TriggerEvent {
  /// Fires on `INSERT`.
  insert,

  /// Fires on `UPDATE`.
  update,

  /// Fires on `DELETE`.
  delete,
}

/// When a [Trigger] fires relative to its event.
enum TriggerTiming {
  /// Before the event (`BEFORE`).
  before,

  /// After the event (`AFTER`).
  after,

  /// Instead of the event (`INSTEAD OF`).
  insteadOf,
}

/// A SQLite trigger: a named body run in response to an event on a table.
final class Trigger {
  /// Trigger name.
  final String name;

  /// When the trigger fires relative to the event.
  final TriggerTiming timing;

  /// Event that fires the trigger.
  final TriggerEvent event;

  /// Table whose rows trigger the event.
  final String targetTable;

  /// Plain SQL statement(s) executed inside `BEGIN ... END;`.
  final String body; // Plain SQL statement(s) executed inside BEGIN ... END;

  /// Creates a trigger with an explicit [timing], [event], and [body].
  const Trigger({
    required this.name,
    required this.timing,
    required this.event,
    required this.targetTable,
    required this.body,
  });

  /// Expressive factory helper for FTS sync triggers
  factory Trigger.ftsSync({
    required String name,
    required String targetTable,
    required String ftsTable,
    required List<String> columns,
  }) {
    final colsStr = columns.join(', ');
    final newValsStr = columns.map((c) => 'new.$c').join(', ');

    return Trigger(
      name: name,
      timing: TriggerTiming.after,
      event: TriggerEvent.insert,
      targetTable: targetTable,
      body:
          'INSERT INTO $ftsTable(rowid, $colsStr) VALUES (new.id, $newValsStr);',
    );
  }

  /// Renders the `CREATE TRIGGER IF NOT EXISTS` statement.
  String toCreateSql() {
    final timingStr = timing.name.toUpperCase();
    final eventStr = event.name.toUpperCase();
    return '''
CREATE TRIGGER IF NOT EXISTS $name
$timingStr $eventStr ON $targetTable
FOR EACH ROW
BEGIN
  $body
END;''';
  }
}
