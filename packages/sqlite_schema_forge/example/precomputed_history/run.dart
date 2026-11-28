import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_schema_forge/sqlite_schema_forge.dart';

import 'schemas.dart';

Future<void> main() async {
  final database = sqlite3.openInMemory();
  final db = _SqliteExecutor(database);
  try {
    // Simulate an installed v1 database with data that needs the v2 backfill.
    database.execute(schemaV1.tables.single.toCreateTableSql());
    database.execute("INSERT INTO users (name) VALUES ('Ada Lovelace');");
    database.execute('PRAGMA user_version = 1;');

    final history = MigrationArtifactStore(
      _FileMigrationLoader(Directory('build/precomputed-history/migrations')),
    );
    await SqliteSchemaForge.migrateWithUpgrades(
      db: db,
      targetSchema: schemaV3,
      migrationHistory: history,
      upgrades: [
        Upgrade.from(1).to(
          2,
          MigrationHook((txn, from, to) async {
            await txn.execute(
              'UPDATE users SET normalized_name = lower(name);',
            );
          }),
        ),
      ],
    );

    final migratedUser = database
        .select('SELECT name, normalized_name FROM users LIMIT 1;')
        .single;
    stdout.writeln(
      'Schema v${database.select('PRAGMA user_version;').single['user_version']}: '
      '${migratedUser['name']} -> ${migratedUser['normalized_name']}',
    );
  } finally {
    database.close();
  }
}

final class _FileMigrationLoader implements MigrationArtifactLoader {
  _FileMigrationLoader(this.directory);

  final Directory directory;

  @override
  Future<String> loadManifest() =>
      File('${directory.path}/manifest.json').readAsString();

  @override
  Future<String> loadChunk(String file) =>
      File('${directory.path}/$file').readAsString();
}

final class _SqliteExecutor implements DatabaseExecutor {
  _SqliteExecutor(this.database);

  final Database database;

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    final rows = database.select(sql, arguments ?? const []);
    return [
      for (final row in rows) {for (final key in row.keys) key: row[key]},
    ];
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async =>
      database.execute(sql, arguments ?? const []);

  @override
  Future<T> transaction<T>(
    Future<T> Function(DatabaseExecutor txn) action,
  ) async {
    database.execute('BEGIN;');
    try {
      final result = await action(this);
      database.execute('COMMIT;');
      return result;
    } catch (_) {
      database.execute('ROLLBACK;');
      rethrow;
    }
  }
}
