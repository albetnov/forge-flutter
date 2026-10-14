import 'package:sqlite_schema_forge/sqlite_schema_forge.dart';
import 'package:test/test.dart';

void main() {
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
