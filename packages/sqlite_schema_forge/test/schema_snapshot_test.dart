import 'package:sqlite_schema_forge/sqlite_schema_forge.dart';
import 'package:test/test.dart';

void main() {
  group('SchemaSnapshot', () {
    final schema = Schema(
      version: 7,
      tables: [
        Table(
          'users',
          [
            Column.id(),
            Column.text('nickname', defaultValue: 'anon'),
            Column.datetime('created', defaultValue: RawSql.currentTimestamp),
            Column.integer('team_id', refTable: 'teams', refCol: 'id'),
          ],
          indexes: [
            Index(columns: ['team_id']),
            Index(
              name: 'users_nickname_uq',
              columns: ['nickname'],
              unique: true,
            ),
          ],
        ),
        Table('teams', [Column.id(), Column.text('name', nullable: false)]),
      ],
      virtualTables: [
        VirtualTable.fts5(
          'users_fts',
          columns: ['nickname'],
          contentTable: 'users',
        ),
      ],
      triggers: [
        Trigger(
          name: 'users_update',
          timing: TriggerTiming.after,
          event: TriggerEvent.update,
          targetTable: 'users',
          body: 'UPDATE teams SET name = new.nickname WHERE id = new.team_id;',
        ),
      ],
    );

    test('round trips every currently supported structural property', () {
      final restored = SchemaSnapshot.decode(SchemaSnapshot.encode(schema));
      expect(SchemaSnapshot.toJson(restored), SchemaSnapshot.toJson(schema));
    });

    test('serialization is canonical across entity declaration order', () {
      final reordered = Schema(
        version: schema.version,
        tables: schema.tables.reversed.toList(),
        virtualTables: schema.virtualTables,
        triggers: schema.triggers,
      );
      expect(SchemaSnapshot.encode(reordered), SchemaSnapshot.encode(schema));
    });

    test(
      'format version is distinct and unsupported versions are rejected',
      () {
        expect(SchemaSnapshot.toJson(schema)['formatVersion'], 1);
        expect(
          () => SchemaSnapshot.decode('{"formatVersion":99}'),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('Unsupported schema snapshot formatVersion 99'),
            ),
          ),
        );
      },
    );

    test('malformed structure and unsupported defaults fail clearly', () {
      expect(
        () =>
            SchemaSnapshot.decode('{"formatVersion":1,"schemaVersion":"one"}'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('schemaVersion must be an integer'),
          ),
        ),
      );
      expect(
        () => SchemaSnapshot.encode(
          Schema(
            version: 1,
            tables: [
              Table('t', [
                Column(name: 'c', type: DataType.text, defaultValue: Object()),
              ]),
            ],
          ),
        ),
        throwsArgumentError,
      );
    });
  });
}
