import 'package:sqlite_schema_forge/sqlite_schema_forge.dart';
import 'package:test/test.dart';

void main() {
  group('MigrationPlanSnapshot', () {
    test('round trips ordered plan steps and metadata', () {
      const plan = MigrationPlan(
        fromVersion: 4,
        toVersion: 5,
        steps: [
          PlanStep(
            type: ChangeType.rebuildTable,
            targetTable: 'users',
            sql: 'CREATE TEMP;\nDROP OLD;',
            description: 'Rebuild users',
            isDestructive: true,
          ),
          PlanStep(
            type: ChangeType.createIndex,
            targetTable: 'users',
            sql: 'CREATE INDEX ix;',
            description: 'Create index',
          ),
        ],
      );

      final decoded = MigrationPlanSnapshot.decode(
        MigrationPlanSnapshot.encode(plan),
      );
      expect(
        MigrationPlanSnapshot.toJson(decoded),
        MigrationPlanSnapshot.toJson(plan),
      );
      expect(decoded.hasDestructiveChanges, isTrue);
    });

    test('rejects unsupported and malformed serialized plans', () {
      expect(
        () => MigrationPlanSnapshot.decode('{"formatVersion":2}'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Unsupported migration plan formatVersion'),
          ),
        ),
      );
      expect(
        () => MigrationPlanSnapshot.decode(
          '{"formatVersion":1,"fromVersion":1,"toVersion":2,"steps":[{"type":"unknown"}]}',
        ),
        throwsFormatException,
      );
    });
  });

  group('MigrationPlanCompiler', () {
    test(
      'uses the existing planner to compile adjacent structural changes',
      () async {
        final previous = Schema(
          version: 3,
          tables: [
            Table('users', [Column.id(), Column.text('legacy')]),
            Table('teams', [Column.id()]),
          ],
        );
        final current = Schema(
          version: 4,
          tables: [
            Table('users', [Column.id(), Column.text('name')]),
            Table('teams', [Column.id(), Column.text('label')]),
          ],
        );

        final plan = await MigrationPlanCompiler.compile(
          previous: previous,
          current: current,
        );

        expect((plan.fromVersion, plan.toVersion), (3, 4));
        expect(plan.steps.map((step) => step.type), [
          ChangeType.rebuildTable,
          ChangeType.addColumn,
        ]);
        expect(plan.steps.first.isDestructive, isTrue);
        expect(plan.steps.first.sql, contains('DROP TABLE users;'));
      },
    );

    test('requires adjacent schema versions', () async {
      await expectLater(
        MigrationPlanCompiler.compile(
          previous: Schema(version: 1, tables: const []),
          current: Schema(version: 3, tables: const []),
        ),
        throwsArgumentError,
      );
    });
  });
}
