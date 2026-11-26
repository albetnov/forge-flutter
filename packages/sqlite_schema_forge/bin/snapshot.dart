import 'dart:convert';
import 'dart:io';

import 'package:sqlite_schema_forge/sqlite_schema_forge.dart';

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.isEmpty ||
        arguments.first == '--help' ||
        arguments.first == '-h') {
      _usage();
      return;
    }
    final options = _parse(arguments.skip(1).toList());
    switch (arguments.first) {
      case 'capture':
        await _capture(options);
        break;
      case 'compile':
        await _compile(options);
        break;
      case 'verify':
        await _verify(options);
        break;
      default:
        throw FormatException('Unknown command "${arguments.first}".');
    }
  } catch (error) {
    stderr.writeln('sqlite_schema_forge:snapshot: $error');
    exitCode = 1;
  }
}

void _usage() {
  stdout.writeln('''
SQLite Schema Forge JSON history tool

Commands:
  capture --entry <dart-file> --out <snapshot.json>
  compile --snapshots <directory> --out <new-migrations-directory> [--hook from:to:beforePlan|afterPlan] [--hooks-file hooks.json]
  verify --snapshots <directory> --migrations <directory> [--hook from:to:beforePlan|afterPlan] [--hooks-file hooks.json]

Schema entry points run on the host and must print only SchemaSnapshot JSON to
stdout. Capture refuses to overwrite a conflicting snapshot. Compile writes a
complete artifact set only into a new or empty directory. Verify never writes.
''');
}

Map<String, List<String>> _parse(List<String> args) {
  final values = <String, List<String>>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      throw FormatException('Unexpected argument "$arg".');
    }
    final key = arg.substring(2);
    if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
      throw FormatException('Missing value for --$key.');
    }
    values.putIfAbsent(key, () => []).add(args[++i]);
  }
  return values;
}

String _one(Map<String, List<String>> options, String key) {
  final values = options[key];
  if (values == null || values.length != 1) {
    throw FormatException('Provide --$key exactly once.');
  }
  return values.single;
}

Future<Map<(int, int), MigrationHookMetadata>> _hooks(
  Map<String, List<String>> options,
) async {
  final hooks = <(int, int), MigrationHookMetadata>{};
  void add(int from, int to, String phaseName) {
    final phases = MigrationHookPhase.values.where(
      (value) => value.name == phaseName,
    );
    if (phases.length != 1) {
      throw FormatException('Unknown hook phase "$phaseName".');
    }
    final range = (from, to);
    if (hooks.containsKey(range)) {
      throw FormatException('Duplicate hook metadata for $from->$to.');
    }
    hooks[range] = MigrationHookMetadata(phases.single);
  }

  for (final spec in options['hook'] ?? const <String>[]) {
    final parts = spec.split(':');
    if (parts.length != 3) {
      throw FormatException(
        'Invalid --hook "$spec"; expected from:to:beforePlan|afterPlan.',
      );
    }
    add(int.parse(parts[0]), int.parse(parts[1]), parts[2]);
  }
  final hooksFilePath = options['hooks-file'];
  if (hooksFilePath != null) {
    if (hooksFilePath.length != 1) {
      throw FormatException('Provide --hooks-file at most once.');
    }
    final Object? decoded = jsonDecode(
      await File(hooksFilePath.single).readAsString(),
    );
    if (decoded is! List) {
      throw FormatException('Hook metadata file must contain a JSON array.');
    }
    for (var i = 0; i < decoded.length; i++) {
      final item = decoded[i];
      if (item is! Map ||
          item['from'] is! int ||
          item['to'] is! int ||
          item['phase'] is! String) {
        throw FormatException(
          'Hook metadata entry $i must contain integer from/to and string phase.',
        );
      }
      add(item['from'] as int, item['to'] as int, item['phase'] as String);
    }
  }
  return hooks;
}

Future<void> _capture(Map<String, List<String>> options) async {
  final entry = _one(options, 'entry');
  final output = File(_one(options, 'out'));
  final result = await Process.run(Platform.resolvedExecutable, [
    'run',
    entry,
  ], workingDirectory: Directory.current.path);
  if (result.exitCode != 0) {
    throw StateError(
      'Schema entry point failed (${result.exitCode}): ${result.stderr}',
    );
  }
  final schema = SchemaSnapshot.decode(result.stdout as String);
  final content = '${SchemaSnapshot.encode(schema)}\n';
  if (await output.exists()) {
    final existing = SchemaSnapshot.decode(await output.readAsString());
    if (SchemaSnapshot.encode(existing) != SchemaSnapshot.encode(schema)) {
      throw StateError(
        'Refusing to overwrite conflicting snapshot ${output.path}; released versions are immutable.',
      );
    }
    stdout.writeln('Snapshot ${schema.version} is unchanged: ${output.path}');
    return;
  }
  await output.parent.create(recursive: true);
  final temp = File('${output.path}.tmp');
  await temp.writeAsString(content, flush: true);
  await temp.rename(output.path);
  stdout.writeln('Captured schema version ${schema.version}: ${output.path}');
}

