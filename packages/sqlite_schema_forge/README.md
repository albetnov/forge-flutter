# SQLite Schema Forge (SSF)

A dead-simple, ultra-minimalist, intuitive, and declarative SQLite schema manager with auto-migration support for Dart & Flutter. Built to replace `forge_schema`.

## Key Features

* **100% Declarative:** Define desired schemas with plain Dart objects—no callback wrappers or raw SQL `CREATE TABLE` strings needed.
* **Auto-Diffing Engine:** Introspects live SQLite `PRAGMA` metadata and auto-generates native `ALTER TABLE` statements or safe copy-and-swap table rebuilds.
* **Fast-Path Boot:** Reads `PRAGMA user_version` on startup (<1ms) to ensure zero overhead on warm launches.
* **Driver Agnostic:** Runs on any SQLite driver (`sqflite`, `sqlite3`, FFI) via a lightweight `DatabaseExecutor` contract.
* **Global Orchestration Ready:** Exposes `plan()` and `applyPlan()` for dry runs and multi-storage migrations (Hive, DataStore, SharedPreferences).

## Quick Start

```dart
import 'package:sqlite_schema_forge/sqlite_schema_forge.dart';

final appSchema = Schema(
  version: 1,
  tables: [
    Table(
      'wallets',
      [
        Column.id(),
        Column.text('name', nullable: false),
        Column.integer('wallet_type_id', nullable: false),
        Column.integer('is_deleted', nullable: false, defaultValue: 0),
        Column.datetime('created_at', defaultValue: RawSql.currentTimestamp),
        Column.datetime('updated_at', defaultValue: RawSql.currentTimestamp),
      ],
      indexes: [
        Index(columns: ['wallet_type_id']), // Auto-named: 'idx_wallets_wallet_type_id'
      ],
    ),
  ],
);

void main() async {
  final db = MyDatabaseDriver(); // Wraps sqflite, sqlite3, or FFI

  await SqliteSchemaForge.enableForeignKeys(db);

  final result = await SqliteSchemaForge.migrate(
    db: db,
    targetSchema: appSchema,
  );

  print('Migrated: ${result.migrated}');
  print('Executed SQL:\n${result.executedSql.join('\n')}');
}

```

## Migration and Query Planning

SSF eliminates manual `up` and `down` migration files. Instead, the diffing engine calculates structural changes at runtime.

### 1. Data Transformation Callbacks

When structural changes require data transformations (like splitting a column or formatting data before a type change), use `onUpgrade` or `onDowngrade`:

```dart
final result = await SqliteSchemaForge.migrate(
  db: db,
  targetSchema: appSchemaV2,
  allowDestructive: true, // Required for column removals or type modifications
  onUpgrade: (db, from, to) async {
    if (from == 1 && to >= 2) {
      // Phase 1: Transform existing data before structural table rebuild
      await db.execute("UPDATE users SET age = 0 WHERE age IS NULL;");
    }
  },
);

```

### 2. Inspecting Plans (`plan()`)

To preview migration queries without writing to the database:

```dart
final MigrationPlan plan = await SqliteSchemaForge.plan(
  db: db,
  targetSchema: appSchema,
);

if (plan.hasDestructiveChanges) {
  print('Warning: Migration requires table rebuilds!');
}

for (final step in plan.steps) {
  print('[${step.type.name}] ${step.description}');
  print('SQL: ${step.sql}\n');
}

```

## Custom Migration Control (`applyPlan`)

If you manage application versioning externally (for example, in a multi-storage setup alongside Hive or DataStore), use `applyPlan`.

Unlike `migrate()`, `applyPlan()` executes the schema diffs **without modifying `PRAGMA user_version**`:

```dart
final plan = await SqliteSchemaForge.plan(db: db, targetSchema: appSchema);

// Executes structural updates without touching PRAGMA user_version
await SqliteSchemaForge.applyPlan(
  db: db,
  plan: plan,
  allowDestructive: true,
);

```

## Foreign Keys

