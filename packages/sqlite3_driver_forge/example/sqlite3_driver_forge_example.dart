import 'dart:io';

import 'package:sqlite3_driver_forge/sqlite3_driver_forge.dart';

/// Minimal end-to-end demo: file database, CRUD, transaction, hot backup.
Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('driver_forge_example');
  final driver = SqliteDriver.file('${dir.path}/example.db');

  await driver.connect();
  try {
    await driver.execute(
      'CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL);',
    );
    final id = await driver.insert('INSERT INTO notes (body) VALUES (?);', [
      'hello from the worker isolate',
    ]);
    print('inserted row $id');

    await driver.transaction((txn) async {
      await txn.execute('INSERT INTO notes (body) VALUES (?);', ['in txn']);
    });

    final rows = await driver.query('SELECT id, body FROM notes ORDER BY id;');
    for (final row in rows) {
      print('${row['id']}: ${row['body']}');
    }

    await driver.backupTo('${dir.path}/example.backup.db');
    print('backed up; db file at ${driver.path}');
  } finally {
    await driver.disconnect();
  }
}
