import 'package:sqlite_query_forge/sqlite_query_forge.dart';
import 'package:test/test.dart';

String sqlOf(Statement statement) => statement.compile().sql;

List<Object?> argsOf(Statement statement) => statement.compile().args;

void main() {
  const id = Column<int>('id');
  const name = Column<String>('name');
  const isActive = Column<bool>('is_active');
  const amount = Column<int>('amount');

  final users = const TableSource('users');
  final wallets = const TableSource('wallets');

  group('identifier quoting', () {
    test('quotes plain names', () {
      expect(quoteIdentifier('id'), '"id"');
    });

    test('escapes embedded double quotes by doubling', () {
      expect(quoteIdentifier('a"b'), '"a""b"');
    });

    test('neutralises an injection attempt in an identifier', () {
      expect(
        quoteIdentifier('id" ; DROP TABLE users; --'),
        '"id"" ; DROP TABLE users; --"',
      );
    });
  });

  group('Column', () {
    test('carries its name through', () {
      expect(id.name, 'id');
      expect(isActive.name, 'is_active');
    });

    test('renders as a quoted identifier', () {
      expect(sqlOf(SelectStatement(columns: [id])), 'SELECT "id"');
    });

    test('const declarations share one instance', () {
      const a = Column<int>('id');
      const b = Column<int>('id');
      expect(identical(a, b), isTrue);
    });

    test('phantom type keeps eq checked', () {
      expect(
        sqlOf(SelectStatement(where: id.eq(42))),
        'SELECT * WHERE "id" = ?',
      );
      expect(
        sqlOf(SelectStatement(where: name.eq('a'))),
        'SELECT * WHERE "name" = ?',
      );
    });
  });

  group('comparison expressions bind their value', () {
    test('eq', () {
      expect(
        sqlOf(SelectStatement(columns: [id], where: id.eq(42))),
        'SELECT "id" WHERE "id" = ?',
      );
      expect(argsOf(SelectStatement(where: id.eq(42))), [42]);
    });

    test('neq renders SQL-standard <>', () {
      expect(
        sqlOf(SelectStatement(where: id.neq(1))),
        'SELECT * WHERE "id" <> ?',
      );
    });

    test('range operators', () {
      expect(
        sqlOf(SelectStatement(where: id.gt(1))),
        'SELECT * WHERE "id" > ?',
      );
      expect(
        sqlOf(SelectStatement(where: id.gte(1))),
        'SELECT * WHERE "id" >= ?',
      );
      expect(
        sqlOf(SelectStatement(where: id.lt(1))),
        'SELECT * WHERE "id" < ?',
      );
      expect(
        sqlOf(SelectStatement(where: id.lte(1))),
        'SELECT * WHERE "id" <= ?',
      );
    });

    test('a string value is never inlined into the SQL', () {
      final q = SelectStatement(
        where: name.eq('Robert\'); DROP TABLE users;--'),
      ).compile();
      expect(q.sql, 'SELECT * WHERE "name" = ?');
      expect(q.args, ["Robert'); DROP TABLE users;--"]);
    });

    test('like binds the pattern', () {
      final q = SelectStatement(where: name.like('%ada%')).compile();
      expect(q.sql, 'SELECT * WHERE "name" LIKE ?');
      expect(q.args, ['%ada%']);
    });
  });

  group('boolean columns', () {
    test('a bool value is bound as 1/0 by the compiler, not as SQL text', () {
      // SQLite has no bool type.
      final q = SelectStatement(where: isActive.eq(true)).compile();
      expect(q.sql, 'SELECT * WHERE "is_active" = ?');
      expect(q.args, [1]);
    });

    test('false binds as 0', () {
      expect(argsOf(SelectStatement(where: isActive.eq(false))), [0]);
    });

    test('the conversion covers insert values too', () {
      final q = InsertStatement.one(users, ['is_active'], [true]).compile();
      expect(q.args, [1]);
    });
  });

  group('json_object', () {
    test('alternates string literal and expression, binding nothing', () {
      final q = SelectStatement(
        columns: [
          const JsonObject({
            'id': RawSql('"u"."id"'),
            'name': RawSql('"u"."name"'),
          }),
        ],
      ).compile();
      expect(
        q.sql,
        'SELECT json_object(\'id\', "u"."id", \'name\', "u"."name")',
      );
      expect(q.args, isEmpty);
    });

    test('takes columns as values and qualifies them for a join', () {
      final object = const JsonObject({
        'id': QualifiedColumn('u', 'id'),
        'name': QualifiedColumn('u', 'name'),
      });
      expect(
        sqlOf(SelectStatement(from: users, columns: [object])),
        'SELECT json_object(\'id\', "u"."id", \'name\', "u"."name") FROM "users"',
      );
    });

    test('aliases through the expression, like any other projection', () {
      final q = SelectStatement(
        columns: [
          const JsonObject({'id': RawSql('"id"')}).alias('user'),
        ],
      ).compile();
      expect(q.sql, 'SELECT json_object(\'id\', "id") AS "user"');
    });

    test('escapes a quote inside a label', () {
      final q = SelectStatement(
        columns: [
          const JsonObject({"it's": RawSql('"id"')}),
        ],
      ).compile();
      expect(q.sql, "SELECT json_object('it''s', \"id\")");
    });

    test('an empty map compiles to json_object(), which is {}', () {
      expect(
        sqlOf(SelectStatement(columns: [const JsonObject({})])),
        'SELECT json_object()',
      );
    });

    test('nests, since a JsonObject is an Expression like any other', () {
      final outer = JsonObject({
        'user': const JsonObject({'id': RawSql('"id"')}),
      });
      expect(
        sqlOf(SelectStatement(columns: [outer])),
        'SELECT json_object(\'user\', json_object(\'id\', "id"))',
      );
    });

    test('leaves the WHERE arguments alone', () {
      final q = SelectStatement(
        columns: [
          const JsonObject({'active': RawSql('"is_active"')}),
        ],
        where: id.eq(1),
      ).compile();
      expect(
        q.sql,
        'SELECT json_object(\'active\', "is_active") WHERE "id" = ?',
      );
      expect(q.args, [1]);
    });

    test('composes in a grouping, like any other expression', () {
      expect(
        sqlOf(
          SelectStatement(
            columns: [
              const JsonObject({'id': RawSql('"id"')}),
            ],
            groupBy: Grouping([
              const JsonObject({'id': RawSql('"id"')}),
            ]),
          ),
        ),
        'SELECT json_object(\'id\', "id") GROUP BY json_object(\'id\', "id")',
      );
    });
  });

  group('Column constructors', () {
    test('the plain constructor declares no type, so nothing migrates', () {
      expect(const Column('id').type, isNull);
      expect(const Column('id').primaryKey, isFalse);
    });

    test('id names itself and carries the primary key', () {
      final id = const Column.id();
      expect(id.name, 'id');
      expect(id.type, ColumnType.integer);
      expect(id.primaryKey, isTrue);
      expect(id.autoIncrement, isTrue);
      expect(id.nullable, isFalse);
    });

    test('integer and text carry their own flags', () {
      const email = Column.text('email', nullable: false, unique: true);
      expect(email.type, ColumnType.text);
      expect(email.nullable, isFalse);
      expect(email.unique, isTrue);

      const rank = Column.integer('rank', defaultValue: 7);
      expect(rank.type, ColumnType.integer);
      expect(rank.defaultValue, 7);
      expect(rank.nullable, isTrue);
    });

    test('a reference is kept verbatim for the bridge to convert', () {
      const ts = Column.dateTime(
        'created_at',
        nullable: false,
        defaultValue: RawSql('CURRENT_TIMESTAMP'),
      );
      expect(ts.type, ColumnType.text);
      expect(ts.defaultValue, isA<RawSql>());
    });

    test('a const column canonicalizes, so the getter stays free', () {
      expect(identical(const Column.id(), const Column.id()), isTrue);
      expect(identical(const Column('x'), const Column('x')), isTrue);
    });

    test('the flags change nothing about how it renders', () {
      expect(
        sqlOf(SelectStatement(columns: [const Column.id()])),
        'SELECT "id"',
      );
      expect(
        sqlOf(SelectStatement(where: const Column.text('name').eq('Ada'))),
        'SELECT * WHERE "name" = ?',
      );
    });
  });

  group('null checks use IS, not =', () {
    test('isNull', () {
      expect(
        sqlOf(SelectStatement(where: name.isNull)),
        'SELECT * WHERE "name" IS NULL',
      );
      expect(argsOf(SelectStatement(where: name.isNull)), isEmpty);
    });

    test('isNotNull', () {
      expect(
        sqlOf(SelectStatement(where: name.isNotNull)),
        'SELECT * WHERE "name" IS NOT NULL',
      );
    });
  });

  group('between', () {
    test('binds both bounds in order', () {
      final q = SelectStatement(where: id.between(10, 20)).compile();
      expect(q.sql, 'SELECT * WHERE "id" BETWEEN ? AND ?');
      expect(q.args, [10, 20]);
    });

    test('notBetween', () {
      expect(
        sqlOf(SelectStatement(where: id.notBetween(1, 2))),
        'SELECT * WHERE "id" NOT BETWEEN ? AND ?',
      );
    });
  });

  group('IN lists', () {
    test('binds every element', () {
      final q = SelectStatement(where: id.inList([1, 2, 3])).compile();
      expect(q.sql, 'SELECT * WHERE "id" IN (?, ?, ?)');
      expect(q.args, [1, 2, 3]);
    });

    test('negated', () {
      expect(
        sqlOf(SelectStatement(where: id.notIn([1]))),
        'SELECT * WHERE "id" NOT IN (?)',
      );
    });

    test('binds null as a value rather than emitting NULL', () {
      final q = SelectStatement(where: id.inList([1, null])).compile();
      expect(q.sql, 'SELECT * WHERE "id" IN (?, ?)');
      expect(q.args, [1, null]);
    });

    test('an empty list compiles to constant false, not a syntax error', () {
      // SQLite rejects the bare `IN ()`, and rendering the column first
      // would produce `"id" 0`, a syntax error of its own.
      final q = SelectStatement(where: id.inList([])).compile();
      expect(q.sql, 'SELECT * WHERE 0');
      expect(q.args, isEmpty);
    });

    test('an empty negated list compiles to constant true', () {
      final q = SelectStatement(where: id.notIn([])).compile();
      expect(q.sql, 'SELECT * WHERE 1');
    });

    test('an empty list stays composable under AND', () {
      final q = SelectStatement(where: Conjunction(name.eq('a'), id.inList([])))
          .compile();
      expect(q.sql, 'SELECT * WHERE "name" = ? AND 0');
      expect(q.args, ['a']);
    });

    test('an empty list stays composable under OR', () {
      final q = SelectStatement(where: Disjunction(name.eq('a'), id.notIn([])))
          .compile();
      expect(q.sql, 'SELECT * WHERE "name" = ? OR 1');
      expect(q.args, ['a']);
    });
  });

  group('aggregates', () {
    test('count/sum/avg/min/max', () {
      expect(sqlOf(SelectStatement(columns: [id.count])), 'SELECT COUNT("id")');
      expect(
        sqlOf(SelectStatement(columns: [amount.sum])),
        'SELECT SUM("amount")',
      );
      expect(
        sqlOf(SelectStatement(columns: [amount.avg])),
        'SELECT AVG("amount")',
      );
      expect(
        sqlOf(SelectStatement(columns: [amount.min])),
        'SELECT MIN("amount")',
      );
      expect(
        sqlOf(SelectStatement(columns: [amount.max])),
        'SELECT MAX("amount")',
      );
    });

    test('count distinct', () {
      expect(
        sqlOf(SelectStatement(columns: [id.countDistinct])),
        'SELECT COUNT(DISTINCT "id")',
      );
    });

    test('COUNT(*) via a raw fragment', () {
      expect(
        sqlOf(SelectStatement(columns: [const RawSql('COUNT(*)')])),
        'SELECT COUNT(*)',
      );
    });
  });

  group('logical composition', () {
    test('AND binds both sides in order', () {
      final q = SelectStatement(where: Conjunction(id.eq(1), name.eq('a')))
          .compile();
      expect(q.sql, 'SELECT * WHERE "id" = ? AND "name" = ?');
      expect(q.args, [1, 'a']);
    });

    test('OR', () {
      expect(
        sqlOf(SelectStatement(where: Disjunction(id.eq(1), id.eq(2)))),
        'SELECT * WHERE "id" = ? OR "id" = ?',
      );
    });

    test('NOT', () {
      expect(
        sqlOf(SelectStatement(where: Negation(id.eq(1)))),
        'SELECT * WHERE NOT ("id" = ?)',
      );
    });

    test('parenthesised nesting keeps args in textual order', () {
      final inner = Conjunction(id.eq(1), name.eq('x'));
      final q = SelectStatement(where: Disjunction(inner, id.eq(9))).compile();
      expect(q.sql, 'SELECT * WHERE "id" = ? AND "name" = ? OR "id" = ?');
      expect(q.args, [1, 'x', 9]);
    });
  });

  group('aliases and collation', () {
    test('alias', () {
      expect(
        sqlOf(SelectStatement(columns: [id.alias('user_id')])),
        'SELECT "id" AS "user_id"',
      );
    });

    test('parenthesized', () {
      expect(
        sqlOf(
          SelectStatement(where: Conjunction(id.eq(1), id.eq(2)).parenthesized),
        ),
        'SELECT * WHERE ("id" = ? AND "id" = ?)',
      );
    });

    test('collate nocase', () {
      expect(
        sqlOf(SelectStatement(where: Collated(name.eq('a'), 'NOCASE'))),
        'SELECT * WHERE "name" = ? COLLATE NOCASE',
      );
    });
  });

  group('select clause', () {
    test('empty column list emits *', () {
      expect(sqlOf(const SelectStatement()), 'SELECT *');
    });

    test('DISTINCT', () {
      expect(sqlOf(const SelectStatement(distinct: true)), 'SELECT DISTINCT *');
    });

    test('multiple columns', () {
      expect(
        sqlOf(SelectStatement(columns: [id, name])),
        'SELECT "id", "name"',
      );
    });

    test('function call', () {
      expect(
        sqlOf(
          SelectStatement(
            columns: [
              FunctionCall('LOWER', [name]),
            ],
          ),
        ),
        'SELECT LOWER("name")',
      );
    });
  });

  group('joins', () {
    test('inner join emits ON', () {
      final q = SelectStatement(
        from: users,
        joins: [
          JoinClause.inner(
            const TableSource('wallets'),
            const RawSql('"users"."wallet_id" = "wallets"."id"'),
          ),
        ],
      ).compile();
      expect(
        q.sql,
        'SELECT * FROM "users" INNER JOIN "wallets" ON "users"."wallet_id" = "wallets"."id"',
      );
      expect(q.args, isEmpty);
    });

    test('left join', () {
      expect(
        sqlOf(
          SelectStatement(joins: [JoinClause.left(wallets, const RawSql('1'))]),
        ),
        'SELECT * LEFT JOIN "wallets" ON 1',
      );
    });

    test('cross join omits ON', () {
      expect(
        sqlOf(SelectStatement(joins: [JoinClause.cross(wallets)])),
        'SELECT * CROSS JOIN "wallets"',
      );
    });

    test('aliased source', () {
      expect(
        sqlOf(SelectStatement(from: const TableSource('users', 'u'))),
        'SELECT * FROM "users" AS "u"',
      );
    });
  });

  group('group by and having', () {
    test('group by', () {
      expect(
        sqlOf(SelectStatement(groupBy: Grouping([id]))),
        'SELECT * GROUP BY "id"',
      );
    });

    test('group by with having', () {
      expect(
        sqlOf(SelectStatement(groupBy: Grouping([id], id.count.gt(1)))),
        'SELECT * GROUP BY "id" HAVING COUNT("id") > ?',
      );
    });

    test('multiple group expressions', () {
      expect(
        sqlOf(SelectStatement(groupBy: Grouping([id, name]))),
        'SELECT * GROUP BY "id", "name"',
      );
    });
  });

  group('order by, limit, offset', () {
    test('order by asc is explicit', () {
      expect(
        sqlOf(SelectStatement(orderBy: [OrderBy(name)])),
        'SELECT * ORDER BY "name" ASC',
      );
    });

    test('order by desc', () {
      expect(
        sqlOf(SelectStatement(orderBy: [OrderBy(name, SortOrder.desc)])),
        'SELECT * ORDER BY "name" DESC',
      );
    });

    test('multiple sort keys', () {
      expect(
        sqlOf(
          SelectStatement(
            orderBy: [
              OrderBy(name, SortOrder.asc),
              OrderBy(id, SortOrder.desc),
            ],
          ),
        ),
        'SELECT * ORDER BY "name" ASC, "id" DESC',
      );
    });

    test('limit', () {
      final q = const SelectStatement(limit: 10).compile();
      expect(q.sql, 'SELECT * LIMIT ?');
      expect(q.args, [10]);
    });

    test('limit and offset', () {
      final q = const SelectStatement(limit: 16, offset: 32).compile();
      expect(q.sql, 'SELECT * LIMIT ? OFFSET ?');
      expect(q.args, [16, 32]);
    });

    test('unset limit emits no clause at all', () {
      expect(sqlOf(const SelectStatement()), isNot(contains('LIMIT')));
    });
  });

  group('insert', () {
    test('single row binds every value', () {
      final q = InsertStatement.one(
        users,
        ['name', 'email'],
        ['ada', 'ada@x.io'],
      ).compile();
      expect(q.sql, 'INSERT INTO "users" ("name", "email") VALUES (?, ?)');
      expect(q.args, ['ada', 'ada@x.io']);
    });

    test('multi row', () {
      final q = InsertStatement(
        users,
        ['name'],
        [
          ['a'],
          ['b'],
        ],
      ).compile();
      expect(q.sql, 'INSERT INTO "users" ("name") VALUES (?), (?)');
      expect(q.args, ['a', 'b']);
    });

    test('on conflict do nothing', () {
      final q = InsertStatement.one(
        users,
        ['email'],
        ['a@x.io'],
        onConflict: ConflictClause.ignore(),
      ).compile();
      expect(
        q.sql,
        'INSERT INTO "users" ("email") VALUES (?) ON CONFLICT DO NOTHING',
      );
    });

    test('on conflict do update binds the new values', () {
      final q = InsertStatement.one(
        users,
        ['email', 'name'],
        ['a@x.io', 'ada'],
        onConflict: ConflictClause.update(['email'], {'name': 'ada lovelace'}),
      ).compile();
      expect(
        q.sql,
        'INSERT INTO "users" ("email", "name") VALUES (?, ?) '
        'ON CONFLICT ("email") DO UPDATE SET "name" = ?',
      );
      expect(q.args, ['a@x.io', 'ada', 'ada lovelace']);
    });

    test('on conflict do update with no target prefixes DO UPDATE', () {
      final q = InsertStatement.one(
        users,
        ['email'],
        ['a@x.io'],
        onConflict: ConflictClause.update(const [], {'name': 'ada'}),
      ).compile();
      expect(
        q.sql,
        'INSERT INTO "users" ("email") VALUES (?) '
        'ON CONFLICT DO UPDATE SET "name" = ?',
      );
    });
  });

  group('update', () {
    test('binds assignments and the filter', () {
      final q = UpdateStatement(users, {'name': 'ada'}, id.eq(1)).compile();
      expect(q.sql, 'UPDATE "users" SET "name" = ? WHERE "id" = ?');
      expect(q.args, ['ada', 1]);
    });

    test('omits WHERE when absent', () {
      final q = UpdateStatement(users, {'name': 'ada'}).compile();
      expect(q.sql, 'UPDATE "users" SET "name" = ?');
      expect(q.args, ['ada']);
    });
  });

  group('returning', () {
    test('a null list omits the clause', () {
      expect(
        sqlOf(InsertStatement.one(users, ['name'], ['ada'])),
        'INSERT INTO "users" ("name") VALUES (?)',
      );
      expect(
        sqlOf(UpdateStatement(users, {'name': 'ada'})),
        'UPDATE "users" SET "name" = ?',
      );
      expect(sqlOf(DeleteStatement(users)), 'DELETE FROM "users"');
    });

    test('a list binds each expression', () {
      final q = InsertStatement.one(
        users,
        ['name'],
        ['ada'],
        returning: [id, name],
      ).compile();
      expect(
        q.sql,
        'INSERT INTO "users" ("name") VALUES (?) RETURNING "id", "name"',
      );
    });

    test('an empty list means *', () {
      expect(
        sqlOf(
          InsertStatement.one(users, ['name'], ['ada'], returning: const []),
        ),
        'INSERT INTO "users" ("name") VALUES (?) RETURNING *',
      );
      expect(
        sqlOf(UpdateStatement(users, {'name': 'ada'}, null, const [])),
        'UPDATE "users" SET "name" = ? RETURNING *',
      );
      expect(
        sqlOf(DeleteStatement(users, null, const [])),
        'DELETE FROM "users" RETURNING *',
      );
    });
  });

  group('delete', () {
    test('with filter', () {
      final q = DeleteStatement(users, id.eq(1)).compile();
      expect(q.sql, 'DELETE FROM "users" WHERE "id" = ?');
      expect(q.args, [1]);
    });

    test('without filter deletes everything', () {
      expect(sqlOf(DeleteStatement(users)), 'DELETE FROM "users"');
    });
  });

  group('create table', () {
    test('emits definitions and IF NOT EXISTS', () {
      expect(
        sqlOf(
          CreateTableStatement(users, [
            '"id" INTEGER PRIMARY KEY',
            '"name" TEXT NOT NULL',
          ]),
        ),
        'CREATE TABLE IF NOT EXISTS "users" ("id" INTEGER PRIMARY KEY, "name" TEXT NOT NULL)',
      );
    });
  });

  group('statement kind', () {
    test('select is a query, writes are not', () {
      expect(const SelectStatement().isQuery, isTrue);
      expect(DeleteStatement(users).isQuery, isFalse);
      expect(UpdateStatement(users, const {}).isQuery, isFalse);
      expect(InsertStatement.one(users, ['a'], [1]).isQuery, isFalse);
    });
  });

  group('exhaustiveness', () {
    test('switching over Expression covers every node', () {
      String describe(Expression e) => switch (e) {
        Column(:final name) => 'column $name',
        Comparison() => 'comparison',
        RefComparison() => 'reference comparison',
        NullCheck() => 'null check',
        Between() => 'between',
        InList() => 'in list',
        QualifiedColumn() => 'qualified column',
        Conjunction() => 'and',
        Disjunction() => 'or',
        Negation() => 'not',
        Parenthesized() => 'paren',
        Aliased() => 'aliased',
        Collated() => 'collated',
        RawSql() => 'raw',
        JsonObject() => 'json object',
        Aggregate() => 'aggregate',
        FunctionCall() => 'call',
      };

      expect(describe(id), 'column id');
      expect(describe(id.eq(1)), 'comparison');
      expect(describe(id.sameAs(name)), 'reference comparison');
      expect(describe(id.count.gt(1)), 'comparison');
      expect(describe(id.count), 'aggregate');
      expect(describe(const RawSql('1')), 'raw');
      expect(describe(const JsonObject({'id': RawSql('1')})), 'json object');
    });
  });

  group('CompiledQuery toString', () {
    test('omits args when there are none', () {
      expect(const SelectStatement().compile().toString(), 'SELECT *');
    });

    test('appends args when present', () {
      expect(
        SelectStatement(where: id.eq(7)).compile().toString(),
        'SELECT * WHERE "id" = ?  -- args: [7]',
      );
    });
  });
}
