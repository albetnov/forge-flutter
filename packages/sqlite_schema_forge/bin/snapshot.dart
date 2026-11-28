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
        if (options.containsKey('checkpoints')) {
          await _verifyIncremental(options);
        } else {
          await _verify(options);
        }
        break;
      case 'compact':
        await _compact(options);
        break;
      case 'advance':
        await _advance(options);
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
  compact --snapshots <full-history> --migrations <directory> --out <checkpoint-directory> [--hook ...] [--hooks-file hooks.json]
  advance --entry <next-schema.dart> --checkpoints <directory> --migrations <directory> [--hook ...] [--hooks-file hooks.json]
  verify --checkpoints <rolling-pair> --migrations <directory>

Schema entry points run on the host and must print only SchemaSnapshot JSON to
stdout. Capture refuses to overwrite a conflicting snapshot. Compile writes a
complete artifact set only into a new or empty directory. Compact validates
full history before keeping its latest two checkpoints. Advance appends one
transition without rewriting prior chunks. Verify never writes.
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
  final schema = await _runEntry(entry);
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

Future<Schema> _runEntry(String entry) async {
  final result = await Process.run(Platform.resolvedExecutable, [
    'run',
    entry,
  ], workingDirectory: Directory.current.path);
  if (result.exitCode != 0) {
    throw StateError(
      'Schema entry point failed (${result.exitCode}): ${result.stderr}',
    );
  }
  return SchemaSnapshot.decode(result.stdout as String);
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
  final manifest = await _verifyFullArtifacts(
    schemas: schemas,
    migrationDir: migrationDir,
    hooks: await _hooks(options),
  );
  stdout.writeln(
    'Verified ${schemas.length} snapshots and ${manifest.transitions.length} migration transitions.',
  );
}

Future<MigrationManifest> _verifyFullArtifacts({
  required List<Schema> schemas,
  required Directory migrationDir,
  required Map<(int, int), MigrationHookMetadata> hooks,
}) async {
  final actual = await _readArtifactBundle(migrationDir);
  final expected = await _buildBundle(schemas, hooks);
  if (_manifestWithoutChunkFingerprints(actual.bundle.manifest) !=
      _manifestWithoutChunkFingerprints(expected.manifest)) {
    throw StateError(
      'Migration manifest is stale or differs from snapshots and hook declarations.',
    );
  }
  if (actual.bundle.chunkFiles.length != expected.chunkFiles.length ||
      !actual.bundle.chunkFiles.keys.toSet().containsAll(
        expected.chunkFiles.keys,
      )) {
    throw StateError('Migration chunk file set is stale or incomplete.');
  }
  for (final item in expected.chunkFiles.entries) {
    final source = actual.bundle.chunkFiles[item.key]!;
    if (source.trimRight() != item.value) {
      throw StateError(
        'Migration chunk ${item.key} is stale or incompatible with snapshots.',
      );
    }
  }
  return actual.bundle.manifest;
}

String _manifestWithoutChunkFingerprints(MigrationManifest manifest) {
  final json = manifest.toJson();
  json['chunks'] = [
    for (final chunk in manifest.chunks)
      {
        'firstTargetVersion': chunk.firstTargetVersion,
        'lastTargetVersion': chunk.lastTargetVersion,
        'file': chunk.file,
      },
  ];
  return jsonEncode(json);
}

Future<({MigrationArtifactBundle bundle, Set<String> unreferenced})>
_readArtifactBundle(
  Directory directory, {
  Set<String> allowUnreferenced = const {},
}) async {
  final manifestFile = File('${directory.path}/manifest.json');
  if (!await manifestFile.exists()) {
    throw StateError('Missing ${manifestFile.path}.');
  }
  final manifest = MigrationManifest.decode(await manifestFile.readAsString());
  final referenced = {for (final chunk in manifest.chunks) chunk.file};
  final files = <String, String>{};
  final actual = <String>{};
  await for (final entity in directory.list()) {
    if (entity is! File) {
      throw StateError(
        'Unexpected directory in migration artifacts: ${entity.path}',
      );
    }
    final name = entity.uri.pathSegments.last;
    if (name != 'manifest.json') actual.add(name);
  }
  final unreferenced = actual.difference(referenced);
  if (!allowUnreferenced.containsAll(unreferenced)) {
    throw StateError(
      'Migration artifact directory contains unreferenced files: '
      '${unreferenced.difference(allowUnreferenced).join(', ')}.',
    );
  }
  for (final record in manifest.chunks) {
    final file = File('${directory.path}/${record.file}');
    if (!await file.exists()) {
      throw StateError('Missing migration chunk ${record.file}.');
    }
    final source = await file.readAsString();
    final chunk = MigrationPlanChunk.decode(source);
    if (source.trimRight() != chunk.encode()) {
      throw FormatException(
        'Migration chunk ${record.file} is not canonical JSON.',
      );
    }
    files[record.file] = source;
  }
  final bundle = MigrationArtifactBundle.fromAssets(
    manifest: manifest,
    chunkFiles: files,
  );
  return (bundle: bundle, unreferenced: unreferenced);
}

