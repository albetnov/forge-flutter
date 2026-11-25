---
name: sqlite-schema-forge-migration
description: migration planning and application, hook-backed destructive migration API, legacy allowDestructive guard, user_version handling, callbacks, transactions, executor setup.
---

# `SqliteSchemaForge`: plan → apply → migrate

Static-only migrator over a `DatabaseExecutor` you implement (sqflite /
sqlite3 / drift, or `ForgeDatabaseExecutor` to share the query-forge driver).

```dart
await SqliteSchemaForge.enableForeignKeys(db); // PRAGMA foreign_keys = ON
final plan = await SqliteSchemaForge.plan(db: db, targetSchema: appSchema);
if (plan.hasDestructiveChanges) review(plan);
final r = await SqliteSchemaForge.migrate(
  db: db, targetSchema: appSchema, allowDestructive: false,
  onUpgrade: (txn, from, to) async {}, onDowngrade: (txn, from, to) async {},
);
```

## Configuration

```dart
abstract interface class DatabaseExecutor {
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]);
  Future<void> execute(String sql, [List<Object?>? arguments]);
  Future<T> transaction<T>(Future<T> Function(DatabaseExecutor txn) action);
}
```

| Entry | Meaning |
| --- | --- |
| `plan(db:, targetSchema:)` | Dry run. Returns `MigrationPlan(fromVersion, toVersion, steps)`; executes nothing except `PRAGMA user_version` + introspection (`table_info`, `index_list`, `sqlite_master`). `user_version == version` short-circuits to empty steps. |
| `applyPlan(db:, plan:, allowDestructive:)` | Executes `plan.steps` (splits multi-line `step.sql` on `\n`, skips blanks). Never touches `user_version`. For custom multi-store migrators. Throws `StateError` on destructive steps unless `allowDestructive: true`. No-op (`migrated: false`) when `plan.isUpToDate`. |
| `migrate(db:, targetSchema:, onUpgrade?, onDowngrade?, allowDestructive:)` | Legacy path: `plan` + transaction. Prefer `migrateWithHooks` for the explicit hook contract. |
| `migrateWithUpgrades(db:, targetSchema:, upgrades:)` | Opt-in version-bound path. `Upgrade.from(a).to(b, hook)` defines one adjacent transition. Destructive plans require definitions for every crossed transition because the live-to-target diff cannot attribute steps to historical versions. |
| `applyPlanWithHook(db:, plan:, hook?)` | Opt-in custom-versioning path; a missing hook rejects destructive plans with step descriptions. When supplied, hook and destructive DDL run in one transaction. Safe plans may omit it. |
| `MigrationPlan` | `isUpToDate` = steps empty; `hasDestructiveChanges` = any `isDestructive`. `PlanStep(type, targetTable, sql, description, isDestructive)`, `ChangeType`: createTable/addColumn/rebuildTable/createIndex/dropIndex/executeCallback. |
| Callbacks | `onUpgrade` runs when `from < to`, `onDowngrade` when `from > to`, inside the same txn before DDL. |

## Instance management

No instance — all methods static. No `dispose`. The `db` connection stays
caller-owned; never dispose it mid-migration. `txn` executors must not
escape their closure. `enableForeignKeys` is explicit (off by default in
SQLite) — call per connection; the rebuild path toggles it `OFF`/`ON`
around the copy-swap itself.

## Behavior contracts

- **Add-column is cheap, drop-column is rebuild.** Missing table → `CREATE TABLE` + indexes. Missing column (no removals) → `ALTER TABLE ... ADD COLUMN`. Any live column missing from target → single destructive `rebuildTable` copy-swap (`_temp_` table, shared columns only, `DROP`, `RENAME`, re-create indexes) and index sync is skipped for that table.
- **Virtual tables/triggers diff by normalized SQL** (whitespace/case-insensitive). Missing → create; modified → `DROP + CREATE` (virtual = destructive, trigger = not flagged destructive); orphaned virtual → `DROP` (destructive), orphaned trigger → `DROP TRIGGER` (reuses `ChangeType.dropIndex`).
- **Table-name interpolation in introspection** (`PRAGMA table_info('$name')`) is quoted as string literal, not identifier — keep table names free of quotes.

## Caveats / workarounds

- Legacy destructive guard is fail-closed: `migrate`/`applyPlan` throw unless `allowDestructive: true`. The opt-in `migrateWithHooks`/`applyPlanWithHook` APIs require an explicit hook for destructive steps; use `MigrationHook.noop()` when no data work is needed.
- `plan()` diffs shape only (columns present, index names, normalized virtual/trigger SQL) — type/nullable/unique/default changes to an *existing* column produce **no step**. Workaround: handle via `onUpgrade` manual `ALTER`/rebuild, or force a rebuild by removing+re-adding (destructive).
- Downgrade is shape-diff + `onDowngrade`, not a reversal log — data dropped on upgrade does not come back. Gate downgrades or back up first.
- `applyPlan` splits `step.sql` on newlines: multi-statement bodies with embedded newlines execute line-by-line — keep trigger bodies to one statement per line or execute them yourself.
