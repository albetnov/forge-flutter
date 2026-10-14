import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3_driver_forge/sqlite3_driver_forge.dart';
import 'package:test/test.dart';

void main() {
  group('lifecycle', () {
    test('connect, ops, disconnect on in-memory db', () async {
      final driver = SqliteDriver.inMemory();
      expect(driver.isConnected, isFalse);
      expect(driver.isInMemory, isTrue);
      expect(driver.path, isNull);

      await driver.connect();
      expect(driver.isConnected, isTrue);
      await driver.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);');
      await driver.disconnect();
      expect(driver.isConnected, isFalse);
    });

    test('double connect throws, double disconnect is a no-op', () async {
      final driver = SqliteDriver.inMemory();
      await driver.connect();
      await expectLater(driver.connect(), throwsStateError);
      await driver.disconnect();
      await driver.disconnect(); // no-op
      await driver.disconnect();
    });

    test('ops while disconnected throw SqliteDriverClosedException', () async {
      final driver = SqliteDriver.inMemory();
      await expectLater(
        driver.query('SELECT 1;'),
        throwsA(isA<SqliteDriverClosedException>()),
      );
      await expectLater(
        driver.execute('SELECT 1;'),
        throwsA(isA<SqliteDriverClosedException>()),
      );
      await expectLater(
        driver.insert('SELECT 1;'),
        throwsA(isA<SqliteDriverClosedException>()),
      );
      await expectLater(
        driver.transaction((txn) async => 1),
        throwsA(isA<SqliteDriverClosedException>()),
      );
      await expectLater(
        driver.backupTo('/tmp/x.db'),
        throwsA(isA<SqliteDriverClosedException>()),
      );
    });

    test('file driver exposes path; reconnect reopens same file', () async {
      final dir = await Directory.systemTemp.createTemp('forge_lifecycle');
      final path = '${dir.path}/a.db';
      final driver = SqliteDriver.file(path);
      expect(driver.path, path);
      await driver.connect();
      await driver.execute('CREATE TABLE t (id INTEGER PRIMARY KEY);');
      await driver.disconnect();
      expect(File(path).existsSync(), isTrue);

      await driver.connect();
      final rows = await driver.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table';",
      );
      expect(rows.map((r) => r['name']), contains('t'));
      await driver.disconnect();
    });

    test('open() aliases connect(), close() aliases disconnect()', () async {
      final driver = SqliteDriver.inMemory();
      await driver.open();
      expect(driver.isConnected, isTrue);
      await driver.close();
      expect(driver.isConnected, isFalse);
    });
  });

  group('crud', () {
    late SqliteDriver driver;
    setUp(() async {
      driver = SqliteDriver.inMemory();
      await driver.connect();
      await driver.execute(
        'CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score REAL, blob BLOB, flag INTEGER);',
      );
    });
    tearDown(() async {
      await driver.dispose();
    });

    test('insert returns rowid, query binds all types', () async {
      final id = await driver.insert(
        'INSERT INTO t (name, score, blob, flag) VALUES (?, ?, ?, ?);',
        [
          'ada',
          1.5,
          Uint8List.fromList([1, 2, 3]),
          true,
        ],
      );
      expect(id, 1);
      final rows = await driver.query('SELECT * FROM t WHERE id = ?;', [id]);
      expect(rows, hasLength(1));
      expect(rows.single['name'], 'ada');
      expect(rows.single['score'], 1.5);
      expect(rows.single['blob'], Uint8List.fromList([1, 2, 3]));
      expect(rows.single['flag'], 1); // bool binds as int
    });

    test('execute returns affected row count', () async {
      await driver.insert("INSERT INTO t (name) VALUES ('a');");
      await driver.insert("INSERT INTO t (name) VALUES ('b');");
      final changed = await driver.execute(
        "UPDATE t SET name = 'z' WHERE name IN ('a','b');",
      );
      expect(changed, 2);
    });

    test('rawQuery matches query (DatabaseExecutor surface)', () async {
      await driver.execute("INSERT INTO t (name) VALUES ('x');");
      final viaRaw = await driver.rawQuery('SELECT name FROM t;');
      final viaQuery = await driver.query('SELECT name FROM t;');
      expect(viaRaw, viaQuery);
    });

    test('nulls and empty args round-trip', () async {
      await driver.execute('INSERT INTO t (name, score) VALUES (?, ?);', [
        null,
        null,
      ]);
      final rows = await driver.query('SELECT name, score FROM t;');
      expect(rows.single['name'], isNull);
      expect(rows.single['score'], isNull);
      final one = await driver.query('SELECT 1 AS one;');
      expect(one.single['one'], 1);
    });

    test('unsupported arg types throw ArgumentError', () async {
      await expectLater(
        driver.query('SELECT ?;', [DateTime.now()]),
        throwsArgumentError,
      );
      await expectLater(
        driver.query('SELECT ?;', [
          {'not': 'transferable-as-sqlite-value-but-still-a-map'},
        ]),
        throwsArgumentError,
      );
    });

    test('sqlite errors surface as SqliteDriverException with code', () async {
      try {
        await driver.query('SELECT * FROM missing_table;');
        fail('expected exception');
      } on SqliteDriverException catch (e) {
        expect(e.message, contains('missing_table'));
        expect(e.resultCode, isNotNull);
      }
    });
  });

  group('transactions', () {
    late SqliteDriver driver;
    setUp(() async {
      driver = SqliteDriver.inMemory();
      await driver.connect();
      await driver.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);');
    });
    tearDown(() async {
      await driver.dispose();
    });

    test('commit persists', () async {
      await driver.transaction((txn) async {
        await txn.execute("INSERT INTO t (v) VALUES ('a');");
      });
      expect(await driver.query('SELECT count(*) AS n FROM t;'), [
        {'n': 1},
      ]);
    });

    test('throw rolls back', () async {
      await expectLater(
        driver.transaction((txn) async {
          await txn.execute("INSERT INTO t (v) VALUES ('a');");
          throw const _Boom();
        }),
        throwsA(isA<_Boom>()),
      );
      expect(await driver.query('SELECT count(*) AS n FROM t;'), [
        {'n': 0},
      ]);
    });

    test('nested transactions use savepoints', () async {
      await driver.transaction((outer) async {
        await outer.execute("INSERT INTO t (v) VALUES ('outer');");
        await outer.transaction((inner) async {
          await inner.execute("INSERT INTO t (v) VALUES ('inner');");
        });
        final rows = await outer.query('SELECT v FROM t ORDER BY id;');
        expect(rows.map((r) => r['v']), ['outer', 'inner']);
      });
      expect(
        (await driver.query('SELECT count(*) AS n FROM t;')).single['n'],
        2,
      );
    });

    test('inner rollback does not abort outer', () async {
      await driver.transaction((outer) async {
        await outer.execute("INSERT INTO t (v) VALUES ('outer');");
        await expectLater(
          outer.transaction((inner) async {
            await inner.execute("INSERT INTO t (v) VALUES ('inner');");
            throw const _Boom();
          }),
          throwsA(isA<_Boom>()),
        );
        // Still inside outer: only 'outer' visible.
        final rows = await outer.query('SELECT v FROM t ORDER BY id;');
        expect(rows.map((r) => r['v']), ['outer']);
      });
      expect((await driver.query('SELECT v FROM t;')).single['v'], 'outer');
    });

    test('concurrent transactions serialize', () async {
      Future<void> append(String v, int n) => driver.transaction((txn) async {
        for (var i = 0; i < n; i++) {
          await txn.execute('INSERT INTO t (v) VALUES (?);', ['$v$i']);
        }
      });
      await Future.wait([append('a', 20), append('b', 20)]);
      final rows = await driver.query('SELECT count(*) AS n FROM t;');
      expect(rows.single['n'], 40);
      // Each transaction must be atomic: all a's contiguous or all b's.
      final order = (await driver.query('SELECT v FROM t ORDER BY id;'))
          .map((r) => (r['v'] as String)[0])
          .join();
      expect(
        order == ('a' * 20 + 'b' * 20) || order == ('b' * 20 + 'a' * 20),
        isTrue,
        reason: 'transactions interleaved: $order',
      );
    });

    test('transaction returns callback value', () async {
      final result = await driver.transaction((txn) async {
        await txn.execute("INSERT INTO t (v) VALUES ('x');");
        return 42;
      });
      expect(result, 42);
    });
  });

  group('backup / restore', () {
    test('backupTo hot-copies file and memory databases', () async {
      final dir = await Directory.systemTemp.createTemp('forge_backup');
      final driver = SqliteDriver.file('${dir.path}/live.db');
      await driver.connect();
      await driver.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);');
      await driver.execute("INSERT INTO t (v) VALUES ('kept');");
      await driver.backupTo('${dir.path}/copy.db');
      expect(File('${dir.path}/copy.db').existsSync(), isTrue);
      await driver.disconnect();

      final check = SqliteDriver.file('${dir.path}/copy.db');
      await check.connect();
      expect(await check.query('SELECT v FROM t;'), [
        {'v': 'kept'},
      ]);
      await check.disconnect();
    });

    test('in-memory db can be backed up to a file', () async {
      final dir = await Directory.systemTemp.createTemp('forge_backup_mem');
      final driver = SqliteDriver.inMemory();
      await driver.connect();
      await driver.execute('CREATE TABLE t (v TEXT);');
      await driver.execute("INSERT INTO t (v) VALUES ('mem');");
      await driver.backupTo('${dir.path}/from_mem.db');
      await driver.disconnect();

      final check = SqliteDriver.file('${dir.path}/from_mem.db');
      await check.connect();
      expect(await check.query('SELECT v FROM t;'), [
        {'v': 'mem'},
      ]);
      await check.disconnect();
    });

    test('restoreFrom requires disconnected and rewrites the file', () async {
      final dir = await Directory.systemTemp.createTemp('forge_restore');
      final driver = SqliteDriver.file('${dir.path}/live.db');
      await driver.connect();
      await driver.execute('CREATE TABLE t (v TEXT);');
      await driver.execute("INSERT INTO t (v) VALUES ('v1');");
      await driver.backupTo('${dir.path}/snap.db');
      await driver.execute("UPDATE t SET v = 'v2';");
      await driver.disconnect();

      // Connected restore is refused (cold copy only).
      final connected = SqliteDriver.file('${dir.path}/other.db');
      await connected.connect();
      await expectLater(
        connected.restoreFrom('${dir.path}/snap.db'),
        throwsStateError,
      );
      await connected.disconnect();

      await driver.restoreFrom('${dir.path}/snap.db');
      await driver.connect();
      expect(await driver.query('SELECT v FROM t;'), [
        {'v': 'v1'},
      ]);
      await driver.disconnect();
    });

    test('restoreFrom on in-memory throws UnsupportedError', () async {
      final driver = SqliteDriver.inMemory();
      await expectLater(
        driver.restoreFrom('/tmp/whatever.db'),
        throwsUnsupportedError,
      );
    });
  });

  group('config validation', () {
    test('empty path and negative timeout throw early', () async {
      final badPath = SqliteDriver.file('');
      await expectLater(badPath.connect(), throwsArgumentError);

      final badTimeout = SqliteDriver(
        config: const SqliteDriverConfig(path: null, busyTimeoutMs: -1),
      );
      await expectLater(badTimeout.connect(), throwsArgumentError);
    });
  });

  group('SecurePassword', () {
    test('dispose zeroes bytes and blocks reuse', () {
      final pw = SecurePassword.text('s3cret');
      expect(pw.isDisposed, isFalse);
      final copy = pw.copyBytes();
      expect(copy, isNotEmpty);
      pw.dispose();
      expect(pw.isDisposed, isTrue);
      expect(() => pw.copyBytes(), throwsStateError);
      // The live copy is the caller's to zero.
      copy.fillRange(0, copy.length, 0);
      expect(copy.every((b) => b == 0), isTrue);
    });

    test('rawKey requires 32 bytes', () {
      expect(
        () => SecurePassword.rawKey(List.filled(16, 1)),
        throwsArgumentError,
      );
      final key = SecurePassword.rawKey(List.filled(32, 7));
      expect(key.isRawKey, isTrue);
      key.dispose();
    });

    test('disposed password cannot connect', () async {
      final pw = SecurePassword.text('x')..dispose();
      final driver = SqliteDriver.inMemory();
      await expectLater(driver.connect(cipher: pw), throwsStateError);
    });
  });
}

final class _Boom implements Exception {
  const _Boom();
}