By default, SQLite disables foreign key constraint enforcement on new connections. SSF provides a helper to enable enforcement:

```dart
await SqliteSchemaForge.enableForeignKeys(db);

```

When defining foreign key relationships in `Table`:

```dart
Column.integer(
  'wallet_type_id',
  nullable: false,
  refTable: 'wallet_types',
  refCol: 'id',
);

```

## Triggers and Virtual Tables

`SSF` provides first-class, declarative support for Full-Text Search (FTS3/4/5) virtual tables and custom SQLite triggers. They live directly inside your `Schema` definition alongside standard tables.

The diffing engine automatically inspects `sqlite_master` to detect missing or modified virtual tables and triggers, creating or re-creating them dynamically during migration.

### 1. Virtual Tables (FTS5 / FTS4 / FTS3)

Use `VirtualTable.fts5()` to define full-text search tables with content bindings:

```dart
final transactionsFts = VirtualTable.fts5(
  'transactions_fts',
  columns: ['name', 'note'],
  contentTable: 'transactions', // Binds FTS index directly to content table
  contentRowId: 'id',
);

```

### 2. Triggers

Triggers can be defined using raw SQL execution bodies or via express helpers for common patterns like FTS synchronization.

```dart
// Option A: FTS Sync Preset (Zero-boilerplate)
final ftsInsertTrigger = Trigger.ftsSync(
  name: 'transactions_fts_insert',
  targetTable: 'transactions',
  ftsTable: 'transactions_fts',
  columns: ['name', 'note'],
);

// Option B: Custom Trigger Object
final updateTimestampTrigger = Trigger(
  name: 'update_wallet_timestamp',
  timing: TriggerTiming.before,
  event: TriggerEvent.update,
  targetTable: 'wallets',
  body: 'SET updated_at = CURRENT_TIMESTAMP WHERE id = old.id;',
);

```

---

### Complete Declarative Schema Example

Include standard tables, virtual tables, and triggers together in a single immutable `Schema` object:

```dart
final appSchema = Schema(
  version: 1,
  tables: [
    Table('transactions', [
      Column.id(),
      Column.text('name', nullable: false),
      Column.text('note'),
    ]),
  ],
  virtualTables: [
    VirtualTable.fts5(
      'transactions_fts',
      columns: ['name', 'note'],
      contentTable: 'transactions',
    ),
  ],
  triggers: [
    Trigger.ftsSync(
      name: 'transactions_fts_insert',
      targetTable: 'transactions',
      ftsTable: 'transactions_fts',
      columns: ['name', 'note'],
    ),
  ],
);

// Runs diffing engine across Tables -> Virtual Tables -> Triggers sequentially
await SqliteSchemaForge.migrate(
  db: db,
  targetSchema: appSchema,
);

```

### How Diffing Works Under the Hood

Unlike standard tables that rely on `PRAGMA table_info`, `SSF` inspects SQLite's catalog metadata (`sqlite_master`) for virtual tables and triggers:

1. **Missing Entities:** If a trigger or virtual table does not exist in `sqlite_master`, `SSF` appends `CREATE VIRTUAL TABLE` or `CREATE TRIGGER` steps to the migration plan.
2. **Modified Definitions:** If the declarative SQL definition in code differs from the live SQL stored in `sqlite_master`, `SSF` generates a drop-and-recreate sequence (`DROP ... IF EXISTS` followed by `CREATE ...`).
3. **Dependency Ordering:** `plan()` automatically sorts migration steps ($\text{Tables} \longrightarrow \text{Virtual Tables} \longrightarrow \text{Triggers}$) so referenced tables always exist before triggers or FTS bindings attempt to hook into them.

## Comparasion with `forge_schema`

In `forge_schema`, table definitions, FTS virtual tables, and triggers were built using imperative builder callbacks and wrapped inside `Migration` instances (`emit.define` / `emit.defineAll`). You also had to manually wire execution closures and register every migration script in a `MigrationManager`.

