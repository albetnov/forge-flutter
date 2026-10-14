// This file imports the opt-in helper explicitly, since qualifyAs is not
// exported by the main entry point.
import 'package:sqlite_query_forge/qualify.dart';

import 'package:sqlite_query_forge/sqlite_query_forge.dart';
import 'package:test/test.dart';

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
}

const users = UsersTable();
const transactions = TransactionsTable();

void main() {
  group('qualifyAs', () {
    test('renders the column under the alias', () {
      final q = SelectStatement(where: transactions.userId.qualifyAs('t').eq(7))
          .compile();
      expect(q.sql, 'SELECT * WHERE "t"."user_id" = ?');
      expect(q.args, [7]);
    });

    test('is the same compiled output as Table.qualify', () {
      final viaTable = SelectStatement(
        where: users.qualify(users.id, 'u').eq(1),
      ).compile();
      final viaExtension = SelectStatement(where: users.id.qualifyAs('u').eq(1))
          .compile();

      expect(viaExtension.sql, viaTable.sql);
      expect(viaExtension.args, viaTable.args);
    });

    test('keeps the phantom type, so eq still checks it', () {
      // Same defect the typed operators on Column already have: a wrong value
      // type is rejected at compile time.
      expect(
        transactions.amount.qualifyAs('t').eq(100),
        isA<Comparison>().having((e) => e.value, 'value', 100),
      );
    });

    test('an alias the join does not bind is still emitted', () {
      // Nothing checks the alias against the source, so a mismatch is a
      // runtime SQL error, exactly as with Table.qualify.
      final q = SelectStatement(where: users.name.qualifyAs('nope').eq('Ada'))
          .compile();
      expect(q.sql, 'SELECT * WHERE "nope"."name" = ?');
    });

    test('works as a join key, which is what it is for', () {
      final on = users.id
          .qualifyAs('u')
          .sameAs(transactions.userId.qualifyAs('t'));
      final q = SelectStatement(
        from: users.source,
        joins: [JoinClause.inner(transactions.sourceAs('t'), on)],
      ).compile();
      expect(
        q.sql,
        'SELECT * FROM "users" INNER JOIN "transactions" AS "t" '
        'ON "u"."id" = "t"."user_id"',
      );
    });

    test('an aliased projection round-trips through the mapper', () async {
      final row = {'id': 1, 'name': 'Ada', 'is_active': 1};
      final executor = _FakeExecutor()..responses = [row];
      final user = await Forge(executor)
          .selectFromSource<Object>(users.sourceAs('u'), (r) => r['id'] as int)
          .select([users.id.qualifyAs('u')])
          .getSingle();
      expect(user, 1);
      expect(
        executor.recorded.single.sql,
        'SELECT "u"."id" FROM "users" AS "u" LIMIT ?',
      );
    });
  });
}

final class _FakeExecutor implements ForgeExecutor {
  List<Map<String, Object?>> responses = const [];

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
    return 1;
  }

  @override
  Future<T> transaction<T>(Future<T> Function(ForgeExecutor txn) action) =>
      action(this);
}
