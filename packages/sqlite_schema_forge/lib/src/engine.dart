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

/// Explicit acknowledgement hook for migrations, including destructive ones.
/// Use [MigrationHook.noop] when no data work is needed but the migration has
/// been reviewed and is intentionally allowed to discard data.
final class MigrationHook {
  /// Callback invoked inside the migration transaction.
  final MigrationCallback _callback;

  /// Whether this hook explicitly acknowledges intentional data loss.
  final bool acknowledgesDataLoss;

  /// Creates a hook from [callback].
  const MigrationHook(MigrationCallback callback)
    : _callback = callback,
      acknowledgesDataLoss = false;

  /// Creates an explicit hook that performs no data transformation.
  factory MigrationHook.noop() => MigrationHook._noop();

  MigrationHook._noop()
    : _callback = _emptyMigrationCallback,
      acknowledgesDataLoss = true;

  /// Runs this hook for the given version range.
  Future<void> call(DatabaseExecutor db, int fromVersion, int toVersion) =>
      _callback(db, fromVersion, toVersion);
}

Future<void> _emptyMigrationCallback(
  DatabaseExecutor db,
  int fromVersion,
  int toVersion,
) async {}

/// A migration hook bound to one adjacent schema version transition.
final class Upgrade {
  /// Source version for this transition.
  final int fromVersion;

  const Upgrade._(this.fromVersion);

  /// Starts an upgrade definition from [version].
  static Upgrade from(int version) => Upgrade._(version);

  /// Completes this transition with its required [hook].
  UpgradeDefinition to(int version, MigrationHook hook) => UpgradeDefinition(
    fromVersion: fromVersion,
    toVersion: version,
    hook: hook,
  );
}

/// One explicitly acknowledged version-to-version upgrade.
final class UpgradeDefinition {
  /// Source version.
  final int fromVersion;

  /// Destination version.
  final int toVersion;

  /// Hook run for this transition.
  final MigrationHook hook;

