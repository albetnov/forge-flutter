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
