import 'package:sqlite_schema_forge/sqlite_schema_forge.dart';

/// First released schema in the end-to-end precomputed history example.
final schemaV1 = Schema(
  version: 1,
  tables: [
    Table('users', [Column.id(), Column.text('name', nullable: false)]),
  ],
);

/// Current schema. `normalized_name` is added by the compiled plan and then
/// backfilled by the transition's `afterPlan` hook.
final schemaV2 = Schema(
  version: 2,
  tables: [
    Table('users', [
      Column.id(),
      Column.text('name', nullable: false),
      Column.text('normalized_name'),
    ]),
  ],
);
