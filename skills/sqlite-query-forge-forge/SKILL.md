---
name: sqlite-query-forge-forge
description: Forge entrypoint, ForgeExecutor contract, query/execute/insert, nested transactions.
---

# `Forge` + `ForgeExecutor`

`Forge` is the executor-bound entrypoint: reads, writes, raw statements,
and transactions all start here. The package ships **no driver** — implement
`ForgeExecutor` over sqflite / sqlite3 / drift and hand it in.

```dart
final forge = Forge(myExecutor); // myExecutor implements ForgeExecutor
final rows = await forge.selectFrom(users).where(users.id.eq(1)).getMany();
await forge.transaction((tx) async {
  await tx.insertInto(users).values({'name': 'Ada'}).execute();
  await tx.transaction((nested) async { // joins outer, no second BEGIN
    await nested.deleteFrom(users).where(users.id.eq(3)).execute();
  });
});
```

## Configuration

Implement all four members (args default to `null`):

```dart
Future<List<Map<String, Object?>>> query(String sql, [List<Object?>? args]);
Future<int> execute(String sql, [List<Object?>? args]); // affected count
Future<int> insert(String sql, [List<Object?>? args]);  // new rowid
Future<T> transaction<T>(Future<T> Function(ForgeExecutor txn) action);
```

`Forge` surface: `selectFrom(table)`, `selectFromSource(src, mapper)`,
`insertInto/update/deleteFrom`, `query(stmt)` (rows), `execute(stmt)`
(count), `insert(stmt)` (rowid), `transaction(action)`.

## Instance management

`Forge` is a stateless holder — **no `dispose`, no `close`, no cache**.
The executor lifecycle stays with the app (open once, share the `Forge`).
Do not store the `txn`-scoped `Forge` passed to `transaction(action)`;
it routes to the open txn only inside `action` (`_open` cleared in
`whenComplete`). Throwing inside `action` rolls back (executor's job);
`Forge` just routes nested `transaction()` calls to the already-open txn.

## Behavior contracts

- **Compile-then-dispatch.** Every method calls `statement.compile()` once, then `query(sql, args)` / `execute` / `insert`. SQL + args order is deterministic (textual order).
- **Nested joins outer.** `tx.transaction(...)` on a txn-scoped `Forge` runs `action` directly — executor sees one `BEGIN`. Top-level delegates to `executor.transaction`.
- **Errors propagate.** Unlike `fetch_forge` queries, failures throw to the caller; `ForgeCardinalityError` for `getSingle` misuse is a `StateError`.

## Caveats / workarounds

- Wrong `query` vs `execute` vs `insert` pairing silently misbehaves (e.g. `query` on an `UPDATE` returns driver-dependent rows). Match: `SELECT`→`query`, `INSERT`→`insert`, `UPDATE/DELETE`→`execute` — or use the builders, which pick correctly (`RETURNING` builders use `getMany`).
- `transaction` return value and throw pass through; to test rollback, throw inside `action` and assert the executor logged `ROLLBACK` / restored rows (see `example/sqlite_query_forge_example.dart` `_MemoryExecutor`).
- Test double shape: record `(sql, args)`, return canned rows; special-case `COUNT(` and filter on `args.first` like the example. `count()` tolerates `int`/`double` counts but throws on strings — mirror that if asserting.
