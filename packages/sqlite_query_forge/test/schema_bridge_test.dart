import 'package:sqlite_query_forge/sqlite_query_forge.dart';
import 'package:sqlite_schema_forge/sqlite_schema_forge.dart' as sf;
import 'package:test/test.dart';

final class User {
  User(this.id, this.name, this.email);

  final int id;
  final String name;
  final String email;

  factory User.fromRow(Map<String, Object?> row) => switch (row) {
    {'id': int id, 'name': String name, 'email': String email} => User(
      id,
      name,
      email,
    ),
    _ => throw FormatException('bad user row: $row'),
  };
}

/// One declaration serving both halves: the getters carry the DDL flags, and
/// [columns] lists what the migrator builds.
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

final class TransactionsTable extends Table<User> {
  const TransactionsTable() : super('transactions', mapper: User.fromRow);

  Column<int> get id => const Column.id();

  Column<int> get userId => const Column.integer(
    'user_id',
    nullable: false,
    referencesTable: 'users',
    referencesColumn: 'id',
  );

  Column<int> get amount => const Column.integer('amount', nullable: false);

  @override
  List<Column<Object>> get columns => [id, userId, amount];
}

/// A query-only table: a plain [Column] declares no type, so nothing migrates.
final class SessionsTable extends Table<User> {
  const SessionsTable() : super('sessions', mapper: User.fromRow);

  Column<int> get id => const Column('id');
}

const users = UsersTable();
const transactions = TransactionsTable();
const sessions = SessionsTable();

const usersCreateTable =
    'CREATE TABLE IF NOT EXISTS "users" '
    '("id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, '
    '"name" TEXT NOT NULL, '
    '"email" TEXT NOT NULL UNIQUE, '
    '"is_active" INTEGER NOT NULL DEFAULT 1);';

const transactionsCreateTable =
    'CREATE TABLE IF NOT EXISTS "transactions" '
    '("id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, '
    '"user_id" INTEGER NOT NULL REFERENCES "users"("id"), '
    '"amount" INTEGER NOT NULL);';

String sqlOf(Statement statement) => statement.compile().sql;

/// A table declaring an arbitrary column list, for DDL goldens.
final class DeclaredTable extends Table<User> {
  const DeclaredTable(
    super.tableName,
    this._columns, {
    super.mapper = User.fromRow,
  });

  final List<Column<Object>> _columns;

  @override
  List<Column<Object>> get columns => _columns;
}

/// A table with nothing declared at all.
final class BareTable extends Table<User> {
  const BareTable() : super('bare', mapper: User.fromRow);
}

final class _FakeExecutor implements ForgeExecutor {
  int userVersion = 0;

  List<Map<String, Object?>> tableInfo = const [];

  final List<CompiledQuery> recorded = [];

  int transactions = 0;

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    recorded.add(CompiledQuery(sql, args ?? const []));
    if (sql.contains('user_version')) {
      return [
        {'user_version': userVersion},
      ];
    }
    if (sql.startsWith('PRAGMA table_info')) return tableInfo;
    return const [];
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
  Future<T> transaction<T>(Future<T> Function(ForgeExecutor txn) action) async {
    transactions++;
    return action(this);
  }
}

