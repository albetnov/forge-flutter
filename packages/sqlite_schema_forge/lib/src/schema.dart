enum DataType { integer, text, real, blob }

/// Identifiers cannot be bound, so they are quoted in exactly one place.
String _quote(String name) => '"${name.replaceAll('"', '""')}"';

/// Column definition
/// Prefer to use the factory helpers [Column.id], [Column.text], etc.
final class Column {
  final String name;
  final DataType type;
  final bool primaryKey;
  final bool autoIncrement;
  final bool nullable;
  final bool unique;
  final Object? defaultValue;
  final String? referencesTable;
  final String? referencesColumn;

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

final class Index {
  final String? name;
  final List<String> columns;
  final bool unique;

  const Index({this.name, required this.columns, this.unique = false});

  /// Derives the index name if none was explicitly provided
  String resolvedName(String tableName) {
    if (name != null && name!.isNotEmpty) return name!;
    final prefix = unique ? 'uniq' : 'idx';
    return '${prefix}_${tableName}_${columns.join('_')}';
  }

  String toSql(String tableName) {
    final u = unique ? 'UNIQUE ' : '';
    final idxName = resolvedName(tableName);
    return 'CREATE ${u}INDEX IF NOT EXISTS ${_quote(idxName)} '
        'ON ${_quote(tableName)} (${columns.map(_quote).join(', ')});';
  }
}

final class Table {
  final String name;
  final List<Column> columns;
  final List<Index> indexes;

  const Table(this.name, this.columns, {this.indexes = const []});

  String toCreateTableSql() {
    final colsSql = columns.map((c) => c.toSql()).join(', ');
    return 'CREATE TABLE IF NOT EXISTS ${_quote(name)} ($colsSql);';
  }
}

final class Schema {
  final int version;
  final List<Table> tables;
  final List<VirtualTable> virtualTables;
  final List<Trigger> triggers;

  const Schema({
    required this.version,
    required this.tables,
    this.virtualTables = const [],
    this.triggers = const [],
  });
}

/// Represents unquoted raw SQL expressions (e.g. CURRENT_TIMESTAMP, NULL, (col_a + col_b))
final class RawSql {
  final String expression;
  const RawSql(this.expression);

  static const currentTimestamp = RawSql('CURRENT_TIMESTAMP');
  static const currentDate = RawSql('CURRENT_DATE');
  static const currentTime = RawSql('CURRENT_TIME');

  @override
  String toString() => expression;
}

final class VirtualTable {
  final String name;
  final String module; // 'fts5', 'fts4', or 'rtree'
  final List<String> columns;
  final String? contentTable;
  final String? contentRowId;

  const VirtualTable.fts5(
    this.name, {
    required this.columns,
    this.contentTable,
    this.contentRowId = 'id',
  }) : module = 'fts5';

  String toCreateTableSql() {
    final args = <String>[...columns];
    if (contentTable != null) args.add("content='$contentTable'");
    if (contentRowId != null) args.add("content_rowid='$contentRowId'");
    return 'CREATE VIRTUAL TABLE IF NOT EXISTS $name USING $module(${args.join(', ')});';
  }
}

enum TriggerEvent { insert, update, delete }

enum TriggerTiming { before, after, insteadOf }

final class Trigger {
  final String name;
  final TriggerTiming timing;
  final TriggerEvent event;
  final String targetTable;
  final String body; // Plain SQL statement(s) executed inside BEGIN ... END;

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
