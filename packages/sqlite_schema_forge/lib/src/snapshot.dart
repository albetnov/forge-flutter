import 'dart:convert';

import 'schema.dart';

/// Stable JSON representation of a [Schema] for development-time history.
///
/// This format is structural metadata, not generated Dart or executable SQL.
/// The format version is independent of [Schema.version].
final class SchemaSnapshot {
  /// Current independently versioned snapshot format.
  static const formatVersion = 1;

  const SchemaSnapshot._();

  /// Returns a canonical, human-readable JSON document for [schema].
  static String encode(Schema schema) =>
      const JsonEncoder.withIndent('  ').convert(toJson(schema));

  /// Stable non-cryptographic fingerprint for schema identity checks.
  ///
  /// This detects stale or mismatched artifacts; it is not an authenticity
  /// signature. The canonical snapshot JSON is the hash input.
  static String fingerprint(Schema schema) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(
      const JsonEncoder().convert(toJson(schema)),
    )) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    return 'fnv1a64:${hash.toRadixString(16).padLeft(16, '0')}';
  }

  /// Returns the canonical JSON-compatible representation of [schema].
  static Map<String, Object?> toJson(Schema schema) => {
    'formatVersion': formatVersion,
    'schemaVersion': schema.version,
    'tables': [
      for (final table in [...schema.tables]..sort(_byName))
        {
          'name': table.name,
          // Column order is structural: it affects CREATE TABLE and rebuilds.
          'columns': [
            for (final column in table.columns) _columnToJson(column),
          ],
          'indexes': [
            for (final index
                in [...table.indexes]..sort(
                  (a, b) => a
                      .resolvedName(table.name)
                      .compareTo(b.resolvedName(table.name)),
                ))
              {
                'name': index.name,
                'columns': index.columns,
                'unique': index.unique,
              },
          ],
        },
    ],
    'virtualTables': [
      for (final table in [...schema.virtualTables]..sort(_byName))
        {
          'name': table.name,
          'module': table.module,
          'columns': table.columns,
          'contentTable': table.contentTable,
          'contentRowId': table.contentRowId,
        },
    ],
    'triggers': [
      for (final trigger in [...schema.triggers]..sort(_byName))
        {
          'name': trigger.name,
          'timing': trigger.timing.name,
          'event': trigger.event.name,
          'targetTable': trigger.targetTable,
          'body': trigger.body,
        },
    ],
  };

  /// Decodes a snapshot, rejecting unknown formats and malformed structures.
  static Schema decode(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw FormatException('Invalid schema snapshot JSON: ${error.message}');
    }
    final root = _map(decoded, 'snapshot');
    final version = _int(root['formatVersion'], 'formatVersion');
    if (version != formatVersion) {
      throw FormatException(
        'Unsupported schema snapshot formatVersion $version; '
        'supported version is $formatVersion.',
      );
    }
    return Schema(
      version: _int(root['schemaVersion'], 'schemaVersion'),
      tables: _list(root['tables'], 'tables').map(_tableFromJson).toList(),
      virtualTables: _list(
        root['virtualTables'],
        'virtualTables',
      ).map(_virtualTableFromJson).toList(),
      triggers: _list(
        root['triggers'],
        'triggers',
      ).map(_triggerFromJson).toList(),
    );
  }

  static int _byName(Object a, Object b) => _nameOf(a).compareTo(_nameOf(b));

  static String _nameOf(Object value) => switch (value) {
    Table item => item.name,
    VirtualTable item => item.name,
    Trigger item => item.name,
    _ => throw ArgumentError.value(value, 'value', 'Unsupported schema entity'),
  };

  static Map<String, Object?> _columnToJson(Column column) => {
    'name': column.name,
    'type': column.type.name,
    'primaryKey': column.primaryKey,
    'autoIncrement': column.autoIncrement,
    'nullable': column.nullable,
    'unique': column.unique,
    'defaultValue': _defaultToJson(column.defaultValue),
    'referencesTable': column.referencesTable,
    'referencesColumn': column.referencesColumn,
  };

  static Object? _defaultToJson(Object? value) {
    if (value is RawSql) return {'kind': 'rawSql', 'value': value.expression};
    if (value == null ||
        value is String ||
        value is int ||
        value is double ||
        value is bool) {
      return value;
    }
    throw ArgumentError.value(
      value,
      'defaultValue',
      'Unsupported snapshot value',
    );
  }

  static Object? _defaultFromJson(Object? value, String path) {
    if (value is Map) {
      final map = _map(value, path);
      if (map.keys.toSet().difference({'kind', 'value'}).isNotEmpty ||
          map['kind'] != 'rawSql' ||
          map['value'] is! String) {
        throw FormatException('$path must be a valid rawSql value.');
      }
      return RawSql(map['value'] as String);
    }
    if (value == null ||
        value is String ||
        value is int ||
        value is double ||
        value is bool) {
      return value;
    }
    throw FormatException('$path has an unsupported value.');
  }

  static Table _tableFromJson(Object? value) {
    final map = _map(value, 'table');
    return Table(
      _string(map['name'], 'table.name'),
      _list(map['columns'], 'table.columns').asMap().entries.map((entry) {
        final path = 'table.columns[${entry.key}]';
        final c = _map(entry.value, path);
        return Column(
          name: _string(c['name'], '$path.name'),
          type: _enum(DataType.values, c['type'], '$path.type'),
          primaryKey: _bool(c['primaryKey'], '$path.primaryKey'),
          autoIncrement: _bool(c['autoIncrement'], '$path.autoIncrement'),
          nullable: _bool(c['nullable'], '$path.nullable'),
          unique: _bool(c['unique'], '$path.unique'),
          defaultValue: _defaultFromJson(
            c['defaultValue'],
            '$path.defaultValue',
          ),
          referencesTable: _nullableString(
            c['referencesTable'],
            '$path.referencesTable',
          ),
          referencesColumn: _nullableString(
            c['referencesColumn'],
            '$path.referencesColumn',
          ),
        );
      }).toList(),
      indexes: _list(map['indexes'], 'table.indexes').map((value) {
        final i = _map(value, 'table.index');
        return Index(
          name: _nullableString(i['name'], 'index.name'),
          columns: _strings(i['columns'], 'index.columns'),
          unique: _bool(i['unique'], 'index.unique'),
        );
      }).toList(),
    );
  }

  static VirtualTable _virtualTableFromJson(Object? value) {
    final m = _map(value, 'virtualTable');
    final module = _string(m['module'], 'virtualTable.module');
    if (module != 'fts5') {
      throw FormatException('Unsupported virtual table module "$module".');
    }
    return VirtualTable.fts5(
      _string(m['name'], 'virtualTable.name'),
      columns: _strings(m['columns'], 'virtualTable.columns'),
      contentTable: _nullableString(
        m['contentTable'],
        'virtualTable.contentTable',
      ),
      contentRowId: _nullableString(
        m['contentRowId'],
        'virtualTable.contentRowId',
      ),
    );
  }

  static Trigger _triggerFromJson(Object? value) {
    final m = _map(value, 'trigger');
    return Trigger(
      name: _string(m['name'], 'trigger.name'),
      timing: _enum(TriggerTiming.values, m['timing'], 'trigger.timing'),
      event: _enum(TriggerEvent.values, m['event'], 'trigger.event'),
      targetTable: _string(m['targetTable'], 'trigger.targetTable'),
      body: _string(m['body'], 'trigger.body'),
    );
  }

  static Map<String, Object?> _map(Object? value, String path) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw FormatException('$path must be a JSON object with string keys.');
    }
    return value.cast<String, Object?>();
  }

  static List<Object?> _list(Object? value, String path) => value is List
      ? value.cast<Object?>()
      : throw FormatException('$path must be a JSON array.');

  static List<String> _strings(Object? value, String path) => _list(value, path)
      .asMap()
      .entries
      .map((entry) => _string(entry.value, '$path[${entry.key}]'))
      .toList();

  static String _string(Object? value, String path) => value is String
      ? value
      : throw FormatException('$path must be a string.');

  static String? _nullableString(Object? value, String path) =>
      value == null ? null : _string(value, path);

  static int _int(Object? value, String path) =>
      value is int ? value : throw FormatException('$path must be an integer.');

  static bool _bool(Object? value, String path) =>
      value is bool ? value : throw FormatException('$path must be a boolean.');

  static T _enum<T extends Enum>(List<T> values, Object? value, String path) {
    if (value is String) {
      for (final item in values) {
        if (item.name == value) return item;
      }
    }
    throw FormatException('$path has an unknown value "$value".');
  }
}
