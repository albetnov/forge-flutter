import 'package:sqlite_query_forge/sqlite_query_forge.dart';
import 'package:test/test.dart';

String sqlOf(SelectStatement statement) => statement.compile().sql;

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
  Column<bool> get isActive => const Column('is_active');
}

const users = UsersTable();
const transactions = TransactionsTable();

final userRow = {'id': 1, 'name': 'Ada', 'is_active': 1};

final class _FakeExecutor implements ForgeExecutor {
  _FakeExecutor({this.responses = const []});

  List<Map<String, Object?>> responses;

  final List<CompiledQuery> recorded = [];

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    recorded.add(CompiledQuery(sql, args ?? const []));
    return responses;
  }

  @override
  Future<int> execute(String sql, [List<Object?>? args]) async {
    recorded.add(CompiledQuery(sql, args ?? const []));
    return 1;
  }

  @override
  Future<int> insert(String sql, [List<Object?>? args]) async {
    recorded.add(CompiledQuery(sql, args ?? const []));
    return 7;
  }

  @override
  Future<T> transaction<T>(Future<T> Function(ForgeExecutor txn) action) =>
      action(this);
}

void main() {
  /// A fresh fake, optionally preloaded with rows. Callers then mutate
  /// `responses` to control what the terminal sees.
  _FakeExecutor driver([List<Map<String, Object?>>? responses]) =>
      _FakeExecutor(responses: responses ?? const []);

  Forge forge(_FakeExecutor executor) => Forge(executor);

  group('qualified columns', () {
    test('renders table and column as two quoted identifiers', () {
      expect(
        sqlOf(SelectStatement(columns: [users.qualify(users.id)])),
        'SELECT "users"."id"',
      );
    });

    test('uses the alias when the table is aliased', () {
      final column = transactions.qualify(transactions.userId, 't');
      expect(sqlOf(SelectStatement(columns: [column])), 'SELECT "t"."user_id"');
    });

    test('TableSource.reference reports the name a join actually binds', () {
      expect(users.source.reference, 'users');
      expect(users.sourceAs('u').reference, 'u');
    });

    test('keeps its phantom type, so eq still rejects the wrong one', () {
      expect(
        sqlOf(SelectStatement(where: users.qualify(users.id).eq(42))),
        'SELECT * WHERE "users"."id" = ?',
      );
    });

    test('composes as an expression in GROUP BY', () {
      expect(
        sqlOf(
          SelectStatement(
            columns: [transactions.qualify(transactions.userId)],
            groupBy: Grouping([transactions.qualify(transactions.userId)]),
          ),
        ),
        'SELECT "transactions"."user_id" GROUP BY "transactions"."user_id"',
      );
    });

    test('counts without a table too', () {
      expect(
        sqlOf(
          SelectStatement(
            groupBy: Grouping([
              users.qualify(users.id),
            ], users.qualify(users.id).count.gt(0)),
          ),
        ),
        'SELECT * GROUP BY "users"."id" HAVING COUNT("users"."id") > ?',
      );
    });
  });

  group('sameAs', () {
    test('renders both sides and binds nothing', () {
      final q = SelectStatement(
        where: users
            .qualify(users.id)
            .sameAs(transactions.qualify(transactions.userId)),
      ).compile();
      expect(q.sql, 'SELECT * WHERE "users"."id" = "transactions"."user_id"');
      expect(q.args, isEmpty);
    });

    test('is the join key form', () {
      final on = users
          .qualify(users.id)
          .sameAs(transactions.qualify(transactions.userId, 't'));
      final q = SelectStatement(
        from: users.source,
        joins: [JoinClause.inner(transactions.sourceAs('t'), on)],
      ).compile();
      expect(
        q.sql,
        'SELECT * FROM "users" INNER JOIN "transactions" AS "t" '
        'ON "users"."id" = "t"."user_id"',
      );
      expect(q.args, isEmpty);
    });

    test('comparing two expressions binds nothing', () {
      // The HAVING case: an aggregate against another expression.
      expect(
        sqlOf(SelectStatement(where: users.id.count.gt(const RawSql('1')))),
        'SELECT * WHERE COUNT("id") > 1',
      );
      expect(
        sqlOf(SelectStatement(where: users.id.count.sameAs(users.name.count))),
        'SELECT * WHERE COUNT("id") = COUNT("name")',
      );
    });

    test('an expression operand never becomes a bound value', () {
      final q = SelectStatement(where: users.id.count.gt(const RawSql('1')))
          .compile();
      expect(q.args, isEmpty);
    });

    test('a bare Column is a node, so projections need no bridge', () {
      // The extension type used to unbox to String, which forced `.expr`
      // wherever an Expression was expected. There is nothing to bridge now.
      expect(
        sqlOf(SelectStatement(columns: [users.id, users.name])),
        'SELECT "id", "name"',
      );
      expect(
        sqlOf(SelectStatement(groupBy: Grouping([users.isActive]))),
        'SELECT * GROUP BY "is_active"',
      );
      expect(
        sqlOf(SelectStatement(orderBy: [OrderBy(users.name)])),
        'SELECT * ORDER BY "name" ASC',
      );
    });

    test('Column.toString keeps its name for debugging', () {
      expect(users.id.toString(), 'id');
      expect('${users.id}', 'id');
    });
  });

  group('select builder', () {
    test('chains into one statement', () {
      final q = forge(driver())
          .selectFrom(users)
          .select([users.id, users.name])
          .where(users.isActive.eq(true))
          .orderBy([OrderBy(users.name, SortOrder.desc)])
          .limit(10)
          .offset(20)
          .compile();
      expect(
        q.sql,
        'SELECT "id", "name" FROM "users" WHERE "is_active" = ? '
        'ORDER BY "name" DESC LIMIT ? OFFSET ?',
      );
      expect(q.args, [1, 10, 20]);
    });

    test('is immutable: each call leaves the previous builder untouched', () {
      final base = forge(driver()).selectFrom(users);
      final filtered = base.where(users.id.eq(1));
      final other = base.where(users.name.eq('x'));
      expect(base.compile().sql, 'SELECT * FROM "users"');
      expect(filtered.compile().sql, 'SELECT * FROM "users" WHERE "id" = ?');
      expect(other.compile().sql, 'SELECT * FROM "users" WHERE "name" = ?');
    });

    test(
      'is immutable: a caller cannot mutate a builder through its own list',
      () {
        // The list handed to select() is copied.
        final columns = <Expression>[users.id];
        final builder = forge(driver()).selectFrom(users).select(columns);
        columns.add(users.name);
        expect(builder.compile().sql, 'SELECT "id" FROM "users"');
      },
    );

    test(
      'is immutable: extending a chained query leaves the original alone',
      () {
        final base = forge(driver()).selectFrom(users);
        final sorted = base.orderBy([OrderBy(users.id)]);
        expect(base.compile().sql, 'SELECT * FROM "users"');
        expect(sorted.compile().sql, 'SELECT * FROM "users" ORDER BY "id" ASC');
        expect(base.orderBy([]).compile().sql, 'SELECT * FROM "users"');
      },
    );

    test('where replaces, andWhere and orWhere accumulate', () {
      final base = forge(driver()).selectFrom(users).where(users.id.gt(1));
      expect(
        base.andWhere(users.isActive.eq(true)).compile().sql,
        'SELECT * FROM "users" WHERE "id" > ? AND "is_active" = ?',
      );
      expect(
        base.orWhere(users.isActive.eq(true)).compile().sql,
        'SELECT * FROM "users" WHERE "id" > ? OR "is_active" = ?',
      );
    });

    test('andWhere over an OR is parenthesised', () {
      // Without the parens this reads as `a OR (b AND c)`.
      final q = forge(driver())
          .selectFrom(users)
          .where(users.id.eq(1))
          .orWhere(users.id.eq(2))
          .andWhere(users.id.eq(3))
          .compile();
      expect(
        q.sql,
        'SELECT * FROM "users" WHERE ("id" = ? OR "id" = ?) AND "id" = ?',
      );
      expect(q.args, [1, 2, 3]);
    });

    test('an already parenthesised filter is left alone', () {
      final q = forge(driver())
          .selectFrom(users)
          .where(Conjunction(users.id.eq(1), users.id.eq(2)).parenthesized)
          .andWhere(users.id.eq(3))
          .compile();
      expect(
        q.sql,
        'SELECT * FROM "users" WHERE ("id" = ? AND "id" = ?) AND "id" = ?',
      );
    });

    test('andWhere parenthesises a disjunction on the right too', () {
      // Guarding only the left side would read as `(a AND b) OR c`.
      final subFilter = Disjunction(users.name.eq('a'), users.name.eq('b'));
      final q = forge(driver())
          .selectFrom(users)
          .where(users.isActive.eq(true))
          .andWhere(subFilter)
          .compile();
      expect(
        q.sql,
        'SELECT * FROM "users" WHERE "is_active" = ? '
        'AND ("name" = ? OR "name" = ?)',
      );
      expect(q.args, [1, 'a', 'b']);
    });

    test('orWhere nests without needing parens, since OR is associative', () {
      final q = forge(driver())
          .selectFrom(users)
          .where(users.id.eq(1))
          .orWhere(users.id.eq(2))
          .orWhere(users.id.eq(3))
          .compile();
      expect(
        q.sql,
        'SELECT * FROM "users" WHERE "id" = ? OR "id" = ? OR "id" = ?',
      );
    });

    test('orWhere over a conjunction needs no parens either', () {
      final q = forge(driver())
          .selectFrom(users)
          .where(users.isActive.eq(true))
          .orWhere(users.id.eq(2))
          .compile();
      expect(q.sql, 'SELECT * FROM "users" WHERE "is_active" = ? OR "id" = ?');
    });

    test('groupBy rejects an empty list rather than emitting bad SQL', () {
      expect(
        () => forge(driver()).selectFrom(users).groupBy([]),
        throwsStateError,
      );
    });

    test('andWhere with no prior where behaves as where', () {
      final q = forge(driver())
          .selectFrom(users)
          .andWhere(users.id.eq(1))
          .compile();
      expect(q.sql, 'SELECT * FROM "users" WHERE "id" = ?');
    });

    test('orWhere with no prior where behaves as where', () {
      final q = forge(driver())
          .selectFrom(users)
          .orWhere(users.id.eq(1))
          .compile();
      expect(q.sql, 'SELECT * FROM "users" WHERE "id" = ?');
    });

    test('orderBy replaces, thenBy appends', () {
      final base = forge(driver()).selectFrom(users);
      expect(
        base.orderBy([OrderBy(users.name)]).compile().sql,
        'SELECT * FROM "users" ORDER BY "name" ASC',
      );
      expect(
        base
            .orderBy([OrderBy(users.name)])
            .thenBy(users.id, SortOrder.desc)
            .compile()
            .sql,
        'SELECT * FROM "users" ORDER BY "name" ASC, "id" DESC',
      );
      expect(
        base
            .orderBy([OrderBy(users.name)])
            .thenBy(users.id, SortOrder.desc)
            .orderBy([OrderBy(users.id)])
            .compile()
            .sql,
        'SELECT * FROM "users" ORDER BY "id" ASC',
      );
    });

    test('distinct defaults on and can be turned back off', () {
      expect(
        forge(driver()).selectFrom(users).distinct().compile().sql,
        'SELECT DISTINCT * FROM "users"',
      );
      expect(
        forge(driver()).selectFrom(users).distinct(value: false).compile().sql,
        'SELECT * FROM "users"',
      );
    });

    test('groupBy and having', () {
      final q = forge(driver())
          .selectFrom(users)
          .groupBy([users.isActive])
          .having(users.id.count.gt(1))
          .compile();
      expect(
        q.sql,
        'SELECT * FROM "users" GROUP BY "is_active" HAVING COUNT("id") > ?',
      );
    });

    test('having without groupBy is rejected rather than emitting bad SQL', () {
      expect(
        () => forge(driver()).selectFrom(users).having(users.id.count.gt(1)),
        throwsStateError,
      );
    });

    test('joins', () {
      final aliased = users
          .qualify(users.id)
          .sameAs(transactions.qualify(transactions.userId, 't'));
      final unaliased = users
          .qualify(users.id)
          .sameAs(transactions.qualify(transactions.userId));
      expect(
        forge(driver())
            .selectFrom(users)
            .join(transactions.sourceAs('t'), on: aliased)
            .compile()
            .sql,
        'SELECT * FROM "users" INNER JOIN "transactions" AS "t" '
        'ON "users"."id" = "t"."user_id"',
      );
      expect(
        forge(driver())
            .selectFrom(users)
            .leftJoin(transactions.sourceAs(), on: unaliased)
            .compile()
            .sql,
        'SELECT * FROM "users" LEFT JOIN "transactions" '
        'ON "users"."id" = "transactions"."user_id"',
      );
      expect(
        forge(driver())
            .selectFrom(users)
            .crossJoin(transactions.source)
            .compile()
            .sql,
        'SELECT * FROM "users" CROSS JOIN "transactions"',
      );
    });

    test(
      'the alias in a join must match the alias in the qualified column',
      () {
        // Qualifying against the table name while the join binds 't' emits a
        // reference to a table the query never binds.
        final joinSource = transactions.sourceAs('t');
        expect(joinSource.reference, 't');

        final mismatched = forge(driver())
            .selectFrom(users)
            .join(
              joinSource,
              on: users
                  .qualify(users.id)
                  .sameAs(transactions.qualify(transactions.userId)),
            )
            .compile();
        expect(
          mismatched.sql,
          'SELECT * FROM "users" INNER JOIN "transactions" AS "t" '
          'ON "users"."id" = "transactions"."user_id"',
        );

        final matched = forge(driver())
            .selectFrom(users)
            .join(
              joinSource,
              on: users
                  .qualify(users.id)
                  .sameAs(
                    transactions.qualify(
                      transactions.userId,
                      joinSource.reference,
                    ),
                  ),
            )
            .compile();
        expect(
          matched.sql,
          'SELECT * FROM "users" INNER JOIN "transactions" AS "t" '
          'ON "users"."id" = "t"."user_id"',
        );
      },
    );

    test('Column.sameAs renders an unqualified name, so qualify in a join', () {
      // Column carries no table, so it cannot qualify itself.
      final unqualified = forge(driver())
          .selectFrom(users)
          .join(
            transactions.sourceAs('t'),
            on: users.id.sameAs(transactions.qualify(transactions.userId, 't')),
          )
          .compile();
      expect(unqualified.sql, contains('ON "id" = "t"."user_id"'));

      final qualified = forge(driver())
          .selectFrom(users)
          .join(
            transactions.sourceAs('t'),
            on: users
                .qualify(users.id)
                .sameAs(transactions.qualify(transactions.userId, 't')),
          )
          .compile();
      expect(qualified.sql, contains('ON "users"."id" = "t"."user_id"'));
    });

    test('a join survives subsequent filters and ordering', () {
      final on = users
          .qualify(users.id)
          .sameAs(transactions.qualify(transactions.userId, 't'));
      expect(
        forge(driver())
            .selectFrom(users)
            .leftJoin(transactions.sourceAs('t'), on: on)
            .where(transactions.qualify(transactions.amount, 't').gt(100))
            .compile()
            .sql,
        'SELECT * FROM "users" LEFT JOIN "transactions" AS "t" '
        'ON "users"."id" = "t"."user_id" WHERE "t"."amount" > ?',
      );
    });

    test('a subquery can be used as a source', () {
      final inner = forge(driver())
          .selectFrom(users)
          .groupBy([users.isActive])
          .statement;
      final counting = forge(
        driver(),
      ).selectFromSource(SubquerySource(inner), (row) => row['count'] as int);
      expect(
        counting.compile().sql,
        contains('FROM (SELECT * FROM "users" GROUP BY "is_active")'),
      );
    });

    test('map re-types the builder around a projection', () {
      final builder = forge(driver())
          .selectFrom(users)
          .select([users.id, users.name])
          .map((row) => (row['id'] as int, row['name'] as String));
      expect(builder.compile().sql, 'SELECT "id", "name" FROM "users"');
    });

    test('map lets a model-less type flow to the terminal', () async {
      final row = await forge(driver()..responses = [userRow])
          .selectFrom(users)
          .select([users.id, users.name])
          .map((r) => (r['id'] as int, r['name'] as String))
          .getFirst();
      expect(row, (1, 'Ada'));
    });
  });

  group('count', () {
    test('emits COUNT(*) over the same filter', () async {
      final executor = driver();
      await forge(executor)
          .selectFrom(users)
          .where(users.isActive.eq(true))
          .count();
      expect(
        executor.recorded.single.sql,
        'SELECT COUNT(*) AS "count" FROM "users" WHERE "is_active" = ?',
      );
    });

    test('wraps a grouped query so groups are counted, not rows', () async {
      final executor = driver();
      await forge(executor)
          .selectFrom(users)
          .groupBy([users.isActive])
          .orderBy([OrderBy(users.isActive)])
          .limit(5)
          .count();
      expect(
        executor.recorded.single.sql,
        'SELECT COUNT(*) AS "count" '
        'FROM (SELECT * FROM "users" GROUP BY "is_active")',
      );
    });

    test('wraps a distinct query so the deduplication is respected', () async {
      final executor = driver();
      await forge(executor).selectFrom(users).distinct().count();
      expect(
        executor.recorded.single.sql,
        'SELECT COUNT(*) AS "count" FROM (SELECT DISTINCT * FROM "users")',
      );
    });

    test('drops the ordering and paging of the inner query', () async {
      final executor = driver();
      await forge(executor)
          .selectFrom(users)
          .orderBy([OrderBy(users.id)])
          .limit(9)
          .count();
      final sql = executor.recorded.single.sql;
      expect(sql, isNot(contains('ORDER BY')));
      expect(sql, isNot(contains('LIMIT')));
    });

    test('reads the value rather than the column name', () async {
      // Keyed differently from the alias, so a name-based read would fail.
      expect(
        await forge(
          driver()
            ..responses = [
              {'count': 3},
            ],
        ).selectFrom(users).count(),
        3,
      );
    });

    test('tolerates a driver that returns the count as a float', () async {
      expect(
        await forge(
          driver()
            ..responses = [
              {'count': 3.0},
            ],
        ).selectFrom(users).count(),
        3,
      );
    });

    test('rejects a non-numeric count rather than casting blind', () async {
      expect(
        forge(
          driver()
            ..responses = [
              {'count': 'three'},
            ],
        ).selectFrom(users).count(),
        throwsStateError,
      );
    });

    test('requires a FROM clause', () {
      expect(
        () => SelectBuilder<User>(SelectStatement()).count(),
        throwsStateError,
      );
    });

    test('preserves the join when counting', () async {
      final executor = driver();
      await forge(executor)
          .selectFrom(users)
          .join(
            transactions.sourceAs('t'),
            on: users
                .qualify(users.id)
                .sameAs(transactions.qualify(transactions.userId, 't')),
          )
          .where(transactions.qualify(transactions.amount, 't').gt(100))
          .count();
      expect(
        executor.recorded.single.sql,
        'SELECT COUNT(*) AS "count" FROM "users" '
        'INNER JOIN "transactions" AS "t" ON "users"."id" = "t"."user_id" '
        'WHERE "t"."amount" > ?',
      );
    });

    test('preserves HAVING when counting a grouped query', () async {
      final executor = driver();
      await forge(executor)
          .selectFrom(users)
          .groupBy([users.isActive])
          .having(users.id.count.gt(1))
          .count();
      expect(
        executor.recorded.single.sql,
        'SELECT COUNT(*) AS "count" FROM (SELECT * FROM "users" '
        'GROUP BY "is_active" HAVING COUNT("id") > ?)',
      );
    });

    test('an empty result counts as 0', () async {
      expect(await forge(driver()).selectFrom(users).count(), 0);
    });
  });

  group('execution', () {
    test('getMany maps rows through the table mapper', () async {
      final result = await forge(driver()..responses = [userRow])
          .selectFrom(users)
          .getMany();
      final user = result.single;
      expect(user.id, 1);
      expect(user.isActive, isTrue);
    });

    test('getSingle returns the only row', () async {
      final user = await forge(driver()..responses = [userRow])
          .selectFrom(users)
          .getSingle();
      expect(user.name, 'Ada');
    });

    test('getSingle throws when the query returns no row', () async {
      expect(
        forge(driver()).selectFrom(users).getSingle(),
        throwsA(
          isA<ForgeCardinalityError>().having((e) => e.actual, 'actual', 0),
        ),
      );
    });

    test('getSingle throws when the query returns more than one row', () async {
      expect(
        forge(driver()..responses = [userRow, userRow])
            .selectFrom(users)
            .getSingle(),
        throwsA(
          isA<ForgeCardinalityError>().having((e) => e.actual, 'actual', 2),
        ),
      );
    });

    test('getFirst returns null on no rows', () async {
      expect(await forge(driver()).selectFrom(users).getFirst(), isNull);
    });

    test('getFirst applies LIMIT 1 when the caller set none', () async {
      final executor = driver()..responses = [userRow];
      expect((await forge(executor).selectFrom(users).getFirst())!.name, 'Ada');
      expect(executor.recorded.single.sql, 'SELECT * FROM "users" LIMIT ?');
    });

    test('getFirst honours a limit the caller already set', () async {
      final executor = driver()..responses = [userRow];
      await forge(executor).selectFrom(users).limit(5).getFirst();
      expect(executor.recorded.single.sql, 'SELECT * FROM "users" LIMIT ?');
      expect(executor.recorded.single.args, [5]);
    });

    test('bound args reach the executor in textual order', () async {
      final executor = driver()..responses = [userRow];
      await forge(executor)
          .selectFrom(users)
          .where(users.id.eq(7))
          .limit(3)
          .getMany();
      expect(
        executor.recorded.single.sql,
        'SELECT * FROM "users" WHERE "id" = ? LIMIT ?',
      );
      expect(executor.recorded.single.args, [7, 3]);
    });

    test('a builder built without an executor fails loudly on a terminal', () {
      expect(
        () => SelectBuilder<User>(SelectStatement()).getMany(),
        throwsStateError,
      );
    });

    test(
      'a builder built without a mapper fails loudly on a terminal',
      () async {
        expect(
          () =>
              SelectBuilder<User>(SelectStatement(), null, driver()).getMany(),
          throwsStateError,
        );
      },
    );

    test('transaction delegates to the executor', () async {
      expect(await forge(driver()).transaction((txn) async => 42), 42);
    });

    test('query, execute and insert compile before dispatching', () async {
      final executor = driver();
      final target = forge(executor);
      await target.query(DeleteStatement(users.source, users.id.eq(1)));
      await target.execute(UpdateStatement(users.source, {'name': 'x'}));
      await target.insert(InsertStatement.one(users.source, ['name'], ['x']));
      expect(executor.recorded.map((q) => q.sql), [
        'DELETE FROM "users" WHERE "id" = ?',
        'UPDATE "users" SET "name" = ?',
        'INSERT INTO "users" ("name") VALUES (?)',
      ]);
    });
  });

  group('json_object', () {
    test('projects a joined row as a JSON object', () async {
      final executor = driver()
        ..responses = [
          {'user': '{"id":1,"name":"Ada"}'},
        ];
      final json = await forge(executor)
          .selectFrom(users)
          .select([
            JsonObject({
              'id': users.qualify(users.id, 'u'),
              'name': users.qualify(users.name, 'u'),
            }).alias('user'),
          ])
          .map((row) => row['user'] as String)
          .getSingle();
      expect(json, '{"id":1,"name":"Ada"}');
      expect(
        executor.recorded.single.sql,
        'SELECT json_object(\'id\', "u"."id", \'name\', "u"."name") AS "user" '
        'FROM "users" LIMIT ?',
      );
      expect(executor.recorded.single.args, [2]);
    });

    test('aliasing a value inside the object nests the AS clause', () {
      final q = forge(driver()).selectFrom(users).select([
        JsonObject({
          'id': users.qualify(users.id, 'u'),
          'profile': users.qualify(users.name, 'u').alias('name'),
        }).alias('user'),
      ]).compile();
      expect(
        q.sql,
        'SELECT json_object(\'id\', "u"."id", \'profile\', "u"."name" AS "name") '
        'AS "user" FROM "users"',
      );
    });
  });
}
