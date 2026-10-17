## 0.2.0

- `CaseWhen` / `WhenBranch`: `CASE WHEN <cond> THEN <result> ... ELSE <else>
  END` for conditional aggregates (e.g. `SUM(CASE WHEN ... END)`). Conditions
  render as expressions; results and `orElse` render as references when they
  are `Expression`s and bind as `?` otherwise. A null `orElse` omits `ELSE`.
- `match(String query)` on `Column`, `QualifiedColumn`, and `ExpressionOps`:
  `<left> MATCH ?` with the FTS5 pattern bound, same shape as `like`.
- `Lit`: a `const` literal value for expression positions, rendering `?` and
  binding (with the existing `bool` → `1/0` rule). Usable anywhere an
  `Expression` fits, e.g. `FunctionCall('COALESCE', [col.sum, const Lit(0)])`.

## 0.1.0

- Initial release in the `the_forge_ecosystem` monorepo (reset from prior
  standalone versioning).
- Sealed `Expression` hierarchy with bound-parameter SQL compilation.
- Immutable fluent builders: select / insert / update / delete / upsert /
  `RETURNING`, joins, JSON projections, transactions via the `Forge` facade
  over `ForgeExecutor`, plus the `sqlite_schema_forge` migration bridge.
