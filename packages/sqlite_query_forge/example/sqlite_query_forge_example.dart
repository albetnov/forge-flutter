// Run with: dart run example/sqlite_query_forge_example.dart
import 'package:sqlite_query_forge/sqlite_query_forge.dart';

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
    _ => throw FormatException('Invalid user row structure: $row'),
  };
  @override
  String toString() => 'User($id, $name, $email, $isActive)';
}

/// A table cannot use the concise class header form, since it cannot be
/// combined with an `extends` clause.
final class UsersTable extends Table<User> {
  const UsersTable() : super('users', mapper: User.fromRow);

  Column<int> get id => const Column.id();
  Column<String> get name => const Column.text('name', nullable: false);
  Column<String> get email =>
      const Column.text('email', nullable: false, unique: true);
  Column<bool> get isActive =>
      const Column.integer('is_active', nullable: false, defaultValue: 1);

  // One declaration, both sides: the getters carry the DDL flags, and columns
  // lists what the migrator builds. Tables that never migrate leave it empty.
  @override
  List<Column<Object>> get columns => [id, name, email, isActive];
}

const users = UsersTable();

void show(String label, Statement statement) {
  final query = statement.compile();
  print('\n$label');
  print('  sql:  ${query.sql}');
  print('  args: ${query.args}');
}

void main() async {
  print('=== sqlite_query_forge: phase 3 ===');

  print('\nColumns:');
  print('  table         = ${users.tableName}');
  print('  users.id.name = "${users.id.name}"');
  print('  users.id      = ${users.id}');

  show(
    'Values are bound, never inlined',
    SelectStatement(
      from: users.source,
      where: users.name.eq("Robert'); DROP TABLE users;--"),
    ),
  );

  show(
    'Booleans bind as 1/0',
    DeleteStatement(users.source, users.isActive.eq(false)),
  );

  show(
    'Qualified columns',
    SelectStatement(
      from: users.source,
      columns: [users.qualify(users.id), users.qualify(users.name)],
    ),
  );

  print('\nFluent builder:');
  print(
    '  ${forge.selectFrom(users).select([users.id]).where(users.isActive.eq(true)).limit(10).compile().sql}',
  );

  show(
    'Join on a column-to-column key',
    SelectStatement(
      from: users.source,
      joins: [
        JoinClause.inner(
          users.sourceAs('u'),
          users.qualify(users.id, 'u').sameAs(users.qualify(users.id)),
        ),
      ],
    ),
  );

  show(
    'JSON object projection',
    SelectStatement(
      from: users.sourceAs('u'),
      columns: [
        JsonObject({
          'id': users.qualify(users.id, 'u'),
          'name': users.qualify(users.name, 'u'),
        }).alias('user'),
      ],
    ),
  );

  show(
    'Nested JSON object',
    SelectStatement(
      columns: [
        JsonObject({
          'id': users.id,
          'profile': JsonObject({'name': users.name}),
        }).alias('row'),
      ],
    ),
  );

  // ---- migrations --------------------------------------------------------

  print('\nMigrations:');
  print('  ${users.toSchemaTable().toCreateTableSql()}');

  // ---- execution ---------------------------------------------------------

  print('\nRunning against an in-memory executor:');
  final active = await forge
      .selectFrom(users)
      .where(users.isActive.eq(true))
      .getMany();
  print('  getMany (active)      = $active');
  final first = await forge.selectFrom(users).orderBy([
    OrderBy(users.name),
  ]).getFirst();
  print('  getFirst (by name)    = $first');
  print('  count                 = ${await forge.selectFrom(users).count()}');

  try {
    await forge.selectFrom(users).where(users.id.eq(999)).getSingle();
  } on ForgeCardinalityError catch (e) {
    print('  getSingle on 0 rows   -> ${e.message}');
  }

  try {
    await forge.selectFrom(users).getSingle();
  } on ForgeCardinalityError catch (e) {
    print('  getSingle on 3 rows   -> ${e.message}');
  }

  final (int, String) idAndName = await forge
      .selectFrom(users)
      .select([users.id, users.name])
      .map((row) => (row['id'] as int, row['name'] as String))
      .where(users.id.eq(2))
      .getSingle();
  print('\nmap() projects without a model: $idAndName');

  // ---- writes ------------------------------------------------------------

  final rowid = await forge.insertInto(users).values({
    'name': 'Ada',
    'email': 'ada@example.com',
    'is_active': true,
  }).execute();
  print('\nWrites:');
  print('  insert rowid          = $rowid');

  print(
    '  ${forge.insertInto(users).valuesAll([
      {'name': 'Grace', 'email': 'grace@example.com'},
      {'name': 'Linus', 'email': 'linus@example.com'},
    ]).onConflictIgnore().compile().sql}',
  );

  print(
    '  ${forge.update(users).values({'is_active': false}).where(users.id.gt(1)).compile().sql}',
  );
  print('  ${forge.deleteFrom(users).where(users.email.isNull).compile().sql}');

  final inserted = await forge
      .insertInto(users)
      .values({'name': 'Ada'})
      .onConflictUpdate(
        {'email': const RawSql('excluded."email"')},
        columns: [users.email],
      )
      .returning([users.id, users.name])
      .getMany();
  print('  returning             = $inserted');

  // ---- transactions -------------------------------------------------------

  print('\nTransaction:');
  final mark = _executor.log.length;
  await forge.transaction((tx) async {
    await tx.insertInto(users).values({'name': 'Margaret'}).execute();
    await tx.transaction((nested) async {
      await nested.deleteFrom(users).where(users.id.eq(3)).execute();
    });
  });
  for (final line in _executor.log.skip(mark)) {
    print('  $line');
  }

  try {
    await forge.transaction((tx) async {
      await tx.insertInto(users).values({'name': 'Alan'}).execute();
      throw StateError('rolled back');
    });
  } on StateError {
    print('  rolled back: ${_executor.log.last}');
  }
}

