import 'package:sqlite_query_forge/sqlite_query_forge.dart';
import 'package:test/test.dart';

String sqlOf(Statement statement) => statement.compile().sql;

final class User {
  User(this.id, this.name, this.isActive);

  final int id;
  final String name;
  final bool isActive;

  factory User.fromRow(Map<String, Object?> row) => switch (row) {
    {'id': int id, 'name': String name, 'is_active': int active} => User(
      id,
      name,
      active == 1,
    ),
    _ => throw FormatException('bad user row: $row'),
  };
}

final class TransactionsTable extends Table<User> {
  const TransactionsTable() : super('transactions', mapper: User.fromRow);

  Column<int> get id => const Column('id');
  Column<int> get userId => const Column('user_id');
  Column<int> get amount => const Column('amount');
}

final class UsersTable extends Table<User> {
  const UsersTable() : super('users', mapper: User.fromRow);

  Column<int> get id => const Column('id');
  Column<String> get name => const Column('name');
  Column<String> get email => const Column('email');
  Column<bool> get isActive => const Column('is_active');
}

const users = UsersTable();
const transactions = TransactionsTable();

final userRow = {'id': 1, 'name': 'Ada', 'is_active': 1};

final class _FakeExecutor implements ForgeExecutor {
  List<Map<String, Object?>> rows = const [];
  int rowid = 7;
  int affected = 3;
  int began = 0;

  final List<CompiledQuery> recorded = [];

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    recorded.add(CompiledQuery(sql, args ?? const []));
    return rows;
  }

  @override
  Future<int> execute(String sql, [List<Object?>? args]) async {
    recorded.add(CompiledQuery(sql, args ?? const []));
    return affected;
  }

  @override
  Future<int> insert(String sql, [List<Object?>? args]) async {
    recorded.add(CompiledQuery(sql, args ?? const []));
    return rowid;
  }

  @override
  Future<T> transaction<T>(Future<T> Function(ForgeExecutor txn) action) async {
    began++;
    return action(this);
  }
}

