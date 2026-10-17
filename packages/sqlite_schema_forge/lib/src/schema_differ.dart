import 'package:sqlite_schema_forge/sqlite_schema_forge.dart';

/// Computes the [PlanStep]s that bring a live database in line with a target
/// [Schema]. Read-only: it never mutates the database.
final class SchemaDiffer {
  /// Diffs one [targetTable]: creates a missing table and its indexes,
  /// rebuilds when a live column was dropped, otherwise adds any new columns
  /// and missing indexes.
  static Future<List<PlanStep>> diffTable(
    DatabaseExecutor db,
    Table targetTable,
  ) async {
    final steps = <PlanStep>[];
    final liveInfo = await db.rawQuery(
      "PRAGMA table_info('${targetTable.name}')",
    );

    // Case 1: Table doesn't exist -> CREATE TABLE & INDEXES
    if (liveInfo.isEmpty) {
      steps.add(
        PlanStep(
          type: ChangeType.createTable,
          targetTable: targetTable.name,
          sql: targetTable.toCreateTableSql(),
          description: "Create table '${targetTable.name}'",
        ),
      );

      for (final idx in targetTable.indexes) {
        steps.add(
          PlanStep(
            type: ChangeType.createIndex,
            targetTable: targetTable.name,
            sql: idx.toSql(targetTable.name),
            description:
                "Create index '${idx.resolvedName(targetTable.name)}' on '${targetTable.name}'",
          ),
        );
      }
      return steps;
    }

    final liveColNames = liveInfo.map((row) => row['name'] as String).toSet();
    final targetColNames = targetTable.columns.map((c) => c.name).toSet();

    // Check if any existing columns were dropped or removed
    final hasRemovedColumns = liveColNames.any(
      (name) => !targetColNames.contains(name),
    );

    // Case 2: Requires full Table Rebuild (Destructive copy-and-swap)
    if (hasRemovedColumns) {
      final sharedCols = liveColNames.intersection(targetColNames);
      final rebuildSqls = _generateRebuildSql(targetTable, sharedCols);

      steps.add(
        PlanStep(
          type: ChangeType.rebuildTable,
          targetTable: targetTable.name,
          sql: rebuildSqls.join('\n'),
          description:
              "Rebuild table '${targetTable.name}' (dropped column detected)",
          isDestructive: true,
        ),
      );

      return steps;
    }

    // Case 3: Simple ADD COLUMN
    for (final col in targetTable.columns) {
      if (!liveColNames.contains(col.name)) {
        steps.add(
          PlanStep(
            type: ChangeType.addColumn,
            targetTable: targetTable.name,
            sql: 'ALTER TABLE ${targetTable.name} ADD COLUMN ${col.toSql()};',
            description: "Add column '${col.name}' to '${targetTable.name}'",
          ),
        );
      }
    }

    // Case 4: Sync Indexes
    final liveIndexes = await db.rawQuery(
      "PRAGMA index_list('${targetTable.name}')",
    );
    final liveIndexNames = liveIndexes
        .map((row) => row['name'] as String)
        .toSet();

    for (final idx in targetTable.indexes) {
      final idxName = idx.resolvedName(targetTable.name);
      if (!liveIndexNames.contains(idxName)) {
        steps.add(
          PlanStep(
            type: ChangeType.createIndex,
            targetTable: targetTable.name,
            sql: idx.toSql(targetTable.name),
            description: "Create index '$idxName' on '${targetTable.name}'",
          ),
        );
      }
    }

    return steps;
  }

  static List<String> _generateRebuildSql(
    Table targetTable,
    Set<String> sharedColumns,
  ) {
    final tempName = '_temp_${targetTable.name}';
    final sharedColsStr = sharedColumns.join(', ');

    return [
      'PRAGMA foreign_keys = OFF;',
      targetTable.toCreateTableSql().replaceAll(targetTable.name, tempName),
      'INSERT INTO $tempName ($sharedColsStr) SELECT $sharedColsStr FROM ${targetTable.name};',
      'DROP TABLE ${targetTable.name};',
      'ALTER TABLE $tempName RENAME TO ${targetTable.name};',
      'PRAGMA foreign_keys = ON;',
      ...targetTable.indexes.map((idx) => idx.toSql(targetTable.name)),
    ];
  }

