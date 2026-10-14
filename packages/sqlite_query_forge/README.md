# SQLite Query Forge

A declarative SQLite query builder in Dart, using Dart 3 language features:
records, pattern matching, sealed types, and const class declarations.

The library avoids dynamic reflection and builds SQL string fragments via a
`StringBuffer` accumulator paired with its bound-argument list.

## Core design architecture

### Sealed types

`Expression` is a sealed hierarchy, so a switch over it is checked
exhaustively, and adding a node fails to compile until it is handled.

### Immutability and const expressions

A `SelectBuilder` is immutable, so any chain can be safely shared, cached, or
built up conditionally. `Table` and `Column` declarations are `const` and
canonicalized, so a column reference costs no allocation the second time it is
used.

### Zero allocation on the hot path

A filter such as `users.id.eq(42)` allocates exactly one node, the
`Comparison`. The `Column` on its left is an existing `const` object, not a
fresh wrapper.

## Values are always bound

Every runtime value is a `?` parameter. SQL text is safe by construction, and
a prepared statement can be cached and reused across different argument
values. Identifiers are the one thing that cannot be bound, so they are quoted
in exactly one place, `SqlFragment.writeIdentifier`.

## Quick start

```dart
// The model. The concise class header form is used here, where it pays off.
final class User(
  final int id,
  final String name,
  final String email,
  final bool isActive,
) {
  factory User.fromRow(Map<String, Object?> row) => switch (row) {
    {
      'id': int id,
      'name': String name,
      'email': String email,
      'is_active': int active,
    } =>
      User(id, name, email, active == 1),
    _ => throw FormatException('Invalid user row: $row'),
  };
}

// The table. It needs an explicit constructor, since the concise header form
// cannot be combined with `extends`.
final class UsersTable extends Table<User> {
  const UsersTable() : super('users', mapper: User.fromRow);

  Column<int> get id => const Column.id();
  Column<String> get name => const Column('name');
  Column<bool> get isActive => const Column('is_active');
}

const users = UsersTable();
```

Wire up an executor, then query:

```dart
// See "No bundled driver" at the end for the adapter itself.
final forge = Forge(MySqliteExecutor(db));

// The table mapper is applied for you.
final User user = await forge.selectFrom(users).where(users.id.eq(42)).getSingle();

// Project a few columns into a record instead of a model.
final (int, String) idAndName = await forge
    .selectFrom(users)
    .select([users.id, users.name])
    .map((row) => (row['id'] as int, row['name'] as String))
    .getSingle();
```

Filters compose immutably, so a chain can be built conditionally without
tracking whether a filter is the first one:

```dart
var query = forge.selectFrom(users).where(users.isActive.eq(true));
if (search != null) query = query.andWhere(users.name.like('%$search%'));
if (since != null) query = query.orWhere(users.id.gt(since));
```

## Joins

Column-to-column equality is expressed explicitly. `eq` takes a value, so a
column-to-column comparison needs its own spelling, since Dart cannot overload
on argument type:

```dart
final transactions = TransactionsTable();

final rows = await forge
    .selectFrom(users)
    .leftJoin(
      transactions.sourceAs('t'),
      on: users
          .qualify(users.id)
          .sameAs(transactions.qualify(transactions.userId, 't')),
    )
    .where(transactions.qualify(transactions.amount, 't').gt(100))
    .getMany();
```

`Column.sameAs` renders an unqualified name, because a `Column` carries no
table. Qualify whichever side needs it, and match the alias the join binds
under:

```dart
// "t"."user_id", not "transactions"."user_id"
final on = users.qualify(users.id).sameAs(transactions.qualify(transactions.userId, 't'));
```

Whatever spelling qualifies the column, the alias is a plain string and nothing
checks it against the source the join binds. `TableSource.reference` reports
the name a source actually binds, so passing it through is safer than retyping:

```dart
final t = transactions.sourceAs('t');
final on = users.qualify(users.id, t.reference)
    .sameAs(transactions.qualify(transactions.userId, t.reference));
```

### Opt-in: qualifyAs

If writing the table twice bothers you, `qualify.dart` carries a column-first
spelling. It is not exported by the main entry point, so it is opted into
explicitly:

```dart
import 'package:sqlite_query_forge/sqlite_query_forge.dart';
import 'package:sqlite_query_forge/qualify.dart'; // the opt-in
```

```dart
final t = transactions.sourceAs('t');

final rows = await forge
    .selectFrom(users)
    .leftJoin(
      t,
      on: users.id.qualifyAs('u').sameAs(transactions.userId.qualifyAs('t')),
    )
    .where(transactions.amount.qualifyAs('t').gt(100))
    .getMany();
```

