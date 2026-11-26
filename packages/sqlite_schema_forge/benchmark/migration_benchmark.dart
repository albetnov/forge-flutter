import 'dart:math' as math;

import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_schema_forge/sqlite_schema_forge.dart';

/// Measures planner, asset, decode, validation, and real SQLite execution cost.
Future<void> main(List<String> args) async {
  final iterations = args.isEmpty ? 100 : int.parse(args.single);
  final previous = Schema(
    version: 1,
    tables: [
      for (var i = 0; i < 100; i++)
        Table('table_$i', [Column.id(), Column.text('value')]),
    ],
  );
  final target = Schema(
    version: 2,
    tables: [
      for (var i = 0; i < 100; i++)
        Table('table_$i', [
          Column.id(),
          Column.text('value'),
          Column.integer('revision', defaultValue: 0),
        ]),
    ],
  );
  final plan = await MigrationPlanCompiler.compile(
    previous: previous,
    current: target,
  );
  final artifacts = MigrationArtifactBundle.build(
    plans: [plan],
    schemaFingerprints: {2: SchemaSnapshot.fingerprint(target)},
  );
  final loader = _MemoryLoader(
    artifacts.manifest.encode(),
    artifacts.chunkFiles,
  );
  final store = MigrationArtifactStore(loader);
  final chunkFile = artifacts.chunkFiles.keys.single;
  final chunkText = artifacts.chunkFiles[chunkFile]!;

  Future<void> runtimePlanning() async {
    final db = _SqliteExecutor(previous);
    try {
      await SqliteSchemaForge.plan(db: db, targetSchema: target);
    } finally {
      db.close();
    }
  }

  Future<void> assetLoading() async {
    await loader.loadManifest();
    await loader.loadChunk(chunkFile);
  }

  Future<void> planDeserialization() async {
    MigrationPlanChunk.decode(chunkText);
  }

  Future<void> artifactValidation() async {
    MigrationArtifactBundle.fromAssets(
      manifest: MigrationManifest.decode(artifacts.manifest.encode()),
      chunkFiles: artifacts.chunkFiles,
    );
  }

  Future<void> sqliteExecution() async {
    final db = _SqliteExecutor(previous);
    try {
      await SqliteSchemaForge.applyPlan(db: db, plan: plan);
    } finally {
      db.close();
    }
  }

  Future<void> runtimePlanAndSqliteExecution() async {
    final db = _SqliteExecutor(previous);
    try {
      final runtimePlan = await SqliteSchemaForge.plan(
        db: db,
        targetSchema: target,
      );
      await SqliteSchemaForge.applyPlan(db: db, plan: runtimePlan);
    } finally {
      db.close();
    }
  }

  Future<void> precomputedLoadAndSqliteExecution() async {
    final db = _SqliteExecutor(previous);
    try {
      final path = await store.loadPath(fromVersion: 1, toVersion: 2);
      await SqliteSchemaForge.applyPlan(db: db, plan: path.plans.single);
    } finally {
      db.close();
    }
  }

  final measurements = <String, Future<void> Function()>{
    'runtime planning (real in-memory SQLite)': runtimePlanning,
    'asset reads (in-memory loader)': assetLoading,
    'plan deserialization': planDeserialization,
    'artifact validation': artifactValidation,
    'SQLite execution only (in-memory SQLite)': sqliteExecution,
    'runtime planning + SQLite execution': runtimePlanAndSqliteExecution,
    'precomputed load + SQLite execution': precomputedLoadAndSqliteExecution,
  };
  for (final entry in measurements.entries) {
    for (var i = 0; i < math.min(iterations ~/ 10, 10); i++) {
      await entry.value();
    }
    final watch = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      await entry.value();
    }
    watch.stop();
    print(
      '${entry.key}: ${(watch.elapsedMicroseconds / iterations / 1000).toStringAsFixed(3)} ms/op',
    );
  }
  print(
    'Fixture: 100 tables, one added column per table, $iterations iterations.',
  );
  print(
    'SQLite is in-memory; these measurements do not include disk I/O or row backfills.',
  );
}

final class _MemoryLoader implements MigrationArtifactLoader {
  _MemoryLoader(this.manifest, this.chunks);

  final String manifest;
  final Map<String, String> chunks;

  @override
  Future<String> loadManifest() async => manifest;

  @override
  Future<String> loadChunk(String file) async {
    final chunk = chunks[file];
    if (chunk == null) throw StateError('Missing benchmark chunk $file.');
    return chunk;
  }
}

final class _SqliteExecutor implements DatabaseExecutor {
  _SqliteExecutor(Schema initialSchema) : database = sqlite3.openInMemory() {
    for (final table in initialSchema.tables) {
      database.execute(table.toCreateTableSql());
      for (final index in table.indexes) {
        database.execute(index.toSql(table.name));
      }
    }
    database.execute('PRAGMA user_version = ${initialSchema.version};');
  }

  final Database database;

  void close() => database.close();

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? args,
  ]) async {
    final result = database.select(sql, args ?? const []);
    return [
      for (final row in result) {for (final key in row.keys) key: row[key]},
    ];
  }

  @override
  Future<void> execute(String sql, [List<Object?>? args]) async =>
      database.execute(sql, args ?? const []);

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
