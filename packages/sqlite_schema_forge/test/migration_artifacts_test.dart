import 'package:sqlite_schema_forge/sqlite_schema_forge.dart';
import 'package:test/test.dart';

MigrationPlan _plan(int from, {bool destructive = false}) => MigrationPlan(
  fromVersion: from,
  toVersion: from + 1,
  steps: [
    if (destructive)
      PlanStep(
        type: ChangeType.rebuildTable,
        targetTable: 'users',
        sql: 'DROP TABLE users;',
        description: 'Drop obsolete users data',
        isDestructive: true,
      ),
    if (!destructive)
      PlanStep(
        type: ChangeType.addColumn,
        targetTable: 'users',
        sql: 'ALTER TABLE users ADD COLUMN name TEXT;',
        description: 'Add name',
      ),
  ],
);

void main() {
  group('MigrationArtifactBundle', () {
    test(
      'builds deterministic chunks, manifest paths, metadata and fingerprints',
      () {
        final plans = [
          for (var v = 1; v < 24; v++) _plan(v, destructive: v == 4),
        ];
        final bundle = MigrationArtifactBundle.build(
          plans: plans,
          chunkSize: 10,
          hooks: {
            (3, 4): const MigrationHookMetadata(MigrationHookPhase.beforePlan),
            (8, 9): const MigrationHookMetadata(MigrationHookPhase.afterPlan),
          },
          schemaFingerprints: {3: 'fp-3', 4: 'fp-4'},
        );

        expect(bundle.chunkFiles.keys.toList(), [
          '0002-0011.json',
          '0012-0021.json',
          '0022-0024.json',
        ]);
        expect(bundle.manifest.latestVersion, 24);
        expect(bundle.manifest.supportedStartingVersions.first, 1);
        expect(bundle.manifest.supportedStartingVersions.last, 23);
        expect(
          bundle.manifest.chunks.every(
            (chunk) => chunk.contentFingerprint != null,
          ),
          isTrue,
        );
        expect(bundle.manifest.transitions[3].destructive, isTrue);
        expect(bundle.manifest.transitions[2].fromFingerprint, 'fp-3');
        expect(bundle.manifest.transitions[2].toFingerprint, 'fp-4');
        expect(bundle.manifest.transitions[3].fromFingerprint, 'fp-4');
        expect(
          bundle.manifest.transitions[2].hookPhase,
          MigrationHookPhase.beforePlan,
        );
        expect(
          bundle.manifest.transitions[7].hookPhase,
          MigrationHookPhase.afterPlan,
        );
        expect(
          MigrationManifest.decode(bundle.manifest.encode()).toJson(),
          bundle.manifest.toJson(),
        );
        expect(
          MigrationArtifactBundle.build(
            plans: plans,
            chunkSize: 10,
            hooks: {
              (3, 4): const MigrationHookMetadata(
                MigrationHookPhase.beforePlan,
              ),
              (8, 9): const MigrationHookMetadata(MigrationHookPhase.afterPlan),
            },
            schemaFingerprints: {3: 'fp-3', 4: 'fp-4'},
          ).chunkFiles,
          bundle.chunkFiles,
        );
      },
    );

    test(
      'rejects gaps, non-adjacent plans, and hook metadata without a plan',
      () {
        expect(
          () => MigrationArtifactBundle.build(plans: [_plan(1), _plan(3)]),
          throwsArgumentError,
        );
        expect(
          () => MigrationArtifactBundle.build(
            plans: [_plan(1)],
            hooks: {
              (4, 5): const MigrationHookMetadata(
                MigrationHookPhase.beforePlan,
              ),
            },
          ),
          throwsArgumentError,
        );
      },
    );

    test('append preserves old chunks and extends supported starts', () {
      final initial = MigrationArtifactBundle.build(
        plans: [_plan(1)],
        schemaFingerprints: {1: 'fp-1', 2: 'fp-2'},
      );
      final next = MigrationArtifactBundle.append(
        existing: initial,
        plan: _plan(2, destructive: true),
        fromFingerprint: 'fp-2',
        toFingerprint: 'fp-3',
      );

      expect(next.manifest.latestVersion, 3);
      expect(next.manifest.supportedStartingVersions, [1, 2]);
      expect(
        next.manifest.transitions.map((t) => (t.fromVersion, t.toVersion)),
        [(1, 2), (2, 3)],
      );
      expect(next.manifest.transitions.last.requiresHook, isTrue);
      expect(
        next.manifest.transitions.last.hookPhase,
        MigrationHookPhase.beforePlan,
      );
      expect(
        next.chunkFiles['0002-0002.json'],
        initial.chunkFiles['0002-0002.json'],
      );
      expect(next.chunkFiles.keys, contains('0003-0003.json'));
      expect(
        next.manifest.chunks.every((chunk) => chunk.contentFingerprint != null),
        isTrue,
      );
    });

    test(
      'append rejects gaps, checkpoint mismatch, and legacy fingerprints',
      () {
        final initial = MigrationArtifactBundle.build(
          plans: [_plan(1)],
          schemaFingerprints: {2: 'fp-2'},
        );

        expect(
          () => MigrationArtifactBundle.append(
            existing: initial,
            plan: _plan(3),
            fromFingerprint: 'fp-2',
            toFingerprint: 'fp-4',
          ),
          throwsArgumentError,
        );
        expect(
          () => MigrationArtifactBundle.append(
            existing: initial,
            plan: _plan(2),
            fromFingerprint: 'wrong',
            toFingerprint: 'fp-3',
          ),
          throwsStateError,
        );

        final legacyManifest = MigrationManifest(
          latestVersion: initial.manifest.latestVersion,
          supportedStartingVersions: initial.manifest.supportedStartingVersions,
          chunks: [
            for (final chunk in initial.manifest.chunks)
              MigrationChunkRecord(
                firstTargetVersion: chunk.firstTargetVersion,
                lastTargetVersion: chunk.lastTargetVersion,
                file: chunk.file,
              ),
          ],
          transitions: initial.manifest.transitions,
        );
        final legacy = MigrationArtifactBundle.fromAssets(
          manifest: legacyManifest,
          chunkFiles: initial.chunkFiles,
        );
        final upgraded = MigrationArtifactBundle.withChunkFingerprints(legacy);
        expect(
          upgraded.manifest.chunks.every(
            (chunk) => chunk.contentFingerprint != null,
          ),
          isTrue,
        );
        expect(upgraded.chunkFiles, legacy.chunkFiles);
        expect(
          () => MigrationArtifactBundle.append(
            existing: legacy,
            plan: _plan(2),
            fromFingerprint: 'fp-2',
            toFingerprint: 'fp-3',
          ),
          throwsStateError,
        );
      },
    );

    test('bundle validation detects chunk content drift', () {
      final bundle = MigrationArtifactBundle.build(plans: [_plan(1)]);
      final name = bundle.chunkFiles.keys.single;
      final altered = bundle.chunkFiles[name]!.replaceFirst(
        'Add name',
        'Add title',
      );

      expect(
        () => MigrationArtifactBundle.fromAssets(
          manifest: bundle.manifest,
          chunkFiles: {name: altered},
        ),
        throwsFormatException,
      );
    });

    test(
      'manifest and chunk validation reject incomplete or inconsistent assets',
      () {
        final bundle = MigrationArtifactBundle.build(
          plans: [_plan(1), _plan(2)],
        );
        expect(
          () => MigrationManifest.decode(
            '{"formatVersion":1,"latestVersion":3,"supportedStartingVersions":[1,2],"chunks":[{"firstTargetVersion":3,"lastTargetVersion":3,"file":"chunk.json"}],"transitions":[{"from":1,"to":2,"destructive":false,"requiresHook":false},{"from":2,"to":3,"destructive":false,"requiresHook":false}]}',
          ),
          throwsFormatException,
        );
        expect(
          () => MigrationArtifactBundle.fromAssets(
            manifest: bundle.manifest,
            chunkFiles: const {},
          ),
          throwsFormatException,
        );
      },
    );
  });

  group('MigrationPlanChunk', () {
    test(
      'round trips plans in destination order and rejects malformed plans',
      () {
        final chunk = MigrationPlanChunk([_plan(2), _plan(1)]);
        final decoded = MigrationPlanChunk.decode(chunk.encode());
        expect(decoded.plans.map((plan) => plan.toVersion), [2, 3]);
        expect(
          () => MigrationPlanChunk.decode('{"formatVersion":2,"plans":[]}'),
          throwsFormatException,
        );
      },
    );
  });

  group('MigrationArtifactStore', () {
    test(
      'loads manifest once and only chunks intersecting the requested path',
      () async {
        final bundle = MigrationArtifactBundle.build(
          plans: [for (var v = 1; v < 24; v++) _plan(v)],
        );
        final loader = _MemoryArtifactLoader(bundle.manifest.encode(), {
          ...bundle.chunkFiles,
          'unrelated.json': 'invalid and must not be read',
        });

        final path = await MigrationArtifactStore(loader)
            .loadPath(fromVersion: 22, toVersion: 24);

        expect(path.plans.map((plan) => plan.toVersion), [23, 24]);
        expect(loader.manifestReads, 1);
        expect(loader.chunkReads, ['0022-0024.json']);
      },
    );

    test('loads multiple relevant chunks and excludes transitions outside the path', () async {
      final bundle = MigrationArtifactBundle.build(
        plans: [for (var v = 1; v < 24; v++) _plan(v)],
      );
      final loader = _MemoryArtifactLoader(
        bundle.manifest.encode(),
        bundle.chunkFiles,
      );

      final path = await MigrationArtifactStore(loader)
          .loadPath(fromVersion: 10, toVersion: 13);

      expect(path.plans.map((plan) => (plan.fromVersion, plan.toVersion)), [
        (10, 11),
        (11, 12),
        (12, 13),
      ]);
      expect(loader.chunkReads, ['0002-0011.json', '0012-0021.json']);
    });

    test('fails closed for reverse, unsupported, incomplete, or missing relevant history', () async {
      final bundle = MigrationArtifactBundle.build(
        plans: [for (var v = 1; v < 5; v++) _plan(v)],
      );
      final loader = _MemoryArtifactLoader(
        bundle.manifest.encode(),
        bundle.chunkFiles,
      );
      final store = MigrationArtifactStore(loader);

      await expectLater(
        store.loadPath(fromVersion: 4, toVersion: 3),
        throwsArgumentError,
      );
      await expectLater(
        store.loadPath(fromVersion: 0, toVersion: 3),
        throwsFormatException,
      );
      await expectLater(
        MigrationArtifactStore(
          _MemoryArtifactLoader(bundle.manifest.encode(), const {}),
        ).loadPath(fromVersion: 2, toVersion: 3),
        throwsFormatException,
      );
    });

    test(
      'runtime loading rejects a chunk whose content fingerprint changed',
      () async {
        final bundle = MigrationArtifactBundle.build(plans: [_plan(1)]);
        final name = bundle.chunkFiles.keys.single;
        final altered = bundle.chunkFiles[name]!.replaceFirst(
          'Add name',
          'Add title',
        );
        final store = MigrationArtifactStore(
          _MemoryArtifactLoader(bundle.manifest.encode(), {name: altered}),
        );

        await expectLater(
          store.loadPath(fromVersion: 1, toVersion: 2),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('fingerprint mismatch'),
            ),
          ),
        );
      },
    );

    test('precomputed migration validates hooks then executes plans at declared boundaries', () async {
      final target = Schema(
        version: 3,
        tables: [
          Table('users', [Column.id()]),
        ],
      );
      final bundle = MigrationArtifactBundle.build(
        plans: [
          MigrationPlan(
            fromVersion: 1,
            toVersion: 2,
            steps: const [
              PlanStep(
                type: ChangeType.addColumn,
                targetTable: 'users',
                sql: 'ALTER TABLE users ADD COLUMN name TEXT;',
                description: 'Add name',
              ),
            ],
          ),
          MigrationPlan(
            fromVersion: 2,
            toVersion: 3,
            steps: const [
              PlanStep(
                type: ChangeType.rebuildTable,
                targetTable: 'users',
                sql: 'DROP TABLE old_users;',
                description: 'Drop old users',
                isDestructive: true,
              ),
            ],
          ),
        ],
        hooks: {
          (1, 2): const MigrationHookMetadata(MigrationHookPhase.beforePlan),
        },
        schemaFingerprints: {3: SchemaSnapshot.fingerprint(target)},
      );
      final db = _MigrationExecutor(1);
      final hookCalls = <String>[];

      final result = await SqliteSchemaForge.migrateWithUpgrades(
        db: db,
        targetSchema: target,
        migrationHistory: MigrationArtifactStore(
          _MemoryArtifactLoader(bundle.manifest.encode(), bundle.chunkFiles),
        ),
        upgrades: [
          Upgrade.from(1).to(
            2,
            MigrationHook((txn, from, to) async {
              hookCalls.add('$from->$to');
              (txn as _MigrationExecutor).events.add('hook:$from->$to');
            }),
          ),
          Upgrade.from(2).to(3, MigrationHook.noop()),
        ],
      );

      expect(hookCalls, ['1->2']);
      expect(db.events, [
        'hook:1->2',
        'sql:ALTER TABLE users ADD COLUMN name TEXT;',
        'version:2',
        'sql:DROP TABLE old_users;',
        'version:3',
      ]);
      expect(db.version, 3);
      expect(result.migrated, isTrue);
    });

    test('precomputed mode rejects missing hooks and target fingerprint mismatch before transaction', () async {
      final target = Schema(
        version: 2,
        tables: [
          Table('users', [Column.id()]),
        ],
      );
      final bundle = MigrationArtifactBundle.build(
        plans: [_plan(1, destructive: true)],
        schemaFingerprints: {2: 'wrong-fingerprint'},
      );
      final db = _MigrationExecutor(1);
      final store = MigrationArtifactStore(
        _MemoryArtifactLoader(bundle.manifest.encode(), bundle.chunkFiles),
      );

      await expectLater(
        SqliteSchemaForge.migrateWithUpgrades(
          db: db,
          targetSchema: target,
          migrationHistory: store,
          upgrades: [Upgrade.from(1).to(2, MigrationHook.noop())],
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('fingerprint mismatch'),
          ),
        ),
      );
      expect(db.transactionCount, 0);
      expect(db.events, isEmpty);

      final matching = MigrationArtifactBundle.build(
        plans: [_plan(1, destructive: true)],
        schemaFingerprints: {2: SchemaSnapshot.fingerprint(target)},
      );
      await expectLater(
        SqliteSchemaForge.migrateWithUpgrades(
          db: db,
          targetSchema: target,
          migrationHistory: MigrationArtifactStore(
            _MemoryArtifactLoader(
              matching.manifest.encode(),
              matching.chunkFiles,
            ),
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('requires a hook'),
          ),
        ),
      );
      expect(db.transactionCount, 0);
      expect(db.events, isEmpty);
    });

    test(
      'already-current precomputed migrations do not load artifacts',
      () async {
        final db = _MigrationExecutor(2);
        final loader = _MemoryArtifactLoader('invalid', const {});

        final result = await SqliteSchemaForge.migrateWithUpgrades(
          db: db,
          targetSchema: Schema(version: 2, tables: const []),
          migrationHistory: MigrationArtifactStore(loader),
        );

        expect(result.migrated, isFalse);
        expect(loader.manifestReads, 0);
        expect(db.transactionCount, 0);
      },
    );

    test(
      'explicit precomputed history rejects downgrade without loading assets',
      () async {
        final db = _MigrationExecutor(3);
        final loader = _MemoryArtifactLoader('invalid', const {});

        await expectLater(
          SqliteSchemaForge.migrateWithUpgrades(
            db: db,
            targetSchema: Schema(version: 2, tables: const []),
            migrationHistory: MigrationArtifactStore(loader),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('forward-only'),
            ),
          ),
        );
        expect(loader.manifestReads, 0);
        expect(db.transactionCount, 0);
      },
    );

    test(
      'fresh database creates target directly and bypasses hooks and history',
      () async {
        final target = Schema(
          version: 3,
          tables: [
            Table('users', [Column.id(), Column.text('name')]),
          ],
        );
        final loader = _MemoryArtifactLoader('invalid', const {});
        final db = _MigrationExecutor(0);
        var hookCalls = 0;

        final result = await SqliteSchemaForge.migrateWithUpgrades(
          db: db,
          targetSchema: target,
          migrationHistory: MigrationArtifactStore(loader),
          upgrades: [
            Upgrade.from(1)
                .to(2, MigrationHook((_, _, _) async => hookCalls++)),
            Upgrade.from(2).to(3, MigrationHook.noop()),
          ],
        );

        expect(loader.manifestReads, 0);
        expect(hookCalls, 0);
        expect(
          db.events,
          contains('sql:${target.tables.single.toCreateTableSql()}'),
        );
        expect(db.version, 3);
        expect(result.migrated, isTrue);
      },
    );

    test('unversioned database with existing tables is not fresh', () async {
      final db = _MigrationExecutor(0)
        ..catalogObjects.add('legacy_users')
        ..catalogColumns['legacy_users'] = {'id', 'old'};
      final target = Schema(
        version: 2,
        tables: [
          Table('legacy_users', [Column.id()]),
        ],
      );

      await SqliteSchemaForge.migrateWithUpgrades(
        db: db,
        targetSchema: target,
        upgrades: [Upgrade.from(0).to(2, MigrationHook.noop())],
      );

      expect(
        db.events.any((event) => event.contains('DROP TABLE legacy_users;')),
        isTrue,
      );
      expect(db.version, 2);
    });

    test(
      'failed post-plan hook rolls back plan SQL and version updates',
      () async {
        final target = Schema(
          version: 2,
          tables: [
            Table('users', [Column.id()]),
          ],
        );
        final bundle = MigrationArtifactBundle.build(
          plans: [_plan(1)],
          hooks: {
            (1, 2): const MigrationHookMetadata(MigrationHookPhase.afterPlan),
          },
          schemaFingerprints: {2: SchemaSnapshot.fingerprint(target)},
        );
        final db = _MigrationExecutor(1);

        await expectLater(
          SqliteSchemaForge.migrateWithUpgrades(
            db: db,
            targetSchema: target,
            migrationHistory: MigrationArtifactStore(
              _MemoryArtifactLoader(
                bundle.manifest.encode(),
                bundle.chunkFiles,
              ),
            ),
            upgrades: [
              Upgrade.from(1).to(
                2,
                MigrationHook((_, _, _) async {
                  throw StateError('hook failed');
                }),
              ),
            ],
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'hook failed',
            ),
          ),
        );
        expect(db.version, 1);
        expect(db.events, isEmpty);
        expect(db.transactionCount, 1);
      },
    );

    test('runtime hook failure rolls back DDL and schema version', () async {
      final db = _MigrationExecutor(1)
        ..catalogObjects.add('users')
        ..catalogColumns['users'] = {'id'};

      await expectLater(
        SqliteSchemaForge.migrateWithUpgrades(
          db: db,
          targetSchema: Schema(
            version: 2,
            tables: [
              Table('users', [Column.id(), Column.text('name')]),
            ],
          ),
          upgrades: [
            Upgrade.from(1).to(
              2,
              MigrationHook((_, _, _) async {
                throw StateError('runtime hook failed');
              }),
            ),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'runtime hook failed',
          ),
        ),
      );

      expect(db.version, 1);
      expect(db.events, isEmpty);
      expect(db.transactionCount, 1);
    });
  });
}

