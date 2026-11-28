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
| `migrate(db:, targetSchema:, onUpgrade?, onDowngrade?, allowDestructive:)` | Legacy path: `plan` + transaction. Use `migrateWithUpgrades` for exact-range acknowledgement and version-bound hooks; use precomputed history for historical attribution. |
| `migrateWithUpgrades(db:, targetSchema:, upgrades:)` | Runtime path. A destructive plan requires `MigrationHook.noop()` on the exact live-to-target range. Adjacent custom hooks run before DDL; applicable custom hooks across skipped versions are rejected because historical schema boundaries are unavailable. |
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

## Optional precomputed history

`SchemaSnapshot` serializes declarative schemas as versioned JSON. The package
CLI captures host-runnable schema entry points, compiles adjacent snapshots
through the existing planner, and verifies snapshots plus plan artifacts
without rewriting them:

```sh
dart run sqlite_schema_forge:snapshot capture --entry tool/schema.dart --out schemaforge/snapshots/0001.json
dart run sqlite_schema_forge:snapshot compile --snapshots schemaforge/snapshots --out build/schemaforge/migrations
dart run sqlite_schema_forge:snapshot verify --snapshots schemaforge/snapshots --migrations build/schemaforge/migrations
```

The entry point prints only `SchemaSnapshot.encode(schema)` to stdout. Never
overwrite a released snapshot with changed structure. Compile into a new or
empty directory; supply repeated `--hook from:to:beforePlan|afterPlan` flags
for data transitions and keep the same flags in CI verification. For CI, keep
these declarations in `schemaforge/hooks.json` as records with `from`, `to`,
and `phase`; the workflow passes that file to verification automatically.

To stop retaining every full schema snapshot, first verify and compact a full
history into a rolling two-version checkpoint pair:

```sh
dart run sqlite_schema_forge:snapshot compact --snapshots schemaforge/snapshots --migrations schemaforge/migrations --out schemaforge/checkpoints --hooks-file schemaforge/hooks.json
dart run sqlite_schema_forge:snapshot advance --entry tool/schema_v31.dart --checkpoints schemaforge/checkpoints --migrations schemaforge/migrations --hooks-file schemaforge/hooks.json
dart run sqlite_schema_forge:snapshot verify --checkpoints schemaforge/checkpoints --migrations schemaforge/migrations
```

`advance` adds exactly one adjacent transition and keeps older migration
chunks, so existing databases remain supported. It needs only the latest two
schema checkpoints; older full snapshots can be pruned after verification.
Keep the manifest and every transition chunk needed by the oldest supported
database version. Checkpoints are build-time inputs and are not app assets.

At runtime, pass `migrationHistory: MigrationArtifactStore(loader)` to
`migrateWithUpgrades()`. Implement `MigrationArtifactLoader` in the host app:
plain Dart can read files and Flutter can use `rootBundle.loadString` plus app
asset declarations. The core package does not depend on Flutter. The loader is
called only after the installed version has been checked, and only chunks
intersecting the requested path are read. Fresh/current databases bypass
history loading. Supplied invalid or incomplete history fails closed.

For precomputed paths, the manifest marks each required hook and its
`beforePlan` or `afterPlan` boundary. Register the exact crossed transitions in
`upgrades`; missing or unexpected registrations fail before transaction
execution. Hooks outside the installed-to-target path are ignored.

## Caveats / workarounds

- Legacy destructive guard is fail-closed: `migrate`/`applyPlan` throw unless `allowDestructive: true`. In `migrateWithUpgrades`, `MigrationHook.noop()` acknowledges destructive work only for the exact live-to-target range. Intermediate acknowledgements do not combine. `applyPlanWithHook` supports explicit acknowledgement for custom versioning.
- `plan()` diffs shape only (columns present, index names, normalized virtual/trigger SQL) — type/nullable/unique/default changes to an *existing* column produce **no step**. Workaround: handle via `onUpgrade` manual `ALTER`/rebuild, or force a rebuild by removing+re-adding (destructive).
- Downgrade is shape-diff + `onDowngrade`, not a reversal log — data dropped on upgrade does not come back. Gate downgrades or back up first.
- `applyPlan` splits `step.sql` on newlines: multi-statement bodies with embedded newlines execute line-by-line — keep trigger bodies to one statement per line or execute them yourself.