**SQLite Schema Forge (SSF)** replaces step-by-step callback tracking with a **declarative, state-based engine**. You define your current database schema—including standard tables, FTS virtual tables, and triggers—as a single source of truth, and SSF handles all SQL transitions automatically.

### Code Comparison

#### 1. Schema Definition & Registration

**`forge_schema`: Imperative Callbacks & Manager Setup**

```dart
// 1. Define migrations with imperative emit closures
final v1 = Migration(
  version: 1,
  up: (emit) {
    emit.defineAll([
      Forge.table('wallets', (t) {
        t.id();
        t.text('name').notNull();
        t.integer('wallet_type_id').notNull();
        t.boolean('is_deleted').index();
        t.text('created_at').currentTimestamp();
        t.text('updated_at').currentTimestamp();
      }),
      Forge.fts5('transactions_fts', (vt) {
        vt.column('name');
        vt.column('note');
        vt.content('transactions');
        vt.contentRowId('id');
      }),
      Forge.trigger('transactions_fts_insert', (tr) {
        tr.after().insert().on('transactions');
        tr.forEachRow();
        tr.stmt('INSERT INTO transactions_fts(rowid, name, note) VALUES (new.id, new.name, new.note)');
      }),
    ]);
  },
  down: (emit) {
    emit.define(Forge.dropTableIfExists('wallets'));
    emit.define(Forge.dropTableIfExists('transactions_fts'));
  },
);

// 2. Set up MigrationManager with custom execution closures
final manager = MigrationManager(
  (sql) => _db!.execute(sql),
  versionExecutor: (sql) async {
    final result = await _db!.rawQuery('PRAGMA user_version;');
    return result.first.values.first as int;
  },
);

// 3. Register every migration script in sequence
manager.register(v1);
await manager.migrate();

```

**`SSF`: Immutable Declarative Schema & Direct Execution**

```dart
// 1. Declare complete target schema state directly as an immutable Dart object
final appSchema = Schema(
  version: 1,
  tables: [
    Table(
      'wallets',
      [
        Column.id(),
        Column.text('name', nullable: false),
        Column.integer('wallet_type_id', nullable: false),
        Column.integer('is_deleted', index: true),
        Column.datetime('created_at', defaultValue: RawSql.currentTimestamp),
        Column.datetime('updated_at', defaultValue: RawSql.currentTimestamp),
      ],
    ),
  ],
  virtualTables: [
    VirtualTable.fts5(
      'transactions_fts',
      columns: ['name', 'note'],
      contentTable: 'transactions',
    ),
  ],
  triggers: [
    Trigger.ftsSync(
      name: 'transactions_fts_insert',
      targetTable: 'transactions',
      ftsTable: 'transactions_fts',
      columns: ['name', 'note'],
    ),
  ],
);

// 2. Execute migration directly against target state
// SSF auto-diffs Tables -> Virtual Tables -> Triggers sequentially
await SqliteSchemaForge.migrate(
  db: db,
  targetSchema: appSchema,
);

```

### Feature Comparison Matrix

| Feature | `forge_schema` | SQLite Schema Forge (`SSF`) |
| --- | --- | --- |
| **Migration Model** | Imperative (`emit.define` callbacks) | **Declarative State Diffing** |
| **Rollbacks (`down`)** | Written manually for every step | **Auto-derived** from target schema |
| **Migration Tracking** | Requires `MigrationManager` setup & script registration | **Single `Schema` object** passed directly |
| **Driver Contract** | Custom closure callbacks for execution & version reads | Standardized `DatabaseExecutor` interface |
| **Dry Run Support** | ❌ Not available | **Built-in `plan()` API** |
| **Multi-Storage Sync** | ❌ Tied strictly to SQLite `user_version` | **Supports versionless dry-runs via `applyPlan()**` |
| **Triggers & FTS Support** | ✅ Imperative builders (`Forge.fts5`, `Forge.trigger`) | **✅ Declarative objects with `sqlite_master` auto-diffing** |