`users.name.qualifyAs('t')` compiles to exactly what
`users.qualify(users.name, 't')` compiles to. It exists as a convenience, not
as a second built-in: `Table.qualify` stays the documented default, and the
same warning about matching the alias applies.

## Writes

Writes start from the same facade and stay immutable, so a conditional filter
needs no branching at the call site. An `UPDATE` or `DELETE` with no `where`
touches every row.

```dart
// The new rowid.
final id = await forge.insertInto(users).values({
  'name': 'Ada',
  'email': 'ada@example.com',
}).execute();

// One statement, many rows.
await forge
    .insertInto(users)
    .valuesAll([
      {'name': 'Ada', 'email': 'ada@example.com'},
      {'name': 'Grace', 'email': 'grace@example.com'},
    ])
    .execute();

// Affected rows.
final updated = await forge
    .update(users)
    .values({'is_active': false})
    .where(users.id.gt(1))
    .execute();
final deleted = await forge.deleteFrom(users).where(users.id.eq(1)).execute();
```

## Upserts

A value that is an expression is written as a reference rather than bound,
which is how `excluded` is reached:

```dart
await forge
    .insertInto(users)
    .values({'email': 'ada@example.com', 'name': 'ada'})
    .onConflictIgnore()
    .execute();

await forge
    .insertInto(users)
    .values({'email': 'ada@example.com', 'name': 'ada'})
    .onConflictUpdate({
      'name': const RawSql('excluded."name"'),
    }, columns: [users.email])
    .execute();
```

## Returning

`returning` turns a write into a read, so rows come back through `getMany()`
instead of a rowid or an affected count. With no columns it emits
`RETURNING *`, following the same convention an empty `select` uses. Needs
SQLite 3.35 or newer.

```dart
final rows = await forge
    .insertInto(users)
    .values({'name': 'Ada'})
    .returning([users.id, users.name])
    .getMany();

// Every column comes back.
final whole = await forge
    .insertInto(users)
    .values({'name': 'Ada'})
    .returning()
    .getMany();
```

## Transactions

`transaction` hands the action a `Forge` bound to the transaction, and every
statement issued through it joins that transaction. A nested call joins the
open transaction rather than issuing a second `BEGIN`. A throw rolls the
transaction back and propagates.

```dart
await forge.transaction((tx) async {
  await tx.insertInto(users).values({'name': 'Ada'}).execute();
  await tx.transaction((nested) async {
    await nested.deleteFrom(users).where(users.id.eq(1)).execute();
  });
});
```

## Compiled SQL

Every builder exposes the same compile step twice: `compile()` for the SQL and
its arguments together, `toSql()` and `getRawArgs()` for one or the other.

```dart
final query = forge.selectFrom(users).where(users.isActive.eq(true));

query.compile();       // CompiledQuery('SELECT * WHERE "is_active" = ?', [1])
query.toSql();         // 'SELECT * FROM "users" WHERE "is_active" = ?'
query.getRawArgs();    // [1]
```

`InsertBuilder.execute()` already returns the new rowid. When the driver backs
`ForgeExecutor.insert` with something that does not, `getLastInsertId()` asks
SQLite directly:

```dart
final id = await forge.insertInto(users).values({'name': 'Ada'}).getLastInsertId();
```

It reads `last_insert_rowid()`, which is a connection-wide value: call it right
after the insert on the same executor, before any other insert lands.

## JSON projections

`JsonObject` builds a `json_object()` call over a map of label to expression,
so a joined row can travel as one JSON value:

```dart
final rows = await forge
    .selectFrom(users)
    .leftJoin(
      transactions.sourceAs('t'),
      on: users.qualify(users.id, 'u').sameAs(
        transactions.qualify(transactions.userId, 't'),
      ),
    )
    .select([
      JsonObject({
        'id': users.qualify(users.id, 'u'),
        'name': users.qualify(users.name, 'u'),
      }).alias('user'),
      JsonObject({
        'amount': transactions.qualify(transactions.amount, 't'),
      }).alias('tx'),
    ])
    .map((row) => (row['user'] as String, row['tx'] as String))
    .getMany();
```

```sql
SELECT json_object('id', "u"."id", 'name', "u"."name") AS "user",
       json_object('amount', "t"."amount") AS "tx"
FROM "users"
LEFT JOIN "transactions" AS "t" ON "users"."id" = "t"."user_id"
```

Labels become SQL string literals, quoted in `SqlFragment.writeLiteral`; every
value is an expression, so it renders itself and binds nothing. A `JsonObject`
is an expression, so it nests, it can be aliased, and it can appear anywhere an
expression can. An empty map compiles to `json_object()`, which returns `{}`.

