---
name: sqlite-query-forge-schema-bridge
description: Table.columns toSchemaTable schemaOf, ForgeDatabaseExecutor adapter sharing one driver with migrator.
---

# Schema bridge: one declaration, queries + migrations

`Table<T>` subclasses declare query columns; `columns` exposes the same
declaration to `sqlite_schema_forge`. One driver adapter serves both.

```dart
final class UsersTable extends Table<User> {
  const UsersTable() : super('users', mapper: User.fromRow);
  Column<int> get id => const Column.id();
  Column<String> get name => const Column.text('name', nullable: false);
  @override
  List<Column<Object>> get columns => [id, name]; // migrator reads this
}
const users = UsersTable();

// Migrate with the same declaration:
final schema = schemaOf(version: 2, tables: [users]);
await SqliteSchemaForge.migrate(db: ForgeDatabaseExecutor(myForgeExecutor), targetSchema: schema);
```

## Configuration

- `Table(tableName, mapper:)`: `mapper` is `Map<String,Object?> → T`. Getters return `const Column.*` (typed `Column<int>` etc., listed as `Column<Object>` in `columns`).
- Only typed factories are migratable (`id/integer/text/dateTime/real/blob`). Plain `Column('x')` has `type == null`.
- `schemaOf(version:, tables:)` → `sqlite_schema_forge` `Schema` (aliased `MigrationSchema`; no direct import of the schema package needed — bridge typedefs `SchemaColumn/SchemaTable/SchemaDataType/SchemaRawSql` avoid the `Column`/`Table` name clash).
- `ForgeDatabaseExecutor(forgeExecutor)` adapts `ForgeExecutor` → `DatabaseExecutor` (`rawQuery`→`query`, `execute`→`execute`, `transaction` wraps txn). Use it so queries and migrations share one connection/txn semantics.

## Instance management

Tables and columns are immutable, `const`-constructible descriptors. No
`dispose`. `ForgeDatabaseExecutor` is a thin wrapper — no lifecycle, owns
nothing; dispose the underlying driver, never the wrapper.

## Behavior contracts

- `toSchemaTable()` maps `ColumnType.integer/text/real/blob` → schema `DataType`; a `RawSql` default becomes schema `RawSql` (verbatim, e.g. `CURRENT_TIMESTAMP`), other defaults are quoted/bound per type.
- FK passes through: `referencesTable/referencesColumn` on the query `Column` → schema `Column`.

## Caveats / workarounds

- `columns == []` (default) means query-only: `toSchemaTable()`/`schemaOf()` throw `StateError` (`declares no columns, so it cannot be created`). Workaround: leave empty for join-only/projection tables; list every persisted column otherwise.
- Typeless column throws: `declares no type. Build it with Column.integer, Column.text, ...`. Workaround: switch plain `Column('x')` getters used in migrations to typed factories; keep plain ones only for query-only tables.
- `schemaOf` covers tables only — indexes come from the schema side (`Table(name, cols, indexes:)` there) or are added to the target `Schema` by hand; virtual tables/triggers are schema-side-only and never come from `columns`.