  /// Diffs [targetVirtualTables] against `sqlite_master`, dropping orphaned
  /// virtual tables and (re)creating missing or changed ones.
  static Future<List<PlanStep>> diffVirtualTables(
    DatabaseExecutor db,
    List<VirtualTable> targetVirtualTables,
  ) async {
    final steps = <PlanStep>[];

    // 1. Fetch live virtual tables from sqlite_master
    final liveVirtualTables = await db.rawQuery(
      "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND sql LIKE 'CREATE VIRTUAL TABLE%';",
    );

    final liveMap = {
      for (final row in liveVirtualTables)
        row['name'] as String: row['sql'] as String?,
    };

    final targetNames = targetVirtualTables.map((v) => v.name).toSet();

    // 2. Drop orphaned virtual tables not in target schema
    for (final liveName in liveMap.keys) {
      if (!targetNames.contains(liveName)) {
        steps.add(
          PlanStep(
            type: ChangeType.rebuildTable,
            targetTable: liveName,
            sql: 'DROP TABLE IF EXISTS $liveName;',
            description: "Drop unused virtual table '$liveName'",
            isDestructive: true,
          ),
        );
      }
    }

    // 3. Create missing or modified virtual tables
    for (final target in targetVirtualTables) {
      final liveSql = liveMap[target.name];
      final targetSql = target.toCreateTableSql();

      if (liveSql == null) {
        // Missing -> CREATE VIRTUAL TABLE
        steps.add(
          PlanStep(
            type: ChangeType.createTable,
            targetTable: target.name,
            sql: targetSql,
            description:
                "Create virtual table '${target.name}' (${target.module})",
          ),
        );
      } else if (_normalizeSql(liveSql) != _normalizeSql(targetSql)) {
        // Modified -> Drop and Re-create
        steps.add(
          PlanStep(
            type: ChangeType.rebuildTable,
            targetTable: target.name,
            sql: 'DROP TABLE IF EXISTS ${target.name};\n$targetSql',
            description: "Re-create modified virtual table '${target.name}'",
            isDestructive: true,
          ),
        );
      }
    }

    return steps;
  }

  /// Diffs [targetTriggers] against `sqlite_master`, dropping orphaned
  /// triggers and (re)creating missing or changed ones.
  static Future<List<PlanStep>> diffTriggers(
    DatabaseExecutor db,
    List<Trigger> targetTriggers,
  ) async {
    final steps = <PlanStep>[];

    // 1. Fetch live triggers from sqlite_master
    final liveTriggers = await db.rawQuery(
      "SELECT name, sql FROM sqlite_master WHERE type = 'trigger';",
    );

    final liveMap = {
      for (final row in liveTriggers)
        row['name'] as String: row['sql'] as String?,
    };

    final targetNames = targetTriggers.map((t) => t.name).toSet();

    // 2. Drop orphaned triggers
    for (final liveName in liveMap.keys) {
      if (!targetNames.contains(liveName)) {
        steps.add(
          PlanStep(
            type: ChangeType.dropIndex, // Custom catalog cleanup type
            targetTable: liveName,
            sql: 'DROP TRIGGER IF EXISTS $liveName;',
            description: "Drop unused trigger '$liveName'",
          ),
        );
      }
    }

    // 3. Create missing or modified triggers
    for (final target in targetTriggers) {
      final liveSql = liveMap[target.name];
      final targetSql = target.toCreateSql();

      if (liveSql == null) {
        // Missing -> CREATE TRIGGER
        steps.add(
          PlanStep(
            type: ChangeType.createIndex,
            targetTable: target.targetTable,
            sql: targetSql,
            description:
                "Create trigger '${target.name}' on '${target.targetTable}'",
          ),
        );
      } else if (_normalizeSql(liveSql) != _normalizeSql(targetSql)) {
        // Modified -> Drop and Re-create
        steps.add(
          PlanStep(
            type: ChangeType.createIndex,
            targetTable: target.targetTable,
            sql: 'DROP TRIGGER IF EXISTS ${target.name};\n$targetSql',
            description: "Re-create modified trigger '${target.name}'",
          ),
        );
      }
    }

    return steps;
  }

  /// Normalizes SQL string whitespace for accurate equality comparison
  static String _normalizeSql(String sql) {
    return sql.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
  }
}