void main() {
  _FakeExecutor driver() => _FakeExecutor();

  Forge forge(_FakeExecutor executor) => Forge(executor);

  group('insert', () {
    test('binds every value in map order', () {
      final q = forge(driver())
          .insertInto(users)
          .values({'name': 'Ada', 'email': 'ada@example.com'})
          .compile();
      expect(q.sql, 'INSERT INTO "users" ("name", "email") VALUES (?, ?)');
      expect(q.args, ['Ada', 'ada@example.com']);
    });

    test('execute routes to insert and returns the rowid', () async {
      final executor = driver();
      final rowid = await forge(executor)
          .insertInto(users)
          .values({'name': 'Ada'})
          .execute();
      expect(rowid, 7);
      expect(
        executor.recorded.single.sql,
        'INSERT INTO "users" ("name") VALUES (?)',
      );
    });

    test('a bool value binds as 1/0', () {
      final q = forge(driver())
          .insertInto(users)
          .values({'name': 'Ada', 'is_active': true})
          .compile();
      expect(q.sql, 'INSERT INTO "users" ("name", "is_active") VALUES (?, ?)');
      expect(q.args, ['Ada', 1]);
    });

    test('valuesAll writes one statement with many row tuples', () {
      final q = forge(driver()).insertInto(users).valuesAll([
        {'name': 'Ada', 'email': 'ada@example.com'},
        {'name': 'Grace', 'email': 'grace@example.com'},
      ]).compile();
      expect(
        q.sql,
        'INSERT INTO "users" ("name", "email") '
        'VALUES (?, ?), (?, ?)',
      );
      expect(q.args, ['Ada', 'ada@example.com', 'Grace', 'grace@example.com']);
    });

    test('valuesAll matches rows by key set, not by key order', () {
      final q = forge(driver()).insertInto(users).valuesAll([
        {'name': 'Ada', 'email': 'ada@example.com'},
        {'email': 'grace@example.com', 'name': 'Grace'},
      ]).compile();
      expect(
        q.sql,
        'INSERT INTO "users" ("name", "email") VALUES (?, ?), (?, ?)',
      );
      expect(q.args, ['Ada', 'ada@example.com', 'Grace', 'grace@example.com']);
    });

    test('valuesAll rejects rows naming different columns', () {
      expect(
        () => forge(driver()).insertInto(users).valuesAll([
          {'name': 'Ada'},
          {'email': 'grace@example.com'},
        ]).compile(),
        throwsStateError,
      );
    });

    test('valuesAll rejects a row with a missing column', () {
      expect(
        () => forge(driver()).insertInto(users).valuesAll([
          {'name': 'Ada', 'email': 'ada@example.com'},
          {'name': 'Grace'},
        ]).compile(),
        throwsStateError,
      );
    });

    test('an empty row or row list is rejected rather than compiled', () {
      expect(
        () => forge(driver()).insertInto(users).values({}).compile(),
        throwsStateError,
      );
      expect(
        () => forge(driver()).insertInto(users).valuesAll([]).compile(),
        throwsStateError,
      );
    });

    test('an insert with no values at all is rejected', () {
      expect(
        () => forge(driver()).insertInto(users).compile(),
        throwsStateError,
      );
    });

    test('is immutable: a derived chain leaves the original alone', () {
      final base = forge(driver()).insertInto(users).values({'name': 'Ada'});
      final other = base.values({'name': 'Grace'});
      expect(base.compile().args, ['Ada']);
      expect(other.compile().args, ['Grace']);
    });

    test('onConflictIgnore', () {
      final q = forge(driver())
          .insertInto(users)
          .values({'email': 'ada@example.com'})
          .onConflictIgnore()
          .compile();
      expect(
        q.sql,
        'INSERT INTO "users" ("email") VALUES (?) ON CONFLICT DO NOTHING',
      );
    });

    test('onConflictUpdate binds the target and the assignments', () {
      final q = forge(driver())
          .insertInto(users)
          .values({'email': 'ada@example.com', 'name': 'ada'})
          .onConflictUpdate({'name': 'ada lovelace'}, columns: [users.email])
          .compile();
      expect(
        q.sql,
        'INSERT INTO "users" ("email", "name") VALUES (?, ?) '
        'ON CONFLICT ("email") DO UPDATE SET "name" = ?',
      );
      expect(q.args, ['ada@example.com', 'ada', 'ada lovelace']);
    });

    test('onConflictUpdate without a target prefixes the assignment', () {
      final q = forge(driver())
          .insertInto(users)
          .values({'email': 'ada@example.com'})
          .onConflictUpdate({'name': 'ada lovelace'})
          .compile();
      expect(
        q.sql,
        'INSERT INTO "users" ("email") VALUES (?) '
        'ON CONFLICT DO UPDATE SET "name" = ?',
      );
    });

    test('an expression value writes a reference, not a bound value', () {
      final q = forge(driver())
          .insertInto(users)
          .values({'email': 'ada@example.com'})
          .onConflictUpdate(
            {'name': const RawSql('excluded."name"')},
            columns: [users.email],
          )
          .compile();
      expect(
        q.sql,
        'INSERT INTO "users" ("email") VALUES (?) '
        'ON CONFLICT ("email") DO UPDATE SET "name" = excluded."name"',
      );
      expect(q.args, ['ada@example.com']);
    });

    test('returning turns the write into a read', () async {
      final executor = driver()..rows = [userRow];
      final rows = await forge(executor)
          .insertInto(users)
          .values({'name': 'Ada'})
          .returning([users.id, users.name])
          .getMany();
      expect(rows, [userRow]);
      expect(
        executor.recorded.single.sql,
        'INSERT INTO "users" ("name") VALUES (?) RETURNING "id", "name"',
      );
    });

    test('returning with no columns emits RETURNING *', () {
      final q = forge(driver())
          .insertInto(users)
          .values({'name': 'Ada'})
          .returning()
          .compile();
      expect(q.sql, 'INSERT INTO "users" ("name") VALUES (?) RETURNING *');
      expect(q.args, ['Ada']);
    });

    test('an explicit empty column list also emits RETURNING *', () {
      final q = forge(driver())
          .insertInto(users)
          .values({'name': 'Ada'})
          .returning([])
          .compile();
      expect(q.sql, 'INSERT INTO "users" ("name") VALUES (?) RETURNING *');
    });

    test('a returning insert cannot be run as a rowid insert', () {
      expect(
        () =>
            forge(driver())
                .insertInto(users)
                .values({'name': 'Ada'})
                .returning([users.id])
                .execute(),
        throwsStateError,
      );
    });

    test('a plain insert cannot be run as a read', () {
      expect(
        () =>
            forge(driver()).insertInto(users).values({'name': 'Ada'}).getMany(),
        throwsStateError,
      );
    });

    test('a builder built without an executor fails loudly on a terminal', () {
      expect(
        () => InsertBuilder(users.source).values({'name': 'Ada'}).execute(),
        throwsStateError,
      );
    });
  });

  group('update', () {
    test('binds the assignments and the filter', () {
      final q = forge(driver())
          .update(users)
          .values({'name': 'Ada', 'is_active': false})
          .where(users.id.eq(42))
          .compile();
      expect(
        q.sql,
        'UPDATE "users" SET "name" = ?, "is_active" = ? WHERE "id" = ?',
      );
      expect(q.args, ['Ada', 0, 42]);
    });

    test('execute returns the affected row count', () async {
      final executor = driver();
      expect(
        await forge(executor).update(users).values({'name': 'Ada'}).execute(),
        3,
      );
      expect(executor.recorded.single.sql, 'UPDATE "users" SET "name" = ?');
    });

    test('a missing filter updates every row', () {
      expect(
        sqlOf(UpdateStatement(users.source, {'name': 'Ada'})),
        'UPDATE "users" SET "name" = ?',
      );
    });

    test('values rejects an empty map', () {
      expect(() => forge(driver()).update(users).values({}), throwsStateError);
    });

    test('where replaces, andWhere and orWhere accumulate', () {
      final base = forge(driver()).update(users).values({'name': 'Ada'});
      expect(
        base.where(users.id.eq(1)).compile().sql,
        'UPDATE "users" SET "name" = ? WHERE "id" = ?',
      );
      expect(
        base.where(users.id.eq(1)).andWhere(users.name.eq('a')).compile().sql,
        'UPDATE "users" SET "name" = ? WHERE "id" = ? AND "name" = ?',
      );
      expect(
        base.where(users.id.eq(1)).orWhere(users.id.eq(2)).compile().sql,
        'UPDATE "users" SET "name" = ? WHERE "id" = ? OR "id" = ?',
      );
    });

    test('andWhere parenthesises a disjunction', () {
      final q = forge(driver())
          .update(users)
          .values({'name': 'Ada'})
          .where(users.id.eq(1))
          .orWhere(users.id.eq(2))
          .andWhere(users.id.eq(3))
          .compile();
      expect(
        q.sql,
        'UPDATE "users" SET "name" = ? '
        'WHERE ("id" = ? OR "id" = ?) AND "id" = ?',
      );
    });

    test('an expression value writes a reference, not a bound value', () {
      final q = forge(driver())
          .update(users)
          .values({'name': const RawSql('excluded."name"')})
          .where(users.id.eq(1))
          .compile();
      expect(
        q.sql,
        'UPDATE "users" SET "name" = excluded."name" WHERE "id" = ?',
      );
      expect(q.args, [1]);
    });

    test('returning turns the write into a read', () async {
      final executor = driver()..rows = [userRow];
      final rows = await forge(executor)
          .update(users)
          .values({'name': 'Ada'})
          .where(users.id.eq(1))
          .returning([users.id, users.name])
          .getMany();
      expect(rows, [userRow]);
      expect(
        executor.recorded.single.sql,
        'UPDATE "users" SET "name" = ? WHERE "id" = ? '
        'RETURNING "id", "name"',
      );
    });

    test('returning with no columns emits RETURNING *', () {
      final q = forge(driver())
          .update(users)
          .values({'name': 'Ada'})
          .where(users.id.eq(1))
          .returning()
          .compile();
      expect(q.sql, 'UPDATE "users" SET "name" = ? WHERE "id" = ? RETURNING *');
    });

    test('a returning update cannot be run as a row count', () {
      expect(
        () =>
            forge(driver())
                .update(users)
                .values({'name': 'Ada'})
                .returning([users.id])
                .execute(),
        throwsStateError,
      );
    });

    test('a plain update cannot be run as a read', () {
      expect(
        () => forge(driver()).update(users).values({'name': 'Ada'}).getMany(),
        throwsStateError,
      );
    });

    test('a builder built without an executor fails loudly on a terminal', () {
      expect(
        () => UpdateBuilder(users.source).values({'name': 'Ada'}).execute(),
        throwsStateError,
      );
    });
  });

  group('delete', () {
    test('binds the filter', () async {
      final executor = driver();
      await forge(executor).deleteFrom(users).where(users.id.eq(42)).execute();
      expect(
        executor.recorded.single.sql,
        'DELETE FROM "users" WHERE "id" = ?',
      );
      expect(executor.recorded.single.args, [42]);
    });

    test('where replaces, andWhere and orWhere accumulate', () {
      final base = forge(driver()).deleteFrom(users);
      expect(
        base.where(users.id.eq(1)).andWhere(users.name.eq('a')).compile().sql,
        'DELETE FROM "users" WHERE "id" = ? AND "name" = ?',
      );
      expect(
        base.where(users.id.eq(1)).orWhere(users.id.eq(2)).compile().sql,
        'DELETE FROM "users" WHERE "id" = ? OR "id" = ?',
      );
    });

    test('returning turns the write into a read', () async {
      final executor = driver()..rows = [userRow];
      final rows = await forge(executor)
          .deleteFrom(users)
          .where(users.id.eq(1))
          .returning([users.id])
          .getMany();
      expect(rows, [userRow]);
      expect(
        executor.recorded.single.sql,
        'DELETE FROM "users" WHERE "id" = ? RETURNING "id"',
      );
    });

    test('returning with no columns emits RETURNING *', () {
      final q = forge(driver())
          .deleteFrom(users)
          .where(users.id.eq(1))
          .returning()
          .compile();
      expect(q.sql, 'DELETE FROM "users" WHERE "id" = ? RETURNING *');
    });

    test('a returning delete cannot be run as a row count', () {
      expect(
        () =>
            forge(driver())
                .deleteFrom(users)
                .where(users.id.eq(1))
                .returning([users.id])
                .execute(),
        throwsStateError,
      );
    });

    test('a builder built without an executor fails loudly on a terminal', () {
      expect(
        () => DeleteBuilder(users.source).where(users.id.eq(1)).execute(),
        throwsStateError,
      );
    });
  });

  group('transaction', () {
    test('runs the action against a Forge bound to the transaction', () async {
      final executor = driver();
      final rowid = await forge(executor).transaction((tx) async {
        return tx.insertInto(users).values({'name': 'Ada'}).execute();
      });
      expect(rowid, 7);
      expect(executor.began, 1);
      expect(
        executor.recorded.single.sql,
        'INSERT INTO "users" ("name") VALUES (?)',
      );
    });

    test('returns the value the action produced', () async {
      expect(await forge(driver()).transaction((tx) async => 42), 42);
    });

    test('the outer Forge also writes inside its own transaction', () async {
      final executor = driver();
      await forge(executor).transaction((tx) async {
        await forge(executor).update(users).values({'name': 'Ada'}).execute();
        return null;
      });
      expect(executor.began, 1);
      expect(executor.recorded.map((q) => q.sql), [
        'UPDATE "users" SET "name" = ?',
      ]);
    });

    test('a nested transaction joins the outer one', () async {
      final executor = driver();
      await forge(executor).transaction((tx) async {
        await tx.insertInto(users).values({'name': 'Ada'}).execute();
        await tx.transaction((nested) async {
          await nested.deleteFrom(users).where(users.id.eq(1)).execute();
          return null;
        });
        return null;
      });
      expect(executor.began, 1);
      expect(executor.recorded.map((q) => q.sql), [
        'INSERT INTO "users" ("name") VALUES (?)',
        'DELETE FROM "users" WHERE "id" = ?',
      ]);
    });

    test('reads inside a transaction use the transaction', () async {
      final executor = driver()..rows = [userRow];
      final rows = await forge(executor)
          .transaction((tx) => tx.selectFrom(users).getMany());
      expect(rows.single.name, 'Ada');
      expect(executor.began, 1);
    });

    test(
      'a throwing action propagates and clears the open transaction',
      () async {
        final executor = driver();
        final outer = forge(executor);
        await expectLater(
          () => outer.transaction((tx) async {
            await tx.insertInto(users).values({'name': 'Ada'}).execute();
            throw StateError('boom');
          }),
          throwsStateError,
        );
        await outer.transaction((tx) async => 1);
        expect(executor.began, 2);
      },
    );
  });

  group('quick access', () {
    test('toSql and getRawArgs on a read chain', () {
      final query = forge(driver())
          .selectFrom(users)
          .where(users.id.eq(42))
          .limit(10);
      expect(query.toSql(), 'SELECT * FROM "users" WHERE "id" = ? LIMIT ?');
      expect(query.getRawArgs(), [42, 10]);
    });

    test('toSql and getRawArgs on each write chain', () {
      final insert = forge(driver())
          .insertInto(users)
          .values({'name': 'Ada', 'is_active': true});
      expect(
        insert.toSql(),
        'INSERT INTO "users" ("name", "is_active") VALUES (?, ?)',
      );
      expect(insert.getRawArgs(), ['Ada', 1]);

      final update = forge(driver())
          .update(users)
          .values({'name': 'Ada'})
          .where(users.id.eq(1));
      expect(update.toSql(), 'UPDATE "users" SET "name" = ? WHERE "id" = ?');
      expect(update.getRawArgs(), ['Ada', 1]);

      final delete = forge(driver()).deleteFrom(users).where(users.id.eq(1));
      expect(delete.toSql(), 'DELETE FROM "users" WHERE "id" = ?');
      expect(delete.getRawArgs(), [1]);
    });

    test('agrees with compile()', () {
      final query = forge(driver()).selectFrom(users).where(users.id.eq(1));
      expect(query.toSql(), query.compile().sql);
      expect(query.getRawArgs(), query.compile().args);
    });
  });

  group('last insert id', () {
    test('asks SQLite for the rowid it last assigned', () async {
      final executor = driver();
      final insert = forge(executor).insertInto(users).values({'name': 'Ada'});
      executor.rows = [
        {'last_insert_rowid()': 42},
      ];
      expect(await insert.getLastInsertId(), 42);
      expect(executor.recorded.last.sql, 'SELECT last_insert_rowid()');
      expect(executor.recorded.last.args, isEmpty);
    });

    test('reads the value by position, not by column name', () async {
      final executor = driver()
        ..rows = [
          {'whatever': 9},
        ];
      expect(
        await forge(executor)
            .insertInto(users)
            .values({'name': 'Ada'})
            .getLastInsertId(),
        9,
      );
    });

    test('tolerates a driver that returns the rowid as a float', () async {
      final executor = driver()
        ..rows = [
          {'last_insert_rowid()': 7.0},
        ];
      expect(
        await forge(executor)
            .insertInto(users)
            .values({'name': 'Ada'})
            .getLastInsertId(),
        7,
      );
    });

    test('rejects a non-numeric value', () {
      final executor = driver()
        ..rows = [
          {'last_insert_rowid()': 'seven'},
        ];
      expect(
        () =>
            forge(executor)
                .insertInto(users)
                .values({'name': 'Ada'})
                .getLastInsertId(),
        throwsStateError,
      );
    });
  });
}
