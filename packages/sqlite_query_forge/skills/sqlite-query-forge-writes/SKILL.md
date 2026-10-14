---
name: sqlite-query-forge-writes
description: INSERT UPDATE DELETE builders, values/returning/onConflict, execute vs getMany, error contracts.
---

# Writes: `InsertBuilder`, `UpdateBuilder`, `DeleteBuilder`

Immutable write chains. Build through `Forge.insertInto/update/deleteFrom`
so the executor is attached. Import from
`package:sqlite_query_forge/sqlite_query_forge.dart`.

```dart
final rowid = await forge.insertInto(users).values({
  'name': 'Ada', 'email': 'ada@example.com', 'is_active': true,
}).execute();

final n = await forge.update(users)
  .values({'is_active': false})
  .where(users.id.gt(1))
  .execute();

await forge.deleteFrom(users).where(users.email.isNull).execute();
```

## Configuration

| Builder | Config |
| --- | --- |
| `InsertBuilder.values(row)` / `valuesAll(rows)` | Column order follows first map's key order. `valuesAll` needs identical column sets in every row. Empty row / empty call throws `StateError`. |
| `onConflictIgnore()` | Emits `ON CONFLICT DO NOTHING`. |
| `onConflictUpdate(updates, {columns})` | Emits `ON CONFLICT [(cols)] DO UPDATE SET`. An `Expression` value (e.g. `RawSql('excluded."email"')`) is written as a reference; anything else binds as `?`. |
| `UpdateBuilder.values(map)` | Non-empty required. `Expression` values are references, rest are bound. |
| `UpdateBuilder/DeleteBuilder.where` + `andWhere`/`orWhere` | Same accumulate/paren rule as selects. **Missing filter touches every row** — `DELETE`/`UPDATE` with no `where` is legal. |
| `returning([cols])` | Empty list means `RETURNING *`. Needs SQLite 3.35+. Flips the terminal (below). |

## Terminals

- `execute()` — insert returns new rowid (`ForgeExecutor.insert`); update/delete return affected count (`ForgeExecutor.execute`). Throws if `returning()` was set: `A returning X yields rows; call getMany().`
- `getMany()` — runs `executor.query`, returns affected rows as `List<Map>`. Throws without prior `returning()`: `Call returning() before reading ... rows.`
- `compile()` / `toSql()` + `getRawArgs()` — preview without executor.
- `InsertBuilder.getLastInsertId()` — `SELECT last_insert_rowid()` on the same executor. Connection-wide: call immediately after the insert; any later insert replaces it. Returns `0` on empty, coerces `num→int`, throws on non-numeric.

## Instance management

Builders are immutable values, no `dispose`. `compile()` needs no
executor; `execute()`/`getMany()` throw `StateError` when built by hand
without one (`Build writes through a Forge instead of constructing a ...`).
Executors stay caller-owned; writes never open/close connections.

## Behavior contracts

- **Same binding rule as reads:** values bind as `?` (`bool` → `1/0`); only `Expression` values render inline. Column names are always quoted identifiers.
- **`Forge.insert/execute(stmt)`** are the raw-statement equivalents (compile then dispatch to `insert`/`execute`).

## Caveats

- `values({})` on update and `valuesAll` with mismatched keys throw synchronously at build time, not at `execute`.
- `RETURNING` turns the write into a read at the driver level — old SQLite (< 3.35), or an executor that routes `RETURNING` through `execute` instead of `query`, fails. Gate usage or test the driver.
- `onConflictUpdate` with no `columns` emits bare `ON CONFLICT DO UPDATE` (last-write-wins on any conflict); pass `columns: [table.email]` to target a unique index.
- `getLastInsertId` is not the `execute()` rowid on all drivers — prefer the `execute()` return unless the insert used `onConflictIgnore` (which may not have inserted).
