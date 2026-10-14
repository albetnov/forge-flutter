## 0.1.0

- Initial release in the `the_forge_ecosystem` monorepo (reset from prior
  standalone versioning).
- Declarative schema definition (`Schema`, `Table`, `Column`, `Index`,
  `VirtualTable`, `Trigger`, `RawSql`) with `CREATE` DDL generation.
- Auto-migration engine: `migrate`, `plan`, `applyPlan` over a
  driver-agnostic `DatabaseExecutor`, with `PRAGMA user_version` tracking
  and foreign-key helper.