Future<void> _compact(Map<String, List<String>> options) async {
  final schemas = await _readSnapshots(Directory(_one(options, 'snapshots')));
  if (schemas.length < 2) {
    throw StateError('At least two snapshots are required to compact history.');
  }
  final migrationDir = Directory(_one(options, 'migrations'));
  final manifest = await _verifyFullArtifacts(
    schemas: schemas,
    migrationDir: migrationDir,
    hooks: await _hooks(options),
  );
  final output = Directory(_one(options, 'out'));
  if (await output.exists() && await output.list().isEmpty) {
    await output.delete();
  } else if (await output.exists()) {
    throw StateError('Checkpoint output must be new or empty: ${output.path}');
  }

  final loaded = await _readArtifactBundle(migrationDir);
  final compacted = MigrationArtifactBundle.withChunkFingerprints(
    loaded.bundle,
  );
  final latest = schemas.last;
  final previous = schemas[schemas.length - 2];
  if (manifest.latestVersion != latest.version ||
      previous.version != latest.version - 1) {
    throw StateError(
      'Full snapshots and migration history do not end at the same adjacent versions.',
    );
  }

  await output.parent.create(recursive: true);
  final stage = await output.parent.createTemp(
    '.sqlite-schema-forge-checkpoints-',
  );
  try {
    await File('${stage.path}/${_snapshotName(previous.version)}')
        .writeAsString('${SchemaSnapshot.encode(previous)}\n');
    await File('${stage.path}/${_snapshotName(latest.version)}')
        .writeAsString('${SchemaSnapshot.encode(latest)}\n');
    await _atomicWrite(
      File('${migrationDir.path}/manifest.json'),
      '${compacted.manifest.encode()}\n',
    );
    await stage.rename(output.path);
  } catch (_) {
    if (await stage.exists()) await stage.delete(recursive: true);
    rethrow;
  }
  stdout.writeln(
    'Compacted ${schemas.length} snapshots to checkpoint pair '
    '${previous.version}/${latest.version}; preserved '
    '${manifest.transitions.length} migration transitions.',
  );
}

String _snapshotName(int version) =>
    '${version.toString().padLeft(4, '0')}.json';

Future<void> _verifyIncremental(Map<String, List<String>> options) async {
  final migrationDir = Directory(_one(options, 'migrations'));
  final checkpoints = Directory(_one(options, 'checkpoints'));
  final bundle = (await _readArtifactBundle(migrationDir)).bundle;
  await _verifyIncrementalBundle(bundle: bundle, checkpoints: checkpoints);
  stdout.writeln(
    'Verified ${bundle.manifest.transitions.length} transitions and the latest checkpoint pair.',
  );
}

Future<List<Schema>> _readCheckpointPair({
  required Directory checkpoints,
  required int latestVersion,
  bool allowPendingNextVersion = false,
  bool allowOlderVersions = false,
}) async {
  final all = await _readSnapshots(checkpoints);
  final byVersion = {for (final schema in all) schema.version: schema};
  final previous = byVersion[latestVersion - 1];
  final current = byVersion[latestVersion];
  if (previous == null || current == null) {
    throw StateError(
      'Checkpoint directory must contain versions ${latestVersion - 1} '
      'and $latestVersion to match migration history.',
    );
  }
  final unexpectedFuture = byVersion.keys.where(
    (version) =>
        version > latestVersion &&
        !(allowPendingNextVersion && version == latestVersion + 1),
  );
  if (unexpectedFuture.isNotEmpty) {
    throw StateError(
      'Checkpoint directory contains versions newer than migration history: '
      '${unexpectedFuture.join(', ')}.',
    );
  }
  final unexpectedOld = byVersion.keys.where(
    (version) => version < latestVersion - 1,
  );
  if (!allowOlderVersions && unexpectedOld.isNotEmpty) {
    throw StateError(
      'Checkpoint directory must retain only its rolling pair; found stale '
      'versions ${unexpectedOld.join(', ')}.',
    );
  }
  return [previous, current];
}

