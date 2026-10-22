## 0.2.0

- **Tracing.** `SqliteDriverConfig.onTrace` (and the `onTrace` argument on
  `SqliteDriver.file` / `SqliteDriver.inMemory`) receives one `SqlTrace` per
  statement that reaches the database, after it settles — including when it
  fails. A trace carries the SQL, the bound parameters, the rows returned,
  the rows affected, the last insert id, the duration and the error.
- New `ConsoleSqlTrace` sink prints traces to the debug console, and
  `formatSqlTrace` renders one as text for a custom sink or another driver.
- The printed result is trimmed for reading: the SQL is cut at 500
  characters, a parameter or a cell at 40, and only the first 3 rows are
  shown — the reported count is always the true one.
- The encryption password never reaches a trace: the key travels to the
  worker in the connect handshake and `PRAGMA key` runs inside the worker.
- A sink that throws never breaks the statement it describes.

## 0.1.3

- Widens `sqlite_query_forge` to `^0.4.0` (`MigrationSchema.extend`).
  No API change in this package.

## 0.1.2

- Widens `sqlite_query_forge` to `^0.3.0` (`Column.text` primary key flag).
  No API change in this package.

## 0.1.1

- Widens `sqlite_query_forge` to `^0.2.0` (`CaseWhen`, `MATCH`, `Lit`). No API
  change in this package.

## 0.1.0

- Initial release in the `the_forge_ecosystem` monorepo (reset from prior
  standalone versioning).
- Background-isolate `SqliteDriver` over `package:sqlite3`, implementing
  both `ForgeExecutor` and `DatabaseExecutor`, with serialized access,
  transactions/savepoints, hot backup, cold restore, and SQLCipher support
  via `SecurePassword`.
