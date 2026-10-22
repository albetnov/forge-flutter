import 'package:sqlite3_driver_forge/sqlite3_driver_forge.dart';
import 'package:test/test.dart';

void main() {
  group('formatSqlTrace', () {
    test('a select reports the sql, the parameters and the rows returned', () {
      final trace = SqlTrace(
        sql: 'SELECT "id" FROM "users" WHERE "age" > ?',
        args: <Object?>[30],
        kind: SqlTraceKind.select,
        rows: <Map<String, Object?>>[
          <String, Object?>{'id': 1},
          <String, Object?>{'id': 2},
        ],
        duration: const Duration(milliseconds: 2),
      );

      final text = formatSqlTrace(trace);

      expect(text, contains('SELECT "id" FROM "users" WHERE "age" > ?'));
      expect(text, contains('args: [30]'));
      expect(text, contains('2 rows returned'));
      expect(text, contains('in 2.0ms'));
      expect(text, contains('{id: 1}'));
      expect(text, contains('{id: 2}'));
    });

    test('an execute reports the rows affected', () {
      final trace = SqlTrace(
        sql: 'UPDATE "users" SET "name" = ? WHERE "id" = ?',
        args: <Object?>['ada', 7],
        kind: SqlTraceKind.execute,
        affectedRows: 1,
        duration: const Duration(microseconds: 800),
      );

      final text = formatSqlTrace(trace);

      expect(text, contains('args: [\'ada\', 7]'));
      expect(text, contains('1 row affected'));
      expect(text, contains('800µs'));
    });

    test('an insert reports the rows affected and the last id', () {
      final trace = SqlTrace(
        sql: 'INSERT INTO "users" ("name") VALUES (?)',
        args: <Object?>['ada'],
        kind: SqlTraceKind.insert,
        affectedRows: 1,
        lastInsertId: 42,
        duration: const Duration(milliseconds: 1),
      );

      final text = formatSqlTrace(trace);

      expect(text, contains('1 row affected, last id 42'));
    });

    test('a failure reports the error and no rows', () {
      final trace = SqlTrace(
        sql: 'SELECT * FROM "nope"',
        args: const <Object?>[],
        kind: SqlTraceKind.select,
        duration: const Duration(milliseconds: 1),
        error: StateError('no such table: nope'),
      );

      final text = formatSqlTrace(trace);

      expect(text, contains('FAILED'));
      expect(text, contains('no such table: nope'));
      expect(text, isNot(contains('rows returned')));
    });

    test('the result is trimmed to the requested rows, the count is not', () {
      final trace = SqlTrace(
        sql: 'SELECT * FROM "users"',
        args: const <Object?>[],
        kind: SqlTraceKind.select,
        rows: <Map<String, Object?>>[
          for (int i = 0; i < 10; i++) <String, Object?>{'id': i},
        ],
        duration: const Duration(milliseconds: 1),
      );

      final text = formatSqlTrace(trace, maxRows: 2);

      expect(text, contains('10 rows returned'));
      expect(text, contains('{id: 0}'));
      expect(text, contains('{id: 1}'));
      expect(text, isNot(contains('{id: 2}')));
      expect(text, contains('…8 more'));
    });

    test('long values are cut, short ones are not', () {
      final long = 'x' * 100;
      final trace = SqlTrace(
        sql: 'SELECT ?',
        args: <Object?>[long],
        kind: SqlTraceKind.select,
        rows: <Map<String, Object?>>[
          <String, Object?>{'name': long},
        ],
        duration: const Duration(milliseconds: 1),
      );

      final text = formatSqlTrace(trace, maxValueLength: 10);

      expect(text, contains('…'));
      expect(text, isNot(contains(long)));
    });

    test('a blob is summarized instead of dumped', () {
      final trace = SqlTrace(
        sql: 'SELECT ?',
        args: <Object?>[null],
        kind: SqlTraceKind.select,
        duration: const Duration(milliseconds: 1),
      );

      expect(formatSqlTrace(trace), contains('args: [null]'));
    });
  });

  group('driver tracing', () {
    test('a select is traced with the rows it returned', () async {
      final List<SqlTrace> traces = <SqlTrace>[];
      final driver = SqliteDriver.inMemory(onTrace: traces.add);
      addTearDown(driver.disconnect);

      await driver.connect();
      await driver.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);');
      await driver.insert('INSERT INTO t (v) VALUES (?)', <Object?>['ada']);
      await driver.query('SELECT * FROM t');

      final select = traces.last;
      expect(select.kind, SqlTraceKind.select);
      expect(select.sql, 'SELECT * FROM t');
      expect(select.returnedRows, 1);
      expect(select.rows.single['v'], 'ada');
      expect(select.failed, isFalse);
    });

    test(
      'an insert is traced with the rows affected and the last id',
      () async {
        final List<SqlTrace> traces = <SqlTrace>[];
        final driver = SqliteDriver.inMemory(onTrace: traces.add);
        addTearDown(driver.disconnect);

        await driver.connect();
        await driver.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);',
        );
        final id = await driver.insert(
          'INSERT INTO t (v) VALUES (?)',
          <Object?>['ada'],
        );

        final insert = traces.last;
        expect(insert.kind, SqlTraceKind.insert);
        expect(insert.affectedRows, 1);
        expect(insert.lastInsertId, id);
        expect(insert.args, <Object?>['ada']);
      },
    );

    test('an execute is traced with the rows affected', () async {
      final List<SqlTrace> traces = <SqlTrace>[];
      final driver = SqliteDriver.inMemory(onTrace: traces.add);
      addTearDown(driver.disconnect);

      await driver.connect();
      await driver.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);');
      await driver.insert('INSERT INTO t (v) VALUES (?)', <Object?>['ada']);
      await driver.execute('UPDATE t SET v = ? WHERE id = ?', <Object?>[
        'grace',
        1,
      ]);

      final update = traces.last;
      expect(update.kind, SqlTraceKind.execute);
      expect(update.affectedRows, 1);
    });

    test(
      'a failing statement is traced and the error still reaches the caller',
      () async {
        final List<SqlTrace> traces = <SqlTrace>[];
        final driver = SqliteDriver.inMemory(onTrace: traces.add);
        addTearDown(driver.disconnect);

        await driver.connect();
        await expectLater(
          driver.query('SELECT * FROM nope'),
          throwsA(isA<SqliteDriverException>()),
        );

        final failure = traces.last;
        expect(failure.failed, isTrue);
        expect(failure.error, isA<SqliteDriverException>());
        expect(failure.returnedRows, 0);
      },
    );

    test('no sink means no tracing and no failure', () async {
      final driver = SqliteDriver.inMemory();
      addTearDown(driver.disconnect);

      await driver.connect();
      await driver.execute('CREATE TABLE t (id INTEGER PRIMARY KEY);');

      expect(await driver.query('SELECT * FROM t'), isEmpty);
    });

    test('a sink that throws never breaks the statement', () async {
      final driver = SqliteDriver.inMemory(
        onTrace: (SqlTrace trace) => throw StateError('sink is broken'),
      );
      addTearDown(driver.disconnect);

      await driver.connect();
      await driver.execute('CREATE TABLE t (id INTEGER PRIMARY KEY);');

      expect(await driver.query('SELECT * FROM t'), isEmpty);
    });
  });
}
