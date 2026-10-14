---
name: sqlite3-driver-forge-driver
description: SqliteDriver lifecycle, config, query/execute/insert, transactions, backup/restore, error types.
---

# `SqliteDriver`: connect → use → disconnect

Background-isolate driver over `package:sqlite3`. One instance implements
both `ForgeExecutor` (query_forge) and `DatabaseExecutor` (schema_forge),
so pass the same driver to `Forge(driver)` and
`SqliteSchemaForge.migrate(db: driver, ...)`.

```dart
final driver = SqliteDriver.file('/data/app.db');
await driver.connect(); // or: await driver.connect(cipher: password);
try {
  await driver.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);');
  final id = await driver.insert('INSERT INTO t (v) VALUES (?);', ['hi']);
  final rows = await driver.query('SELECT * FROM t WHERE id = ?;', [id]);
  await driver.transaction((txn) async {
    await txn.execute("INSERT INTO t (v) VALUES ('atomic');");
  });
  await driver.backupTo('/data/app.backup.db');
} finally {
  await driver.disconnect();
}
```

## Configuration

`SqliteDriver.file(path, {readOnly, foreignKeys: true, journalMode: 'WAL', synchronous, busyTimeoutMs: 5000, cipherMigrate: false, vfs, uri, cipher})` or `SqliteDriver.inMemory({...})`. Full form: `SqliteDriver(config: SqliteDriverConfig(...))`. `connect({cipher})` overrides `config.cipher` for that connect only. `journalMode`/`synchronous` are skipped when read-only or in-memory. Only `null, bool, int, double, String, Uint8List` args cross the isolate — anything else throws `ArgumentError` before SQLite.

## Instance management

`connect()`/`open()` spawns the worker; double-connect throws `StateError`. `disconnect()`/`close()`/`dispose()` are idempotent: sends close, kills the isolate, fails pendings with `SqliteDriverClosedException`. `isConnected`, `isInMemory`, and `path` (copy/export the file yourself, only while disconnected). `restoreFrom(src)` is a cold copy — requires disconnected, `UnsupportedError` for memory DBs. Never retain the driver past `dispose`; never let a `txn` callback executor escape its closure.

## Behavior contracts

- **Serialized single connection.** Concurrent callers queue FIFO; concurrent transactions serialize atomically. Ops inside a `transaction` action bypass the mutex via zone token; outsiders queue behind it.
- **Nesting is savepoints.** Top-level uses `BEGIN IMMEDIATE`/`COMMIT`/`ROLLBACK`; nested `transaction()` uses `SAVEPOINT forge_sp_<depth>` — inner rollback preserves outer work.
- **`execute` returns count, `insert` returns rowid.** The single `Future<int> execute` satisfies both forge interfaces (`Future<int>` is a `Future<void>`).

## Caveats / workarounds

- `VACUUM INTO` (`backupTo`) is forbidden inside a transaction — SQLite errors; back up outside txns.
- Errors are `SqliteDriverException(message, resultCode?)`; wrong-key probe failure is `SqlCipherAuthException`; calls while down are `SqliteDriverClosedException`. Worker death fails pendings with "connection lost" instead of hanging.
- VM-only (`dart:io`, isolates, FFI) — no web. `query` vs `execute` vs `insert` pairing matters like in the `forge` skill. Both forge packages define `Table`/`Column`: prefix one import (`import '...sqlite_schema_forge.dart' as schema;`).
