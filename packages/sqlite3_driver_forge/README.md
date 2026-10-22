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
- **Tracing**: `onTrace:` receives every statement that reaches the database,
  with the SQL, the parameters, the rows returned, the rows affected and the
  duration. `ConsoleSqlTrace` prints it to the debug console.

## Tracing

Pass `onTrace` to see what your app actually asks the database. The sink is
called once per statement, after it settles — including when it fails:

```dart
final driver = SqliteDriver.file(
  '/data/app.db',
  onTrace: const ConsoleSqlTrace(),
);
```

```text
[sql] SELECT * FROM users WHERE age > ? args: [30]
      → 2 rows returned in 3.1ms
      {id: 1, name: 'ada', age: 36}, {id: 2, name: 'grace', age: 45}
[sql] INSERT INTO users (name, age) VALUES (?, ?) args: ['ada', 36]
      → 1 row affected, last id 1 in 4.6ms
[sql] UPDATE users SET age = ? WHERE id = ? args: [37, 1]
      → 1 row affected in 152µs
[sql] SELECT * FROM nope
      → FAILED in 1.6ms: SqliteDriverException (1): ... no such table: nope
```

What the output shows:

| Line | Meaning |
| --- | --- |
| `[sql] …` | The statement as executed, with the bound parameters. |
| `→ N rows returned` | How many rows the statement returned. |
| `→ N row(s) affected` | How many rows it changed. |
| `→ … last id N` | The row id of an insert. |
| `→ FAILED in …` | The failure, with the statement that caused it. |
| `→ … in 2.1ms` | How long it took, including the round trip to the worker isolate. |

The last line shows the first few rows, trimmed for reading: the SQL is cut
at 500 characters, a parameter or a cell at 40, and only the first 3 rows are
shown — the reported count is always the true one. `ConsoleSqlTrace(maxRows:,
maxValueLength:, maxSqlLength:)` changes the limits.

Two things worth knowing:

- **The trace never carries the encryption password.** The key travels to the
  worker in the connect handshake and `PRAGMA key` runs inside the worker, so
  it never passes through a traced statement.
- **Traces hold the full result set.** A sink that stores them decides what
  to keep; `ConsoleSqlTrace` trims only when printing.

Write your own sink for anything else — a counter, a file, a test double:

```dart
void onTrace(SqlTrace trace) {
  if (trace.failed) errors.add(trace);
}
```

### Tracing another driver

`sqlite_query_forge` ships no driver, so if you use `sqflite`, `drift` or
your own binding, the trace recipe is short: wrap the executor, time the
call, and hand the same fields to `formatSqlTrace` from this package (or
render them yourself — the format is four lines).

```dart
class TracingExecutor implements ForgeExecutor {
  TracingExecutor(this._inner);

  final ForgeExecutor _inner;
  final List<SqlTrace> traces = [];

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?>? args]) async {
    final stopwatch = Stopwatch()..start();
    try {
      final rows = await _inner.query(sql, args);
      traces.add(SqlTrace(
        sql: sql,
        args: args ?? const [],
        kind: SqlTraceKind.select,
        rows: rows,
        duration: stopwatch.elapsed,
      ));
      return rows;
    } catch (error, stackTrace) {
      traces.add(SqlTrace(
        sql: sql,
        args: args ?? const [],
        kind: SqlTraceKind.select,
        duration: stopwatch.elapsed,
        error: error,
        stackTrace: stackTrace,
      ));
      rethrow;
    }
  }

  // execute, insert and transaction follow the same shape.
}
```

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
