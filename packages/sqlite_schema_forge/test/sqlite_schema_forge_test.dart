import 'package:sqlite_schema_forge/sqlite_schema_forge.dart';
import 'package:test/test.dart';

final class _RecordingExecutor implements DatabaseExecutor {
  int transactionCount = 0;
  int version = 0;
  final List<String> statements = [];
  final Set<String> existingTables = {};
  final Map<String, Set<String>> existingColumns = {};

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    if (sql == 'PRAGMA user_version;') {
      return [
        {'user_version': version},
      ];
    }
    if (sql.startsWith('PRAGMA table_info(')) {
      final table = sql.substring("PRAGMA table_info('".length, sql.length - 2);
      return (existingColumns[table] ?? {})
          .map((name) => {'name': name})
          .toList();
    }
    if (sql.contains('sqlite_master')) {
      return existingTables.map((name) => {'name': name}).toList();
    }
    return [];
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    statements.add(sql);
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(DatabaseExecutor txn) action,
  ) async {
    transactionCount++;
    return action(this);
  }
}

void main() {
  group('hook-backed migration API', () {
    test(
      'versioned upgrades run only their bound callbacks in order',
      () async {
        final db = _RecordingExecutor()
          ..version = 5
          ..existingTables.add('users')
          ..existingColumns['users'] = {'id'};
        final calls = <String>[];

        await SqliteSchemaForge.migrateWithUpgrades(
          db: db,
          targetSchema: Schema(
            version: 7,
            tables: [
              Table('users', [Column.id('id')]),
            ],
          ),
          upgrades: [
            Upgrade.from(5).to(
              6,
              MigrationHook((_, from, to) async => calls.add('$from->$to')),
            ),
            Upgrade.from(6).to(7, MigrationHook.noop()),
          ],
        );

        expect(calls, ['5->6']);
        expect(db.transactionCount, 1);
      },
    );

    test(
      'destructive upgrade reports missing exact transition definitions',
      () async {
        final db = _RecordingExecutor()
          ..version = 5
          ..existingTables.add('users')
          ..existingColumns['users'] = {'id', 'old'};

        await expectLater(
          SqliteSchemaForge.migrateWithUpgrades(
            db: db,
            targetSchema: Schema(
              version: 7,
              tables: [
                Table('users', [Column.id('id')]),
              ],
            ),
            upgrades: [Upgrade.from(6).to(7, MigrationHook.noop())],
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('5->6'),
            ),
          ),
        );
      },
    );

    test(
      'migrateWithHooks rejects missing upgrade hook with destructive steps',
      () async {
        final db = _RecordingExecutor()
          ..version = 1
          ..existingTables.add('users')
          ..existingColumns['users'] = {'id', 'obsolete'};

        await expectLater(
          SqliteSchemaForge.migrateWithHooks(
            db: db,
            targetSchema: Schema(
              version: 2,
              tables: [
                Table('users', [Column.id('id')]),
              ],
            ),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              allOf(contains('onUpgrade'), contains('users')),
            ),
          ),
        );
        expect(db.transactionCount, 0);
      },
    );

    test(
      'rejects a destructive plan without a hook and explains why',
      () async {
        final plan = MigrationPlan(
          fromVersion: 1,
          toVersion: 2,
          steps: const [
            PlanStep(
              type: ChangeType.rebuildTable,
              targetTable: 'users',
              sql: 'DROP TABLE users;',
              description: 'Remove the obsolete users column',
              isDestructive: true,
            ),
          ],
        );

        await expectLater(
          SqliteSchemaForge.applyPlanWithHook(
            db: _RecordingExecutor(),
            plan: plan,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('version 1 to 2'),
                contains('Remove the obsolete users column'),
                contains('MigrationHook.noop()'),
              ),
            ),
          ),
        );
      },
    );

    test(
      'noop explicitly permits destructive plan in one transaction',
      () async {
        final db = _RecordingExecutor();
        final calls = <String>[];
        final plan = MigrationPlan(
          fromVersion: 1,
          toVersion: 2,
          steps: const [
            PlanStep(
              type: ChangeType.rebuildTable,
              targetTable: 'users',
              sql: 'DROP TABLE users;',
              description: 'Remove obsolete data',
              isDestructive: true,
            ),
          ],
        );

        final result = await SqliteSchemaForge.applyPlanWithHook(
          db: db,
          plan: plan,
          hook: MigrationHook((_, from, to) async => calls.add('$from->$to')),
        );

        expect(calls, ['1->2']);
        expect(db.transactionCount, 1);
        expect(result.executedSql, ['DROP TABLE users;']);
      },
    );
  });

  group('Column.toSql', () {
    test('id factory emits an autoincrement primary key', () {
      expect(
        Column.id('id').toSql(),
        '"id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL',
      );
    });

    test('text defaults to nullable', () {
      expect(Column.text('name').toSql(), '"name" TEXT');
    });

    test('nullable: false adds NOT NULL', () {
      expect(
        Column.text('name', nullable: false).toSql(),
        '"name" TEXT NOT NULL',
      );
    });

    test('unique adds UNIQUE', () {
      expect(Column.text('email', unique: true).toSql(), '"email" TEXT UNIQUE');
    });

    test('a string default is quoted, a RawSql one is not', () {
      expect(
        Column.text('role', defaultValue: 'user').toSql(),
        '"role" TEXT DEFAULT \'user\'',
      );
      expect(
        Column.datetime(
          'created_at',
          defaultValue: RawSql.currentTimestamp,
        ).toSql(),
        '"created_at" TEXT DEFAULT CURRENT_TIMESTAMP',
      );
      expect(
        Column.integer('rank', defaultValue: 0).toSql(),
        '"rank" INTEGER DEFAULT 0',
      );
    });

    test('integer takes primaryKey and autoIncrement', () {
      expect(
        Column.integer(
          'id',
          primaryKey: true,
          autoIncrement: true,
          nullable: false,
        ).toSql(),
        '"id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL',
      );
    });

    test('a non-id primary key needs no autoincrement', () {
      expect(
        const Column(
          name: 'slug',
          type: DataType.text,
          primaryKey: true,
          nullable: false,
        ).toSql(),
        '"slug" TEXT PRIMARY KEY NOT NULL',
      );
    });

    test('references quotes both identifiers', () {
      expect(
        Column.integer('user_id', refTable: 'users', refCol: 'id').toSql(),
        '"user_id" INTEGER REFERENCES "users"("id")',
      );
    });

    test('a reserved word or a quote in the name is escaped', () {
      expect(Column.text('order').toSql(), '"order" TEXT');
      expect(Column.text('a"b').toSql(), '"a""b" TEXT');
    });
  });

  group('Table.toCreateTableSql', () {
    test('joins the column definitions and quotes the name', () {
      final table = Table('users', [
        Column.id('id'),
        Column.text('name', nullable: false),
      ]);
      expect(
        table.toCreateTableSql(),
        'CREATE TABLE IF NOT EXISTS "users" '
        '("id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, "name" TEXT NOT NULL);',
      );
    });

    test('a table named after a reserved word still creates', () {
      expect(
        Table('order', [Column.id('id')]).toCreateTableSql(),
        'CREATE TABLE IF NOT EXISTS "order" '
        '("id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL);',
      );
    });
  });

  group('Index.toSql', () {
    test('derives the name and quotes every identifier', () {
      final index = Index(columns: ['email']);

      expect(
        index.toSql('users'),
        'CREATE INDEX IF NOT EXISTS "idx_users_email" ON "users" ("email");',
      );
    });

    test('unique adds UNIQUE and a uniq_ prefix', () {
      expect(
        Index(columns: ['email'], unique: true).toSql('users'),
        'CREATE UNIQUE INDEX IF NOT EXISTS "uniq_users_email" ON "users" ("email");',
      );
    });

    test('an explicit name wins over the derived one', () {
      expect(
        Index(name: 'by_email', columns: ['email']).toSql('users'),
        'CREATE INDEX IF NOT EXISTS "by_email" ON "users" ("email");',
      );
    });
  });
}
