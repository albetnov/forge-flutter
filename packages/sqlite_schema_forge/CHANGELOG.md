## 0.4.0

- Add incremental artifact generation with `snapshot compact` and
  `snapshot advance`. Keep compiled transition chunks as the durable history
  and retain only the latest two full schema checkpoints; incremental
  verification checks chunk fingerprints and rebuilds the newest transition.

## 0.3.0

- **Breaking:** runtime destructive acknowledgement in `migrateWithUpgrades()`
  must match the actual live-to-target version range. `DestructiveChange`
  selectors are removed, and custom hooks across skipped runtime versions are
  rejected because their historical schema boundaries are unavailable.
- Add optional precomputed migration history: deterministic schema snapshots,
  compiled and validated JSON plan chunks, lazy artifact loading, and the
  `snapshot` capture/compile/verify CLI. Existing runtime planning remains the
  default; explicitly supplied invalid history fails closed.
- Define `beforePlan` and `afterPlan` hook boundaries for precomputed history.
  Fresh databases create the target schema directly without resolving
  historical artifacts or hooks.

## 0.2.0

- Add `migrateWithUpgrades()` with version-bound `Upgrade.from().to()` hooks.
  Destructive plans require explicit definitions for every crossed transition;
  `MigrationHook.noop()` acknowledges intentional data loss for one transition.
- Add `applyPlanWithHook()` for externally managed versioning with explicit
  acknowledgement of destructive plans.

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
