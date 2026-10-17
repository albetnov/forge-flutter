import 'package:sqlite_schema_forge/src/executor.dart';
import 'package:sqlite_schema_forge/src/plan.dart';
import 'package:sqlite_schema_forge/src/schema.dart';
import 'package:sqlite_schema_forge/src/schema_differ.dart';

/// Version-to-version hook run inside the migration transaction for data
/// fixes. Receives the transaction's [db] and the `fromVersion`/`toVersion`
/// range being crossed.
typedef MigrationCallback = Future<void> Function(
  DatabaseExecutor db,
  int fromVersion,
  int toVersion,
);

/// Outcome of a migration: whether anything [migrated] and which SQL ran.
final class MigrationResult {
  /// Whether any step ran; `false` when the schema was already up to date.
  final bool migrated;

  /// The SQL statements that were executed, in order.
  final List<String> executedSql;

  /// Creates a result with the given [migrated] flag and [executedSql].
  const MigrationResult({required this.migrated, required this.executedSql});
}

/// Declarative schema migrator: diff a target [Schema] against a live
/// database, then apply the resulting [MigrationPlan].
final class SqliteSchemaForge {
  /// Enables Foreign Keys on SQLite Connection
  static Future<void> enableForeignKeys(DatabaseExecutor db) async {
    await db.execute('PRAGMA foreign_keys = ON;');
  }

  /// Inspects live DB structure against [targetSchema] and returns proposed SQL steps
  /// WITHOUT executing any mutations on the database.
  static Future<MigrationPlan> plan({
    required DatabaseExecutor db,
    required Schema targetSchema,
  }) async {
    // 1. Fast version gatekeeper check
    final versionResult = await db.rawQuery('PRAGMA user_version;');
    final currentVersion = (versionResult.first['user_version'] as int?) ?? 0;

    if (currentVersion == targetSchema.version) {
      return MigrationPlan(
        fromVersion: currentVersion,
        toVersion: targetSchema.version,
        steps: const [],
      );
    }

    final steps = <PlanStep>[];

    // 2. Diff Standard Tables & Indexes
    for (final table in targetSchema.tables) {
      steps.addAll(await SchemaDiffer.diffTable(db, table));
    }

    // 3. Diff Virtual Tables (FTS5, FTS4, RTree)
    if (targetSchema.virtualTables.isNotEmpty) {
      steps.addAll(
        await SchemaDiffer.diffVirtualTables(db, targetSchema.virtualTables),
      );
    }

    // 4. Diff Triggers
    if (targetSchema.triggers.isNotEmpty) {
      steps.addAll(await SchemaDiffer.diffTriggers(db, targetSchema.triggers));
    }

    return MigrationPlan(
      fromVersion: currentVersion,
      toVersion: targetSchema.version,
      steps: steps,
    );
  }

  /// Executes a MigrationPlan against the DB without touching PRAGMA user_version.
  /// Used by global/multi-storage migrators.
  ///
  /// Use this if you want to manage your own migrator.
  static Future<MigrationResult> applyPlan({
    required DatabaseExecutor db,
    required MigrationPlan plan,
    bool allowDestructive = false,
  }) async {
    if (plan.isUpToDate) {
      return const MigrationResult(migrated: false, executedSql: []);
    }

    if (plan.hasDestructiveChanges && !allowDestructive) {
      throw StateError(
        "Destructive changes detected during migration. "
        "Set allowDestructive = true to permit dropping columns or rebuilding tables.",
      );
    }

    final executedQueries = <String>[];

    for (final step in plan.steps) {
      final queries = step.sql.split('\n').where((q) => q.trim().isNotEmpty);
      for (final query in queries) {
        await db.execute(query);
        executedQueries.add(query);
      }
    }

    return MigrationResult(migrated: true, executedSql: executedQueries);
  }

  /// Standard standalone entrypoint
  /// (uses applyPlan + updates PRAGMA user_version)
  static Future<MigrationResult> migrate({
    required DatabaseExecutor db,
    required Schema targetSchema,
    MigrationCallback? onUpgrade,
    MigrationCallback? onDowngrade,
    bool allowDestructive = false,
  }) async {
    final migrationPlan = await plan(db: db, targetSchema: targetSchema);
    if (migrationPlan.isUpToDate) {
      return const MigrationResult(migrated: false, executedSql: []);
    }

    final executedQueries = <String>[];

    await db.transaction((txn) async {
      // 1. Run version range callbacks
      if (migrationPlan.fromVersion < targetSchema.version &&
          onUpgrade != null) {
        await onUpgrade(txn, migrationPlan.fromVersion, targetSchema.version);
      } else if (migrationPlan.fromVersion > targetSchema.version &&
          onDowngrade != null) {
        await onDowngrade(txn, migrationPlan.fromVersion, targetSchema.version);
      }

      // 2. Delegate execution to applyPlan
      final result = await applyPlan(
        db: txn,
        plan: migrationPlan,
        allowDestructive: allowDestructive,
      );
      executedQueries.addAll(result.executedSql);

      // 3. Set SQLite's local version header
      final setVersionSql = 'PRAGMA user_version = ${targetSchema.version};';
      await txn.execute(setVersionSql);
      executedQueries.add(setVersionSql);
    });

    return MigrationResult(migrated: true, executedSql: executedQueries);
  }
}
