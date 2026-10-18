## 0.1.1

- Fix `migrate()` skipping `onUpgrade`/`onDowngrade` and the
  `PRAGMA user_version` stamp when the plan has no DDL steps:
  `MigrationPlan.isUpToDate` is now `fromVersion == toVersion && steps.isEmpty`,
  so a version gap alone (e.g. a data-only or column-affinity migration)
  counts as out of date. `applyPlan()` keeps its DDL-only no-op behavior.
- New `migrate(disableForeignKeys:)` option (default `false`): turns
  `PRAGMA foreign_keys` off before the migration transaction and restores it
  afterwards, so `onUpgrade`/`onDowngrade` data moves and `DROP`/`CREATE`
  rebuilds don't trip on transient violations.

## 0.1.0

- Initial release in the `the_forge_ecosystem` monorepo (reset from prior
  standalone versioning).
- Declarative schema definition (`Schema`, `Table`, `Column`, `Index`,
  `VirtualTable`, `Trigger`, `RawSql`) with `CREATE` DDL generation.
- Auto-migration engine: `migrate`, `plan`, `applyPlan` over a
  driver-agnostic `DatabaseExecutor`, with `PRAGMA user_version` tracking
  and foreign-key helper.
