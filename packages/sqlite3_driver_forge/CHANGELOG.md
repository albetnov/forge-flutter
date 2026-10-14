## 0.1.0

- Initial release in the `the_forge_ecosystem` monorepo (reset from prior
  standalone versioning).
- Background-isolate `SqliteDriver` over `package:sqlite3`, implementing
  both `ForgeExecutor` and `DatabaseExecutor`, with serialized access,
  transactions/savepoints, hot backup, cold restore, and SQLCipher support
  via `SecurePassword`.
