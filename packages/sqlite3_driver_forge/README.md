# sqlite3_driver_forge

Background-isolate driver over [`package:sqlite3`](https://pub.dev/packages/sqlite3)
for the forge packages. It owns the connection lifecycle, serializes all
access through one connection on a dedicated worker isolate (like drift's
connection manager), and implements both executor contracts at once:

- `ForgeExecutor` (`sqlite_query_forge`)
- `DatabaseExecutor` (`sqlite_schema_forge`)

One instance serves both packages:

```dart
import 'package:sqlite3_driver_forge/sqlite3_driver_forge.dart';
import 'package:sqlite_query_forge/sqlite_query_forge.dart';
import 'package:sqlite_schema_forge/sqlite_schema_forge.dart' as schema;

final driver = SqliteDriver.file('/data/app.db');
await driver.connect();

await schema.SqliteSchemaForge.migrate(
  db: driver, // DatabaseExecutor
  targetSchema: schema.Schema(version: 1, tables: [...]),
);

final forge = Forge(driver); // ForgeExecutor
```

> Both forge packages define `Table`/`Column`, so import one of them with a
> prefix (as above).

## Features

- **Connection manager**: `connect()` / `disconnect()` (`open()` / `close()`
  aliases). The SQLite connection lives on a worker isolate; the main isolate
  never blocks on I/O. Unexpected isolate death fails pending operations
  instead of hanging them.
- **Serialized access**: concurrent callers queue behind a FIFO mutex in call
  order. Transactions (`BEGIN IMMEDIATE`, nested `SAVEPOINT`s) hold the
  connection exclusively; concurrent transactions serialize atomically.
- **First-class config**: file path (exposed via `path` so you can export the
  file yourself), in-memory mode, read-only, foreign keys, journal mode,
  synchronous, busy timeout, VFS, URI filenames.
- **Export**: `backupTo(path)` hot backup via `VACUUM INTO` while connected;
  `restoreFrom(path)` cold file copy while disconnected.
- **SQLCipher**: `connect(cipher: ...)` / `changePassword(...)` with
  `SqlCipherAuthException` on a wrong key.

## Encrypted databases

Build the app with an encryption-capable SQLite. Recommended:
[SQLite3MultipleCiphers](https://github.com/utelle/SQLite3MultipleCiphers)
(`sqlcipher` also works — the driver only speaks `PRAGMA key`, which both
understand). In the **app's** `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    sqlite3:
      source: sqlite3mc # or: sqlcipher
```

Then:

```dart
final password = SecurePassword.text(await loadFromSecureStorage());
try {
  await driver.connect(cipher: password);
} finally {
  password.dispose(); // zero the bytes; the driver retains nothing
}
```

Prefer `SecurePassword.rawKey(bytes)` (32 random bytes): raw keys are
hex-encoded straight from bytes and never materialize as a `String`. See
`SecurePassword` docs for the GC-caveat details.

## Usage

```dart
final driver = SqliteDriver.file('/data/app.db');
await driver.connect();
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

## Additional information

- VM-only (`dart:io`, `dart:isolate`, FFI). No web support.
- Only `null, bool, int, double, String, Uint8List` values cross the isolate
  boundary — anything else throws `ArgumentError` before hitting SQLite.
- SQLite errors surface as `SqliteDriverException` (with extended result
  code); calls while disconnected throw `SqliteDriverClosedException`.