  /// Creates an adjacent version transition.
  UpgradeDefinition({
    required this.fromVersion,
    required this.toVersion,
    required this.hook,
  }) : assert(fromVersion != toVersion);
}

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
  /// Migrates using hooks bound to version transitions.
  ///
  /// Runtime planning cannot attribute a destructive change to a historical
  /// transition. A [MigrationHook.noop] acknowledges destructive work only
  /// when its range exactly matches the live-to-target migration. For skipped
  /// versions, custom hooks are rejected because intermediate schema states
  /// are unavailable.
  static Future<MigrationResult> migrateWithUpgrades({
    required DatabaseExecutor db,
    required Schema targetSchema,
    List<UpgradeDefinition> upgrades = const [],
    bool disableForeignKeys = false,
  }) async {
    final migrationPlan = await plan(db: db, targetSchema: targetSchema);
    if (migrationPlan.isUpToDate) {
      return const MigrationResult(migrated: false, executedSql: []);
    }
    final isUpgrade = migrationPlan.fromVersion < targetSchema.version;
    final transitions = isUpgrade
        ? [
            for (
              var v = migrationPlan.fromVersion;
              v < targetSchema.version;
              v++
            )
              (v, v + 1),
          ]
        : [
            for (
              var v = migrationPlan.fromVersion;
              v > targetSchema.version;
              v--
            )
              (v, v - 1),
          ];
    final byRange = {
      for (final upgrade in upgrades)
        (upgrade.fromVersion, upgrade.toVersion): upgrade,
    };
    final exactRange = (migrationPlan.fromVersion, targetSchema.version);
    final exactUpgrade = byRange[exactRange];
    final skipped =
        (targetSchema.version - migrationPlan.fromVersion).abs() > 1;
    final lower = migrationPlan.fromVersion < targetSchema.version
        ? migrationPlan.fromVersion
        : targetSchema.version;
    final upper = migrationPlan.fromVersion > targetSchema.version
        ? migrationPlan.fromVersion
        : targetSchema.version;
    final applicable = upgrades
        .where(
          (upgrade) =>
              upgrade.fromVersion >= lower && upgrade.toVersion <= upper,
        )
        .toList();
    if (skipped &&
        applicable.any((upgrade) => !upgrade.hook.acknowledgesDataLoss)) {
      throw StateError(
        'Cannot run custom migration hooks while migrating across skipped '
        'versions ${migrationPlan.fromVersion} -> ${targetSchema.version} '
        'without historical schemas. Use precomputed migration history or '
        'migrate through adjacent versions. Hooks must not be silently skipped.',
      );
    }

    if (migrationPlan.hasDestructiveChanges &&
        (exactUpgrade == null || !exactUpgrade.hook.acknowledgesDataLoss)) {
      final details = migrationPlan.steps
          .where((step) => step.isDestructive)
          .map((step) => '- ${step.description} (table: ${step.targetTable})')
          .join('\n');
      throw StateError(
        'Destructive migration from ${migrationPlan.fromVersion} to '
        '${targetSchema.version} requires an exact-range acknowledgement. '
        'Register Upgrade.from(${migrationPlan.fromVersion}).to('
        '${targetSchema.version}, MigrationHook.noop()) or supply precomputed '
        'history for historical attribution.\nDestructive changes:\n$details',
      );
    }

    final hooks = [
      for (final range in transitions)
        if (isUpgrade) byRange[range]?.hook else null,
    ];
    final executed = <String>[];
    Future<void> run() async {
      await db.transaction((txn) async {
        for (var i = 0; i < transitions.length; i++) {
          final hook = hooks[i];
          if (hook != null) {
            await hook.call(txn, transitions[i].$1, transitions[i].$2);
          }
        }
        final applied = await applyPlan(
          db: txn,
          plan: migrationPlan,
          allowDestructive: true,
        );
        executed.addAll(applied.executedSql);
        final sql = 'PRAGMA user_version = ${targetSchema.version};';
        await txn.execute(sql);
        executed.add(sql);
      });
    }

    if (disableForeignKeys) {
      final wasEnabled = await _wereForeignKeysEnabled(db);
      await db.execute('PRAGMA foreign_keys = OFF;');
      executed.add('PRAGMA foreign_keys = OFF;');
      try {
        await run();
      } finally {
        if (wasEnabled) {
          await db.execute('PRAGMA foreign_keys = ON;');
          executed.add('PRAGMA foreign_keys = ON;');
        }
      }
    } else {
      await run();
    }
    return MigrationResult(migrated: true, executedSql: executed);
  }

  /// Applies a plan with an explicit hook when it contains destructive steps.
  /// The hook receives the plan version range before DDL is applied.
  static Future<MigrationResult> applyPlanWithHook({
    required DatabaseExecutor db,
    required MigrationPlan plan,
    MigrationHook? hook,
  }) async {
    if (plan.steps.isEmpty) {
      return const MigrationResult(migrated: false, executedSql: []);
    }
    if (plan.hasDestructiveChanges) {
      if (hook == null) {
        final details = plan.steps
            .where((step) => step.isDestructive)
            .map((step) => '- ${step.description} (table: ${step.targetTable})')
            .join('\n');
        throw StateError(
          'Destructive migration from version ${plan.fromVersion} to '
          '${plan.toVersion} requires an explicit MigrationHook. '
          'Use MigrationHook.noop() to acknowledge intentional data loss. '
          'Destructive changes:\n$details',
        );
      }
      return db.transaction((txn) async {
        await hook.call(txn, plan.fromVersion, plan.toVersion);
        return applyPlan(db: txn, plan: plan, allowDestructive: true);
      });
    }
    return applyPlan(db: db, plan: plan, allowDestructive: false);
  }

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
  /// Only DDL [plan.steps] determine whether work runs here; a version gap
  /// with zero steps is a no-op for [applyPlan] (version bookkeeping belongs
  /// to [migrate] or the external version manager).
  ///
  /// Use this if you want to manage your own migrator.
  static Future<MigrationResult> applyPlan({
    required DatabaseExecutor db,
    required MigrationPlan plan,
    bool allowDestructive = false,
  }) async {
    if (plan.steps.isEmpty) {
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
  ///
  /// When [disableForeignKeys] is true, foreign-key enforcement is turned off
  /// around the whole migration (before the transaction, restored after) so
  /// [onUpgrade]/[onDowngrade] data moves and `DROP`/`CREATE` rebuilds don't
  /// trip on transient violations. This follows the documented SQLite
  /// procedure (`PRAGMA foreign_keys = OFF;` outside the transaction —
  /// toggling it *inside* the transaction is a no-op per SQLite docs).
  static Future<MigrationResult> migrate({
    required DatabaseExecutor db,
    required Schema targetSchema,
    MigrationCallback? onUpgrade,
    MigrationCallback? onDowngrade,
    bool allowDestructive = false,
    bool disableForeignKeys = false,
  }) async {
    final migrationPlan = await plan(db: db, targetSchema: targetSchema);
    if (migrationPlan.isUpToDate) {
      return const MigrationResult(migrated: false, executedSql: []);
    }

    final executedQueries = <String>[];

    Future<void> runMigration() async {
      await db.transaction((txn) async {
        // 1. Run version range callbacks
        if (migrationPlan.fromVersion < targetSchema.version &&
            onUpgrade != null) {
          await onUpgrade(txn, migrationPlan.fromVersion, targetSchema.version);
        } else if (migrationPlan.fromVersion > targetSchema.version &&
            onDowngrade != null) {
          await onDowngrade(
            txn,
            migrationPlan.fromVersion,
            targetSchema.version,
          );
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
    }

    if (!disableForeignKeys) {
      await runMigration();
    } else {
      final wasEnabled = await _wereForeignKeysEnabled(db);
      const offSql = 'PRAGMA foreign_keys = OFF;';
      await db.execute(offSql);
      executedQueries.add(offSql);
      try {
        await runMigration();
      } finally {
        if (wasEnabled) {
          const onSql = 'PRAGMA foreign_keys = ON;';
          await db.execute(onSql);
          executedQueries.add(onSql);
        }
      }
    }

    return MigrationResult(migrated: true, executedSql: executedQueries);
  }

  /// Reads the current `PRAGMA foreign_keys` state. Defaults to enabled when
  /// the value can't be determined, so callers that opt into
  /// [SqliteSchemaForge.migrate] with `disableForeignKeys: true` restore a
  /// safe default.
  static Future<bool> _wereForeignKeysEnabled(DatabaseExecutor db) async {
    try {
      final rows = await db.rawQuery('PRAGMA foreign_keys;');
      if (rows.isEmpty) return true;
      final value = rows.first.values.first;
      if (value is int) return value != 0;
      if (value is bool) return value;
      return true;
    } catch (_) {
      return true;
    }
  }
}
