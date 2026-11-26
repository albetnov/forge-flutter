import 'dart:convert';

import 'engine.dart';
import 'executor.dart';
import 'plan.dart';
import 'schema.dart';

/// Versioned JSON serialization for an already compiled migration plan.
final class MigrationPlanSnapshot {
  /// Current plan artifact format, independent of schema and schema-snapshot
  /// versions.
  static const formatVersion = 1;

  const MigrationPlanSnapshot._();

  /// Serializes a plan deterministically as readable JSON.
  static String encode(MigrationPlan plan) =>
      const JsonEncoder.withIndent('  ').convert(toJson(plan));

  /// Returns the canonical JSON-compatible representation of [plan].
  static Map<String, Object?> toJson(MigrationPlan plan) => {
    'formatVersion': formatVersion,
    'fromVersion': plan.fromVersion,
    'toVersion': plan.toVersion,
    'steps': [
      for (final step in plan.steps)
        {
          'type': step.type.name,
          'targetTable': step.targetTable,
          'sql': step.sql,
          'description': step.description,
          'isDestructive': step.isDestructive,
        },
    ],
  };

  /// Parses a serialized plan and rejects unsupported or malformed records.
  static MigrationPlan decode(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw FormatException('Invalid migration plan JSON: ${error.message}');
    }
    final root = _map(decoded, 'plan');
    final format = _int(root['formatVersion'], 'formatVersion');
    if (format != formatVersion) {
      throw FormatException(
        'Unsupported migration plan formatVersion $format; '
        'supported version is $formatVersion.',
      );
    }
    final steps = _list(root['steps'], 'steps').asMap().entries.map((entry) {
      final path = 'steps[${entry.key}]';
      final step = _map(entry.value, path);
      return PlanStep(
        type: _enum(ChangeType.values, step['type'], '$path.type'),
        targetTable: _string(step['targetTable'], '$path.targetTable'),
        sql: _string(step['sql'], '$path.sql'),
        description: _string(step['description'], '$path.description'),
        isDestructive: _bool(step['isDestructive'], '$path.isDestructive'),
      );
    }).toList();
    return MigrationPlan(
      fromVersion: _int(root['fromVersion'], 'fromVersion'),
      toVersion: _int(root['toVersion'], 'toVersion'),
      steps: steps,
    );
  }

  static Map<String, Object?> _map(Object? value, String path) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw FormatException('$path must be a JSON object with string keys.');
    }
    return value.cast<String, Object?>();
  }

  static List<Object?> _list(Object? value, String path) => value is List
      ? value.cast<Object?>()
      : throw FormatException('$path must be a JSON array.');

  static String _string(Object? value, String path) => value is String
      ? value
      : throw FormatException('$path must be a string.');

  static int _int(Object? value, String path) =>
      value is int ? value : throw FormatException('$path must be an integer.');

  static bool _bool(Object? value, String path) =>
      value is bool ? value : throw FormatException('$path must be a boolean.');

  static T _enum<T extends Enum>(List<T> values, Object? value, String path) {
    if (value is String) {
      for (final item in values) {
        if (item.name == value) return item;
      }
    }
    throw FormatException('$path has an unknown value "$value".');
  }
}

/// Compiles an adjacent schema transition with the package's runtime planner.
///
/// The previous snapshot is exposed through a read-only executor which answers
/// the same introspection queries used by [SqliteSchemaForge.plan]. This keeps
/// the migration rules shared with runtime planning.
final class MigrationPlanCompiler {
  const MigrationPlanCompiler._();

  /// Compiles [previous] → [current] using the existing schema planner.
  static Future<MigrationPlan> compile({
    required Schema previous,
    required Schema current,
  }) async {
    if (current.version != previous.version + 1) {
      throw ArgumentError(
        'Migration plans must be compiled from adjacent versions; got '
        '${previous.version} -> ${current.version}.',
      );
    }
    final plan = await SqliteSchemaForge.plan(
      db: _SnapshotExecutor(previous),
      targetSchema: current,
    );
    return MigrationPlan(
      fromVersion: previous.version,
      toVersion: current.version,
      steps: plan.steps,
    );
  }
}

final class _SnapshotExecutor implements DatabaseExecutor {
  _SnapshotExecutor(this.schema);

  final Schema schema;

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    if (sql == 'PRAGMA user_version;') {
      return [
        {'user_version': schema.version},
      ];
    }
    final tableMatch = RegExp(r"^PRAGMA table_info\('((?:''|[^'])*)'\)$")
        .firstMatch(sql);
    if (tableMatch != null) {
      final name = tableMatch.group(1)!.replaceAll("''", "'");
      final table = _find(schema.tables, name);
      return table == null
          ? []
          : [
              for (final column in table.columns) {'name': column.name},
            ];
    }
    final indexMatch = RegExp(r"^PRAGMA index_list\('((?:''|[^'])*)'\)$")
        .firstMatch(sql);
    if (indexMatch != null) {
      final name = indexMatch.group(1)!.replaceAll("''", "'");
      final table = _find(schema.tables, name);
      return table == null
          ? []
          : [
              for (final index in table.indexes)
                {'name': index.resolvedName(table.name)},
            ];
    }
    if (sql.contains("type = 'table'")) {
      return [
        for (final table in schema.virtualTables)
          {'name': table.name, 'sql': table.toCreateTableSql()},
      ];
    }
    if (sql.contains("type = 'trigger'")) {
      return [
        for (final trigger in schema.triggers)
          {'name': trigger.name, 'sql': trigger.toCreateSql()},
      ];
    }
    throw UnsupportedError('Unsupported planner introspection query: $sql');
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async =>
      throw UnsupportedError('Snapshot compilation is read-only.');

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseExecutor txn) action) =>
      throw UnsupportedError('Snapshot compilation does not use transactions.');

  Table? _find(List<Table> tables, String name) {
    for (final table in tables) {
      if (table.name == name) return table;
    }
    return null;
  }
}