```dart
// Nested objects, no extra API.
JsonObject({'id': users.id, 'profile': JsonObject({'name': users.name})})
```

## Migrations

A column can also declare how it is created, so the query path and the
migration path read one declaration:

```dart
final class UsersTable extends Table<User> {
  const UsersTable() : super('users', mapper: User.fromRow);

  Column<int> get id => const Column.id();

  Column<String> get name => const Column.text('name', nullable: false);

  Column<String> get email =>
      const Column.text('email', nullable: false, unique: true);

  Column<bool> get isActive =>
      const Column.integer('is_active', nullable: false, defaultValue: 1);

  @override
  List<Column<Object>> get columns => [id, name, email, isActive];
}
```

The named constructors — `Column.id`, `.integer`, `.text`, `.real`, `.blob`,
`.dateTime` — attach the DDL flags to the very column the queries use, so a
name or a flag is written once. They are `const` generative constructors, so a
column still canonicalizes and `users.id` costs no allocation. A column built
by the plain `const Column('name')` declares no type, and stays query-only.

`SchemaColumn` is `sqlite_schema_forge.Column` under an alias, so a table file
never imports the schema package — whose own `Column` and `Table` would collide
with the query side's. `toSchemaTable()` compiles the list into DDL, and
`schemaOf` collects the tables under one version:

```dart
final targetSchema = schemaOf(version: 2, tables: [users, transactions]);

await SqliteSchemaForge.migrate(
  db: ForgeDatabaseExecutor(forge),
  targetSchema: targetSchema,
);
```

A `Column.dateTime` taking a `RawSql` default writes `CURRENT_TIMESTAMP`
verbatim, while a `String` default is quoted.

`ForgeDatabaseExecutor` presents a `ForgeExecutor` as the migrator's
`DatabaseExecutor`, so one adapter drives both. Tables that never migrate
leave `columns` empty, and `toSchemaTable()` refuses them rather than emitting
`CREATE TABLE t ()`.

Indexes, virtual tables, triggers and composite keys stay in the migration
schema, which is where those concepts already live.

## Putting it together

One adapter, created once, serves both halves:

```dart
final class SqfliteExecutor implements ForgeExecutor {
  SqfliteExecutor(this._db);

  final Database _db;

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?>? args]) =>
      _db.rawQuery(sql, args);

  @override
  Future<int> execute(String sql, [List<Object?>? args]) =>
      _db.rawUpdate(sql, args);

  @override
  Future<int> insert(String sql, [List<Object?>? args]) =>
      _db.rawInsert(sql, args);

  @override
  Future<T> transaction<T>(Future<T> Function(ForgeExecutor txn) action) =>
      _db.transaction((txn) => action(SqfliteExecutor(txn)));
}

final executor = SqfliteExecutor(db);
final forge = Forge(executor);

await SqliteSchemaForge.enableForeignKeys(ForgeDatabaseExecutor(executor));

await SqliteSchemaForge.migrate(
  db: ForgeDatabaseExecutor(executor),
  targetSchema: schemaOf(version: 1, tables: [users, transactions]),
);
```

That stamps `PRAGMA user_version`, which is what later runs compare against.
Changing a schema means adding a flag to a column's constructor and raising
the version:

```dart
// in UsersTable
Column<String> get nickname => const Column.text('nickname');

// at the call site
final targetSchema = schemaOf(version: 2, tables: [users, transactions]);
```

Adding a column produces an `ALTER TABLE ... ADD COLUMN`; removing one is a
destructive table rebuild, so it needs `allowDestructive: true`. After the
migration, the declared tables are the query path — same object, same names:

```dart
// Write. The new rowid comes straight back.
final userId = await forge
    .insertInto(users)
    .values({'name': 'Ada', 'email': 'ada@example.com', 'is_active': true})
    .execute();

await forge.transaction((tx) async {
  await tx
      .insertInto(transactions)
      .values({'user_id': userId, 'amount': 250})
      .execute();
  await tx
      .update(users)
      .values({'is_active': true})
      .where(users.id.eq(userId))
      .execute();
});

// Read. The mapper is applied for you.
final List<User> active = await forge
    .selectFrom(users)
    .where(users.isActive.eq(true))
    .orderBy([OrderBy(users.name)])
    .getMany();
```

## No bundled driver

The query side needs no driver of its own. It does depend on
`sqlite_schema_forge` for the bridge above, and ships no driver: implement
`ForgeExecutor` over the binding you already use, and hand it to `Forge`:

```dart
final class SqfliteExecutor implements ForgeExecutor {
  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?>? args]) =>
      db.rawQuery(sql, args);

  // ...
}

final forge = Forge(SqfliteExecutor());
```

> No code generation: declarations stay hand-written.