Future<void> _verifyIncrementalBundle({
  required MigrationArtifactBundle bundle,
  required Directory checkpoints,
  bool allowPendingNextVersion = false,
  bool allowOlderVersions = false,
}) async {
  final missingFingerprints = bundle.manifest.chunks
      .where((chunk) => chunk.contentFingerprint == null)
      .map((chunk) => chunk.file)
      .toList();
  if (missingFingerprints.isNotEmpty) {
    throw StateError(
      'Migration chunks lack integrity fingerprints. Compact the full history '
      'before using incremental verification.',
    );
  }
  final pair = await _readCheckpointPair(
    checkpoints: checkpoints,
    latestVersion: bundle.manifest.latestVersion,
    allowPendingNextVersion: allowPendingNextVersion,
    allowOlderVersions: allowOlderVersions,
  );
  final previous = pair.first;
  final latest = pair.last;
  final transition = bundle.manifest.transitions.last;
  if (transition.fromVersion != previous.version ||
      transition.toVersion != latest.version ||
      transition.fromFingerprint != SchemaSnapshot.fingerprint(previous) ||
      transition.toFingerprint != SchemaSnapshot.fingerprint(latest)) {
    throw StateError(
      'Rolling checkpoints do not match the latest migration transition. '
      'Restore the matching checkpoint pair or run full history verification.',
    );
  }
  final persisted =
      [
        for (final source in bundle.chunkFiles.values)
          ...MigrationPlanChunk.decode(source).plans,
      ].singleWhere(
        (plan) =>
            plan.fromVersion == transition.fromVersion &&
            plan.toVersion == transition.toVersion,
      );
  final rebuilt = await MigrationPlanCompiler.compile(
    previous: previous,
    current: latest,
  );
  if (jsonEncode(MigrationPlanSnapshot.toJson(persisted)) !=
      jsonEncode(MigrationPlanSnapshot.toJson(rebuilt))) {
    throw StateError(
      'Latest migration plan differs from its rolling schema checkpoints.',
    );
  }
}

