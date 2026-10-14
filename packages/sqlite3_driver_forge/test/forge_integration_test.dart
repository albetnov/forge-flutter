import 'package:sqlite3_driver_forge/sqlite3_driver_forge.dart';
import 'package:sqlite_query_forge/sqlite_query_forge.dart';
import 'package:sqlite_schema_forge/sqlite_schema_forge.dart' as schema;
import 'package:test/test.dart';

/// Proves one [SqliteDriver] serves both forge packages: migrate the schema
/// through [DatabaseExecutor], then read/write through [Forge].
void main() {
  test('migrate with schema_forge, query with query_forge', () async {
    final driver = SqliteDriver.inMemory();
    await driver.connect();
    try {
      // Compile-time proof the driver satisfies both contracts.
      final ForgeExecutor forQueries = driver;
      final schema.DatabaseExecutor forMigrations = driver;
      expect(forQueries, same(driver));
      expect(forMigrations, same(driver));

      final result = await schema.SqliteSchemaForge.migrate(
        db: forMigrations,
        targetSchema: schema.Schema(
          version: 1,
          tables: [
            schema.Table('notes', [
              schema.Column.id(),
              schema.Column.text('body', nullable: false),
            ]),
          ],
        ),
      );
      expect(result.migrated, isTrue);

      final forge = Forge(forQueries);
      const notes = TableSource('notes');

      final rowid = await forge.insert(
        InsertStatement.one(notes, ['body'], ['via forge']),
      );
      expect(rowid, greaterThan(0));

      final bodies = await forge
          .selectFromSource(notes, (row) => row['body'] as String? ?? '')
          .getMany();
      expect(bodies, ['via forge']);

      // Forge-scoped transactions ride the same connection.
      await forge.transaction((txn) async {
        await txn.insert(InsertStatement.one(notes, ['body'], ['in txn']));
      });
      final after = await forQueries.query('SELECT count(*) AS n FROM notes;');
      expect(after.single['n'], 2);
    } finally {
      await driver.dispose();
    }
  });
}