void main() {
  _FakeExecutor driver() => _FakeExecutor();

  group('toSchemaTable', () {
    test('compiles the declared columns into CREATE TABLE', () {
      expect(users.toSchemaTable().toCreateTableSql(), usersCreateTable);
    });

    test('renders a foreign key', () {
      expect(
        transactions.toSchemaTable().toCreateTableSql(),
        transactionsCreateTable,
      );
    });

    test('a TEXT primary key bridges with its flag', () {
      const settings = DeclaredTable('app_settings', [
        Column.text('key', primaryKey: true, nullable: false),
      ]);
      expect(
        settings.toSchemaTable().toCreateTableSql(),
        'CREATE TABLE IF NOT EXISTS "app_settings" '
        '("key" TEXT PRIMARY KEY NOT NULL);',
      );
    });

    test('carries the table name and the columns', () {
      final schemaTable = users.toSchemaTable();
      expect(schemaTable.name, 'users');
      expect(schemaTable.columns.map((c) => c.name), [
        'id',
        'name',
        'email',
        'is_active',
      ]);
      expect(schemaTable.indexes, isEmpty);
    });

    test('a listed column with no type is refused, not silently migrated', () {
      expect(() => sessions.toSchemaTable(), throwsStateError);
    });

    test('an empty column list is refused, since nothing would be created', () {
      expect(const BareTable().columns, isEmpty);
      expect(() => const BareTable().toSchemaTable(), throwsStateError);
    });
  });

  group('extend', () {
    MigrationSchema base() => schemaOf(
      version: 1,
      tables: [
        DeclaredTable('accounts', [Column.id()]),
        DeclaredTable('transactions', [Column.id()]),
      ],
    );

    test('attaches indexes to the named tables', () {
      final extended = base().extend(
        indexes: {
          'accounts': [SchemaIndex(columns: ['account_type'])],
        },
      );
      expect(
        extended.tables
            .firstWhere((t) => t.name == 'accounts')
            .indexes
            .map((i) => i.toSql('accounts')),
        [
          'CREATE INDEX IF NOT EXISTS "idx_accounts_account_type" '
              'ON "accounts" ("account_type");',
        ],
      );
      expect(
        extended.tables
            .firstWhere((t) => t.name == 'transactions')
            .indexes,
        isEmpty,
      );
    });

    test('an unknown table name throws rather than dropping the index', () {
      expect(
        () => base().extend(
          indexes: {
            'nope': [SchemaIndex(columns: ['x'])],
          },
        ),
        throwsStateError,
      );
    });

    test('appends virtual tables and triggers, keeping the version', () {
      final extended = base().extend(
        virtualTables: [
          SchemaVirtualTable.fts5(
            'transactions_fts',
            columns: ['payee'],
            contentTable: 'transactions',
          ),
        ],
        triggers: [
          SchemaTrigger(
            name: 't',
            timing: sf.TriggerTiming.after,
            event: sf.TriggerEvent.insert,
            targetTable: 'transactions',
            body: 'SELECT 1;',
          ),
        ],
      );
      expect(extended.version, 1);
      expect(extended.virtualTables.map((v) => v.name), ['transactions_fts']);
      expect(extended.virtualTables.single.contentRowId, 'id');
      expect(extended.triggers.map((t) => t.name), ['t']);
    });

    test('an empty extend keeps the schema as is', () {
      final extended = base().extend();
      expect(extended.version, 1);
      expect(extended.tables.map((t) => t.name), ['accounts', 'transactions']);
      expect(extended.virtualTables, isEmpty);
      expect(extended.triggers, isEmpty);
    });
  });

  group('columns as a declaration', () {
    test('the plain Column stays usable in a query', () {
      final q = SelectStatement(
        from: sessions.source,
        where: sessions.id.eq(1),
      ).compile();
      expect(q.sql, 'SELECT * FROM "sessions" WHERE "id" = ?');
      expect(q.args, [1]);
    });

    test('the flag-carrying Column still renders as an identifier', () {
      expect(
        sqlOf(SelectStatement(from: users.source, where: users.name.eq('Ada'))),
        'SELECT * FROM "users" WHERE "name" = ?',
      );
    });

    test('the comparison keeps its defect check', () {
      expect(
        sqlOf(SelectStatement(where: users.id.eq(42))),
        'SELECT * WHERE "id" = ?',
      );
    });
  });

  group('defaults', () {
    test('a RawSql default is written verbatim', () {
      const events = DeclaredTable('events', [
        Column.id(),
        Column.dateTime(
          'created_at',
          nullable: false,
          defaultValue: RawSql('CURRENT_TIMESTAMP'),
        ),
      ]);
      expect(
        events.toSchemaTable().toCreateTableSql(),
        'CREATE TABLE IF NOT EXISTS "events" '
        '("id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, '
        '"created_at" TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);',
      );
    });

    test('a String default is quoted', () {
      const roles = DeclaredTable('roles', [
        Column.id(),
        Column.text('name', nullable: false, defaultValue: 'member'),
      ]);
      expect(
        roles.toSchemaTable().toCreateTableSql(),
        'CREATE TABLE IF NOT EXISTS "roles" '
        '("id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, '
        '"name" TEXT NOT NULL DEFAULT \'member\');',
      );
    });
  });

  group('other column types', () {
    test('real and blob map to their own affinities', () {
      const files = DeclaredTable('files', [
        Column.id(),
        Column.real('size'),
        Column.blob('data'),
      ]);
      expect(
        files.toSchemaTable().toCreateTableSql(),
        'CREATE TABLE IF NOT EXISTS "files" '
        '("id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, '
        '"size" REAL, "data" BLOB);',
      );
    });
  });

  group('schemaOf', () {
    test('collects the declared tables under one version', () {
      final target = schemaOf(version: 3, tables: [users, transactions]);
      expect(target.version, 3);
      expect(target.tables.map((t) => t.name), ['users', 'transactions']);
      expect(target.tables[1].toCreateTableSql(), transactionsCreateTable);
    });

    test('a query-only table is refused, since versioning needs the DDL', () {
      expect(() => schemaOf(version: 1, tables: [sessions]), throwsStateError);
    });

    test('an empty table list is a version-only migration, and is allowed', () {
      final target = schemaOf(version: 1, tables: <Table<Object>>[]);
      expect(target.tables, isEmpty);
    });
  });

  group('ForgeDatabaseExecutor', () {
    test(
      'maps rawQuery to query and drops the row count from execute',
      () async {
        final inner = driver();
        final db = ForgeDatabaseExecutor(inner);

        expect(await db.rawQuery('SELECT 1'), isEmpty);
        await db.execute('PRAGMA foreign_keys = ON;');

        expect(inner.recorded.map((q) => q.sql), [
          'SELECT 1',
          'PRAGMA foreign_keys = ON;',
        ]);
      },
    );

    test('wraps the transaction it is handed', () async {
      final inner = driver();
      final typeName = await ForgeDatabaseExecutor(inner)
          .transaction((txn) async {
            expect(txn, isA<ForgeDatabaseExecutor>());
            return txn.runtimeType.toString();
          });
      expect(inner.transactions, 1);
      expect(typeName, 'ForgeDatabaseExecutor');
    });
  });

  group('migration end to end', () {
    test('a missing table becomes one createTable step', () async {
      final inner = driver();
      final plan = await sf.SqliteSchemaForge.plan(
        db: ForgeDatabaseExecutor(inner),
        targetSchema: schemaOf(version: 2, tables: [users]),
      );

      expect(plan.fromVersion, 0);
      expect(plan.toVersion, 2);
      expect(plan.steps.single.type, sf.ChangeType.createTable);
      expect(plan.steps.single.sql, usersCreateTable);
      expect(plan.steps.single.description, "Create table 'users'");
    });

    test(
      'migrate runs the plan inside a transaction and stamps the version',
      () async {
        final inner = driver();
        final result = await sf.SqliteSchemaForge.migrate(
          db: ForgeDatabaseExecutor(inner),
          targetSchema: schemaOf(version: 2, tables: [users]),
        );

        expect(result.migrated, isTrue);
        expect(result.executedSql, [
          usersCreateTable,
          'PRAGMA user_version = 2;',
        ]);
        expect(inner.transactions, 1);
      },
    );

    test('an up-to-date database migrates nothing', () async {
      final inner = driver()..userVersion = 2;
      final result = await sf.SqliteSchemaForge.migrate(
        db: ForgeDatabaseExecutor(inner),
        targetSchema: schemaOf(version: 2, tables: [users]),
      );

      expect(result.migrated, isFalse);
      expect(result.executedSql, isEmpty);
      expect(inner.recorded.map((q) => q.sql), ['PRAGMA user_version;']);
    });
  });
}