final class _MemoryArtifactLoader implements MigrationArtifactLoader {
  _MemoryArtifactLoader(this.manifest, this.chunks);

  final String manifest;
  final Map<String, String> chunks;
  int manifestReads = 0;
  final List<String> chunkReads = [];

  @override
  Future<String> loadManifest() async {
    manifestReads++;
    return manifest;
  }

  @override
  Future<String> loadChunk(String file) async {
    chunkReads.add(file);
    final contents = chunks[file];
    if (contents == null) throw StateError('Missing asset: $file');
    return contents;
  }
}

final class _MigrationExecutor implements DatabaseExecutor {
  _MigrationExecutor(this.version);

  int version;
  int transactionCount = 0;
  final List<String> events = [];
  final List<String> catalogObjects = [];
  final Map<String, Set<String>> catalogColumns = {};

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? args,
  ]) async {
    if (sql == 'PRAGMA user_version;') {
      return [
        {'user_version': version},
      ];
    }
    if (sql == 'PRAGMA foreign_keys;') {
      return [
        {'foreign_keys': 1},
      ];
    }
    if (sql.contains('sqlite_master')) {
      return [
        for (final name in catalogObjects) {'name': name},
      ];
    }
    if (sql.startsWith('PRAGMA table_info(')) {
      final name = sql.substring(19, sql.length - 2);
      return [
        for (final column in catalogColumns[name] ?? {}) {'name': column},
      ];
    }
    if (sql.startsWith('PRAGMA index_list(')) return [];
    throw UnsupportedError('Unexpected read query: $sql');
  }

  @override
  Future<void> execute(String sql, [List<Object?>? args]) async {
    if (sql.startsWith('PRAGMA user_version = ')) {
      version = int.parse(RegExp(r'\d+').firstMatch(sql)!.group(0)!);
      events.add('version:$version');
    } else {
      events.add('sql:$sql');
    }
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(DatabaseExecutor txn) action,
  ) async {
    transactionCount++;
    final previousVersion = version;
    final previousEvents = [...events];
    try {
      return await action(this);
    } catch (_) {
      version = previousVersion;
      events
        ..clear()
        ..addAll(previousEvents);
      rethrow;
    }
  }
}