Future<void> _advance(Map<String, List<String>> options) async {
  final migrationDir = Directory(_one(options, 'migrations'));
  final checkpoints = Directory(_one(options, 'checkpoints'));
  final manifestFile = File('${migrationDir.path}/manifest.json');
  if (!await manifestFile.exists()) {
    throw StateError(
      'Missing ${manifestFile.path}; compile initial history first.',
    );
  }
  final currentManifest = MigrationManifest.decode(
    await manifestFile.readAsString(),
  );
  final nextVersion = currentManifest.latestVersion + 1;
  final nextChunkName =
      '${nextVersion.toString().padLeft(4, '0')}-'
      '${nextVersion.toString().padLeft(4, '0')}.json';
  await _discardAdvanceTemporaries(
    migrationDir: migrationDir,
    checkpoints: checkpoints,
    nextChunkName: nextChunkName,
    nextVersion: nextVersion,
  );
  final loaded = await _readArtifactBundle(
    migrationDir,
    allowUnreferenced: {nextChunkName},
  );
  final pair = await _readCheckpointPair(
    checkpoints: checkpoints,
    latestVersion: currentManifest.latestVersion,
    allowPendingNextVersion: true,
    allowOlderVersions: true,
  );
  await _verifyIncrementalBundle(
    bundle: loaded.bundle,
    checkpoints: checkpoints,
    allowPendingNextVersion: true,
    allowOlderVersions: true,
  );

  final schemas = await _readSnapshots(checkpoints);
  final schemaByVersion = {
    for (final schema in schemas) schema.version: schema,
  };
  final current = pair.last;
  final nextSchema = await _runEntry(_one(options, 'entry'));
  if (nextSchema.version != nextVersion) {
    throw StateError(
      'Next schema entry must declare version $nextVersion; '
      'it declared ${nextSchema.version}.',
    );
  }
  final nextFingerprint = SchemaSnapshot.fingerprint(nextSchema);
  final pendingCheckpoint = schemaByVersion[nextVersion];
  if (pendingCheckpoint != null &&
      SchemaSnapshot.encode(pendingCheckpoint) !=
          SchemaSnapshot.encode(nextSchema)) {
    throw StateError(
      'An uncommitted checkpoint for version $nextVersion differs from the '
      'schema entry. Resolve the interrupted append before continuing.',
    );
  }
  final plan = await MigrationPlanCompiler.compile(
    previous: current,
    current: nextSchema,
  );
  final hooks = await _hooks(options);
  final nextRange = (current.version, nextVersion);
  for (final entry in hooks.entries) {
    if (entry.key == nextRange) continue;
    final old = currentManifest.transitions.where(
      (item) =>
          item.fromVersion == entry.key.$1 && item.toVersion == entry.key.$2,
    );
    if (old.length != 1 ||
        !old.single.requiresHook ||
        old.single.hookPhase != entry.value.phase) {
      throw StateError(
        'Hook metadata ${entry.key.$1}->${entry.key.$2} does not match the '
        'existing manifest or the new transition $nextVersion.',
      );
    }
  }
  final nextBundle = MigrationArtifactBundle.append(
    existing: loaded.bundle,
    plan: plan,
    fromFingerprint: SchemaSnapshot.fingerprint(current),
    toFingerprint: nextFingerprint,
    hook: hooks[nextRange],
  );
  for (final name in loaded.unreferenced) {
    if (name != nextChunkName || loaded.bundle.chunkFiles.containsKey(name)) {
      throw StateError('Unexpected unreferenced artifact $name.');
    }
    final orphan = File('${migrationDir.path}/$name');
    if (!await orphan.exists() ||
        (await orphan.readAsString()).trimRight() !=
            nextBundle.chunkFiles[name]) {
      throw StateError(
        'An uncommitted migration chunk $name differs from the next plan. '
        'Remove the orphan file after reviewing it, then retry.',
      );
    }
  }

  await migrationDir.create(recursive: true);
  await checkpoints.create(recursive: true);
  await _writeIfAbsentOrEqual(
    File('${migrationDir.path}/$nextChunkName'),
    '${nextBundle.chunkFiles[nextChunkName]}\n',
  );
  await _writeIfAbsentOrEqual(
    File('${checkpoints.path}/${_snapshotName(nextVersion)}'),
    '${SchemaSnapshot.encode(nextSchema)}\n',
  );
  await _atomicWrite(manifestFile, '${nextBundle.manifest.encode()}\n');

  for (final schema in schemas) {
    if (schema.version != current.version && schema.version != nextVersion) {
      await File('${checkpoints.path}/${_snapshotName(schema.version)}')
          .delete();
    }
  }
  await _verifyIncrementalBundle(bundle: nextBundle, checkpoints: checkpoints);
  stdout.writeln(
    'Appended ${current.version}->$nextVersion; preserved '
    '${nextBundle.manifest.transitions.length - 1} prior transitions.',
  );
}

Future<void> _discardAdvanceTemporaries({
  required Directory migrationDir,
  required Directory checkpoints,
  required String nextChunkName,
  required int nextVersion,
}) async {
  for (final file in [
    File('${migrationDir.path}/manifest.json.tmp'),
    File('${migrationDir.path}/$nextChunkName.tmp'),
    File('${checkpoints.path}/${_snapshotName(nextVersion)}.tmp'),
  ]) {
    if (await file.exists()) await file.delete();
  }
}

Future<void> _writeIfAbsentOrEqual(File file, String content) async {
  if (await file.exists()) {
    if ((await file.readAsString()).trimRight() != content.trimRight()) {
      throw StateError('Refusing to overwrite conflicting file ${file.path}.');
    }
    return;
  }
  await file.parent.create(recursive: true);
  await _atomicWrite(file, content);
}

Future<void> _atomicWrite(File target, String content) async {
  await target.parent.create(recursive: true);
  final temp = File('${target.path}.tmp');
  if (await temp.exists()) await temp.delete();
  await temp.writeAsString(content, flush: true);
  try {
    await temp.rename(target.path);
  } catch (_) {
    if (await temp.exists()) await temp.delete();
    rethrow;
  }
}