/// A throwaway executor. The package ships no driver by design.
final class _MemoryExecutor implements ForgeExecutor {
  _MemoryExecutor(this.rows);

  final List<Map<String, Object?>> rows;

  final List<String> log = [];

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    log.add('$sql  -- args: $args');
    if (sql.contains('COUNT(')) {
      return [
        {'count': rows.length},
      ];
    }
    final filter = args != null && args.isNotEmpty ? args.first : null;
    if (sql.contains('"id" = ?') && filter is int) {
      return rows.where((r) => r['id'] == filter).toList();
    }
    if (sql.contains('"is_active" = ?') && filter is int) {
      return rows.where((r) => r['is_active'] == filter).toList();
    }
    return rows;
  }

  @override
  Future<int> execute(String sql, [List<Object?>? args]) async {
    log.add('$sql  -- args: $args');
    return rows.length;
  }

  @override
  Future<int> insert(String sql, [List<Object?>? args]) async {
    log.add('$sql  -- args: $args');
    return 1;
  }

  @override
  Future<T> transaction<T>(Future<T> Function(ForgeExecutor txn) action) async {
    log.add('BEGIN');
    final snapshot = List.of(rows);
    try {
      final result = await action(this);
      log.add('COMMIT');
      return result;
    } catch (_) {
      rows
        ..clear()
        ..addAll(snapshot);
      log.add('ROLLBACK');
      rethrow;
    }
  }
}

final _executor = _MemoryExecutor([
  {'id': 1, 'name': 'Ada', 'email': 'ada@example.com', 'is_active': 1},
  {'id': 2, 'name': 'Grace', 'email': 'grace@example.com', 'is_active': 1},
  {'id': 3, 'name': 'Linus', 'email': 'linus@example.com', 'is_active': 0},
]);

final forge = Forge(_executor);
