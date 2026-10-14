## 0.1.0

- Initial release in the `the_forge_ecosystem` monorepo (reset from prior
  standalone versioning).
- Sealed `Expression` hierarchy with bound-parameter SQL compilation.
- Immutable fluent builders: select / insert / update / delete / upsert /
  `RETURNING`, joins, JSON projections, transactions via the `Forge` facade
  over `ForgeExecutor`, plus the `sqlite_schema_forge` migration bridge.