Future<List<Schema>> _readSnapshots(Directory directory) async {
  if (!await directory.exists()) {
    throw StateError('Snapshot directory does not exist: ${directory.path}');
  }
  final files = <(int, File)>[];
  await for (final entity in directory.list()) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.last;
    final match = RegExp(r'^(\d+)\.json$').firstMatch(name);
    if (match == null) {
      throw FormatException('Unexpected snapshot file "$name".');
    }
    files.add((int.parse(match.group(1)!), entity));
  }
  files.sort((a, b) => a.$1.compareTo(b.$1));
  if (files.isEmpty) {
    throw StateError('No versioned JSON snapshots found in ${directory.path}.');
  }
  final versions = <int>{};
  final schemas = <Schema>[];
  for (final (filenameVersion, file) in files) {
    if (!versions.add(filenameVersion)) {
      throw FormatException('Duplicate snapshot version $filenameVersion.');
    }
    final source = await file.readAsString();
    final schema = SchemaSnapshot.decode(source);
    if (schema.version != filenameVersion) {
      throw FormatException(
        '${file.path} declares schema version ${schema.version}, expected $filenameVersion.',
      );
    }
    if (source.trimRight() != SchemaSnapshot.encode(schema)) {
      throw FormatException(
        '${file.path} is not in canonical snapshot format.',
      );
    }
    schemas.add(schema);
  }
  return schemas;
}

Future<MigrationArtifactBundle> _buildBundle(
  List<Schema> schemas,
  Map<(int, int), MigrationHookMetadata> hooks,
) async {
  final plans = <MigrationPlan>[];
  for (var i = 1; i < schemas.length; i++) {
    plans.add(
      await MigrationPlanCompiler.compile(
        previous: schemas[i - 1],
        current: schemas[i],
      ),
    );
  }
  if (plans.isEmpty) {
    throw StateError(
      'At least two adjacent snapshots are required to compile history.',
    );
  }
  return MigrationArtifactBundle.build(
    plans: plans,
    hooks: hooks,
    schemaFingerprints: {
      for (final schema in schemas)
        schema.version: SchemaSnapshot.fingerprint(schema),
    },
  );
}

Future<void> _compile(Map<String, List<String>> options) async {
  final schemas = await _readSnapshots(Directory(_one(options, 'snapshots')));
  final bundle = await _buildBundle(schemas, await _hooks(options));
  final output = Directory(_one(options, 'out'));
  if (await output.exists() && !await output.list().isEmpty) {
    throw StateError(
      'Refusing to overwrite a non-empty artifact directory: ${output.path}',
    );
  }
  await output.create(recursive: true);
  final stage = await output.parent.createTemp('.sqlite-schema-forge-stage-');
  try {
    await File('${stage.path}/manifest.json')
        .writeAsString('${bundle.manifest.encode()}\n');
    for (final item in bundle.chunkFiles.entries) {
      await File('${stage.path}/${item.key}').writeAsString('${item.value}\n');
    }
    await for (final file in stage.list()) {
      await file.rename('${output.path}/${file.uri.pathSegments.last}');
    }
  } catch (_) {
    if (await output.exists()) await output.delete(recursive: true);
    rethrow;
  } finally {
    if (await stage.exists()) await stage.delete(recursive: true);
  }
  stdout.writeln(
    'Compiled ${bundle.manifest.transitions.length} transitions into ${bundle.chunkFiles.length} chunks at ${output.path}',
  );
}

Future<void> _verify(Map<String, List<String>> options) async {
  final schemas = await _readSnapshots(Directory(_one(options, 'snapshots')));
  final migrationDir = Directory(_one(options, 'migrations'));
  final manifestFile = File('${migrationDir.path}/manifest.json');
  if (!await manifestFile.exists()) {
    throw StateError('Missing ${manifestFile.path}.');
  }
  final manifest = MigrationManifest.decode(await manifestFile.readAsString());
  final expected = await _buildBundle(schemas, await _hooks(options));
  if (expected.manifest.encode() != manifest.encode()) {
    throw StateError(
      'Migration manifest is stale or differs from snapshots and hook declarations.',
    );
  }
  final actualFiles = <String>{};
  await for (final entity in migrationDir.list()) {
    if (entity is! File) {
      throw StateError(
        'Unexpected directory in migration artifacts: ${entity.path}',
      );
    }
    final name = entity.uri.pathSegments.last;
    if (name != 'manifest.json') {
      actualFiles.add(name);
    }
  }
  if (actualFiles.length != expected.chunkFiles.length ||
      !actualFiles.containsAll(expected.chunkFiles.keys)) {
    throw StateError('Migration chunk file set is stale or incomplete.');
  }
  for (final item in expected.chunkFiles.entries) {
    if (await File('${migrationDir.path}/${item.key}').readAsString() !=
        '${item.value}\n') {
      throw StateError(
        'Migration chunk ${item.key} is stale or incompatible with snapshots.',
      );
    }
  }
  stdout.writeln(
    'Verified ${schemas.length} snapshots and ${manifest.transitions.length} migration transitions.',
  );
}
