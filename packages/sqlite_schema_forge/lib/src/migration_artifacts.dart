import 'dart:convert';

import 'plan.dart';
import 'plan_snapshot.dart';

/// Explicit hook lifecycle boundary recorded in the migration manifest.
enum MigrationHookPhase {
  /// Run while the source schema still exists, before applying the plan.
  beforePlan,

  /// Run after the destination schema has been applied.
  afterPlan,
}

/// Hook metadata supplied by the application or artifact author.
///
/// Callback code is never serialized. This record only states that the
/// transition requires an application-registered hook and where it runs.
final class MigrationHookMetadata {
  /// Lifecycle boundary required by this transition.
  final MigrationHookPhase phase;

  /// Creates hook metadata with an explicit execution boundary.
  const MigrationHookMetadata(this.phase);
}

/// One forward transition indexed by the execution manifest.
final class MigrationTransitionRecord {
  /// Source version.
  final int fromVersion;

  /// Destination version.
  final int toVersion;

  /// Whether the compiled plan contains data-loss operations.
  final bool destructive;

  /// Whether a registered runtime hook is required.
  final bool requiresHook;

  /// Hook execution boundary, present only when a hook is required.
  final MigrationHookPhase? hookPhase;

  /// Optional stable fingerprint for the source schema.
  final String? fromFingerprint;

  /// Optional stable fingerprint for the destination schema.
  final String? toFingerprint;

  /// Creates a manifest transition record.
  const MigrationTransitionRecord({
    required this.fromVersion,
    required this.toVersion,
    required this.destructive,
    required this.requiresHook,
    required this.hookPhase,
    this.fromFingerprint,
    this.toFingerprint,
  });
}

/// Location and destination-version coverage for one bounded migration file.
final class MigrationChunkRecord {
  /// First destination version in this chunk.
  final int firstTargetVersion;

  /// Last destination version in this chunk.
  final int lastTargetVersion;

  /// Relative artifact file path.
  final String file;

  /// Creates a chunk index entry.
  const MigrationChunkRecord({
    required this.firstTargetVersion,
    required this.lastTargetVersion,
    required this.file,
  });
}

/// Execution index for versioned, forward-only migration artifacts.
final class MigrationManifest {
  /// Current manifest format version.
  static const formatVersion = 1;

  /// Latest schema version represented by the artifact set.
  final int latestVersion;

  /// Starting versions for which the manifest declares a complete path.
  final List<int> supportedStartingVersions;

  /// Bounded plan asset index.
  final List<MigrationChunkRecord> chunks;

  /// Per-transition destructive and hook metadata.
  final List<MigrationTransitionRecord> transitions;

  /// Creates and validates an execution manifest.
  MigrationManifest({
    required this.latestVersion,
    required List<int> supportedStartingVersions,
    required List<MigrationChunkRecord> chunks,
    required List<MigrationTransitionRecord> transitions,
  }) : supportedStartingVersions = List.unmodifiable(
         [...supportedStartingVersions]..sort(),
       ),
       chunks = List.unmodifiable(
         chunks.toList()..sort(
           (a, b) => a.firstTargetVersion.compareTo(b.firstTargetVersion),
         ),
       ),
       transitions = List.unmodifiable(
         transitions.toList()
           ..sort((a, b) => a.toVersion.compareTo(b.toVersion)),
       ) {
    _validate();
  }

  /// Canonical readable JSON representation.
  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Canonical JSON-compatible representation.
  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'latestVersion': latestVersion,
    'supportedStartingVersions': supportedStartingVersions,
    'chunks': [
      for (final chunk in chunks)
        {
          'firstTargetVersion': chunk.firstTargetVersion,
          'lastTargetVersion': chunk.lastTargetVersion,
          'file': chunk.file,
        },
    ],
    'transitions': [
      for (final transition in transitions)
        {
          'from': transition.fromVersion,
          'to': transition.toVersion,
          'destructive': transition.destructive,
          'requiresHook': transition.requiresHook,
          if (transition.hookPhase != null)
            'hookPhase': transition.hookPhase!.name,
          if (transition.fromFingerprint != null)
            'fromFingerprint': transition.fromFingerprint,
          if (transition.toFingerprint != null)
            'toFingerprint': transition.toFingerprint,
        },
    ],
  };

  /// Parses and validates a manifest document.
  factory MigrationManifest.decode(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw FormatException(
        'Invalid migration manifest JSON: ${error.message}',
      );
    }
    final root = _map(decoded, 'manifest');
    final format = _int(root['formatVersion'], 'formatVersion');
    if (format != formatVersion) {
      throw FormatException(
        'Unsupported migration manifest formatVersion $format; '
        'supported version is $formatVersion.',
      );
    }
    final chunks = _list(root['chunks'], 'chunks').asMap().entries.map((entry) {
      final m = _map(entry.value, 'chunks[${entry.key}]');
      return MigrationChunkRecord(
        firstTargetVersion: _int(
          m['firstTargetVersion'],
          'chunk.firstTargetVersion',
        ),
        lastTargetVersion: _int(
          m['lastTargetVersion'],
          'chunk.lastTargetVersion',
        ),
        file: _string(m['file'], 'chunk.file'),
      );
    }).toList();
    final transitions = _list(root['transitions'], 'transitions')
        .asMap()
        .entries
        .map((entry) {
          final m = _map(entry.value, 'transitions[${entry.key}]');
          final requiresHook = _bool(
            m['requiresHook'],
            'transition.requiresHook',
          );
          return MigrationTransitionRecord(
            fromVersion: _int(m['from'], 'transition.from'),
            toVersion: _int(m['to'], 'transition.to'),
            destructive: _bool(m['destructive'], 'transition.destructive'),
            requiresHook: requiresHook,
            hookPhase: requiresHook
                ? _enum(
                    MigrationHookPhase.values,
                    m['hookPhase'],
                    'transition.hookPhase',
                  )
                : null,
            fromFingerprint: _optionalString(
              m['fromFingerprint'],
              'transition.fromFingerprint',
            ),
            toFingerprint: _optionalString(
              m['toFingerprint'],
              'transition.toFingerprint',
            ),
          );
        })
        .toList();
    return MigrationManifest(
      latestVersion: _int(root['latestVersion'], 'latestVersion'),
      supportedStartingVersions: _intList(
        root['supportedStartingVersions'],
        'supportedStartingVersions',
      ),
      chunks: chunks,
      transitions: transitions,
    );
  }

  /// Ensures every declared starting version has a complete path to latest.
  void _validate() {
    if (latestVersion < 1) {
      throw FormatException('latestVersion must be positive.');
    }
    if (transitions.isEmpty) {
      throw FormatException('Manifest has no transitions.');
    }
    if (chunks.isEmpty) throw FormatException('Manifest has no plan chunks.');
    final ordered = [...transitions]
      ..sort((a, b) => a.toVersion.compareTo(b.toVersion));
    final destinations = <int>{};
    for (final transition in ordered) {
      if (transition.toVersion != transition.fromVersion + 1) {
        throw FormatException(
          'Transition ${transition.fromVersion}->${transition.toVersion} is not an adjacent forward transition.',
        );
      }
      if (!destinations.add(transition.toVersion)) {
        throw FormatException(
          'Duplicate transition destination ${transition.toVersion}.',
        );
      }
      if (transition.requiresHook != (transition.hookPhase != null)) {
        throw FormatException(
          'Hook metadata is incomplete for ${transition.fromVersion}->${transition.toVersion}.',
        );
      }
    }
    for (var i = 1; i < ordered.length; i++) {
      if (ordered[i - 1].toVersion != ordered[i].fromVersion) {
        throw FormatException(
          'Migration transitions are not contiguous at ${ordered[i - 1].toVersion}->${ordered[i].fromVersion}.',
        );
      }
    }
    if (ordered.last.toVersion != latestVersion) {
      throw FormatException(
        'Manifest transitions do not end at latestVersion $latestVersion.',
      );
    }
    final chunkDestinations = <int>{};
    final orderedChunks = [...chunks]
      ..sort((a, b) => a.firstTargetVersion.compareTo(b.firstTargetVersion));
    for (final chunk in orderedChunks) {
      if (chunk.firstTargetVersion > chunk.lastTargetVersion ||
          chunk.file.trim().isEmpty ||
          chunk.file.contains('/') ||
          chunk.file.contains('\\') ||
          chunk.file == '.' ||
          chunk.file == '..') {
        throw FormatException('Invalid migration chunk entry "${chunk.file}".');
      }
      if (chunk.lastTargetVersion - chunk.firstTargetVersion + 1 > 10) {
        throw FormatException(
          'Migration chunk "${chunk.file}" exceeds ten destination versions.',
        );
      }
      for (
        var version = chunk.firstTargetVersion;
        version <= chunk.lastTargetVersion;
        version++
      ) {
        if (!chunkDestinations.add(version)) {
          throw FormatException(
            'Overlapping chunk coverage at destination version $version.',
          );
        }
      }
    }
    for (final transition in ordered) {
      if (!chunkDestinations.contains(transition.toVersion)) {
        throw FormatException(
          'No migration chunk covers destination version ${transition.toVersion}.',
        );
      }
    }
    if (chunkDestinations.length != destinations.length) {
      throw FormatException(
        'Migration chunks cover versions without transition records.',
      );
    }
    final starts = [...supportedStartingVersions]..sort();
    if (starts.isEmpty || starts.toSet().length != starts.length) {
      throw FormatException(
        'supportedStartingVersions must be non-empty and unique.',
      );
    }
    for (final start in starts) {
      if (start >= latestVersion) {
        throw FormatException(
          'Supported starting version $start must be less than latestVersion.',
        );
      }
      for (var from = start; from < latestVersion; from++) {
        if (!destinations.contains(from + 1)) {
          throw FormatException(
            'No complete migration path from version $start: missing $from->${from + 1}.',
          );
        }
      }
    }
  }

  static Map<String, Object?> _map(Object? v, String p) {
    if (v is! Map || v.keys.any((key) => key is! String)) {
      throw FormatException('$p must be a JSON object with string keys.');
    }
    return v.cast<String, Object?>();
  }

  static List<Object?> _list(Object? v, String p) => v is List
      ? v.cast<Object?>()
      : throw FormatException('$p must be a JSON array.');

  static List<int> _intList(Object? v, String p) => _list(
    v,
    p,
  ).asMap().entries.map((e) => _int(e.value, '$p[${e.key}]')).toList();

  static int _int(Object? v, String p) =>
      v is int ? v : throw FormatException('$p must be an integer.');

  static String _string(Object? v, String p) =>
      v is String ? v : throw FormatException('$p must be a string.');

  static String? _optionalString(Object? v, String p) =>
      v == null ? null : _string(v, p);

  static bool _bool(Object? v, String p) =>
      v is bool ? v : throw FormatException('$p must be a boolean.');

  static T _enum<T extends Enum>(List<T> values, Object? v, String p) {
    if (v is String) {
      for (final value in values) {
        if (value.name == v) return value;
      }
    }
    throw FormatException('$p has an unknown value "$v".');
  }
}

/// JSON plan chunk containing one bounded range of transitions.
final class MigrationPlanChunk {
  /// Current migration chunk format version.
  static const formatVersion = 1;

  /// Compiled plans, in destination-version order.
  final List<MigrationPlan> plans;

  /// Creates an immutable chunk.
  MigrationPlanChunk(List<MigrationPlan> values)
    : plans = List.unmodifiable(
        values.toList()..sort((a, b) => a.toVersion.compareTo(b.toVersion)),
      ) {
    if (plans.isEmpty) throw ArgumentError('Migration chunks cannot be empty.');
    final ordered = plans;
    for (var i = 0; i < ordered.length; i++) {
      final plan = ordered[i];
      if (plan.toVersion != plan.fromVersion + 1) {
        throw ArgumentError(
          'Chunk plans must be adjacent forward transitions.',
        );
      }
      if (i > 0 && ordered[i - 1].toVersion != plan.fromVersion) {
        throw ArgumentError(
          'Chunk plans must form a contiguous transition range.',
        );
      }
    }
  }

  /// First destination version represented.
  int get firstTargetVersion =>
      plans.map((p) => p.toVersion).reduce((a, b) => a < b ? a : b);

  /// Last destination version represented.
  int get lastTargetVersion =>
      plans.map((p) => p.toVersion).reduce((a, b) => a > b ? a : b);

  /// Human-readable deterministic JSON.
  String encode() => const JsonEncoder.withIndent('  ').convert({
    'formatVersion': formatVersion,
    'plans': [for (final plan in plans) MigrationPlanSnapshot.toJson(plan)],
  });

  /// Decode a chunk and verify the plan range matches its containing manifest.
  factory MigrationPlanChunk.decode(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw FormatException('Invalid migration chunk JSON: ${error.message}');
    }
    final root = MigrationManifest._map(decoded, 'chunk');
    final format = MigrationManifest._int(
      root['formatVersion'],
      'formatVersion',
    );
    if (format != formatVersion) {
      throw FormatException(
        'Unsupported migration chunk formatVersion $format.',
      );
    }
    final plans = MigrationManifest._list(
      root['plans'],
      'plans',
    ).map((value) => MigrationPlanSnapshot.decode(jsonEncode(value))).toList();
    try {
      return MigrationPlanChunk(plans);
    } on ArgumentError catch (error) {
      throw FormatException('Invalid migration chunk: ${error.message}');
    }
  }
}

/// Complete build-time output: execution manifest plus bounded plan assets.
final class MigrationArtifactBundle {
  /// Execution manifest.
  final MigrationManifest manifest;

  /// Chunk file name to JSON content.
  final Map<String, String> chunkFiles;

  MigrationArtifactBundle._(this.manifest, Map<String, String> chunkFiles)
    : chunkFiles = Map.unmodifiable(chunkFiles);

  /// Reconstructs and validates a bundle from a decoded manifest and assets.
  factory MigrationArtifactBundle.fromAssets({
    required MigrationManifest manifest,
    required Map<String, String> chunkFiles,
  }) {
    final bundle = MigrationArtifactBundle._(manifest, chunkFiles);
    bundle.validate();
    return bundle;
  }

  /// Builds deterministic manifest and chunks from already compiled plans.
  ///
  /// Hook requirements and lifecycle boundaries are explicit inputs. Optional
  /// fingerprints are keyed by schema version.
  factory MigrationArtifactBundle.build({
    required List<MigrationPlan> plans,
    Map<(int, int), MigrationHookMetadata> hooks = const {},
    Map<int, String> schemaFingerprints = const {},
    int chunkSize = 10,
  }) {
    if (chunkSize < 1 || chunkSize > 10) {
      throw ArgumentError.value(
        chunkSize,
        'chunkSize',
        'must be between 1 and 10',
      );
    }
    if (plans.isEmpty) {
      throw ArgumentError('At least one compiled plan is required.');
    }
    final ordered = [...plans]
      ..sort((a, b) => a.toVersion.compareTo(b.toVersion));
    for (var i = 0; i < ordered.length; i++) {
      final plan = ordered[i];
      if (plan.toVersion != plan.fromVersion + 1) {
        throw ArgumentError(
          'Plan ${plan.fromVersion}->${plan.toVersion} is not adjacent and forward.',
        );
      }
      if (i > 0 && ordered[i - 1].toVersion != plan.fromVersion) {
        throw ArgumentError(
          'Plans must be a contiguous forward migration path.',
        );
      }
    }
    for (final range in hooks.keys) {
      if (!ordered.any((plan) => (plan.fromVersion, plan.toVersion) == range)) {
        throw ArgumentError(
          'Hook metadata references missing transition ${range.$1}->${range.$2}.',
        );
      }
    }
    final first = ordered.first.toVersion;
    final latest = ordered.last.toVersion;
    final records = [
      for (final plan in ordered)
        MigrationTransitionRecord(
          fromVersion: plan.fromVersion,
          toVersion: plan.toVersion,
          destructive: plan.hasDestructiveChanges,
          requiresHook:
              plan.hasDestructiveChanges ||
              hooks.containsKey((plan.fromVersion, plan.toVersion)),
          hookPhase:
              hooks[(plan.fromVersion, plan.toVersion)]?.phase ??
              (plan.hasDestructiveChanges
                  ? MigrationHookPhase.beforePlan
                  : null),
          fromFingerprint: schemaFingerprints[plan.fromVersion],
          toFingerprint: schemaFingerprints[plan.toVersion],
        ),
    ];
    final files = <String, String>{};
    final chunkRecords = <MigrationChunkRecord>[];
    for (var offset = 0; offset < ordered.length; offset += chunkSize) {
      final end = (offset + chunkSize < ordered.length)
          ? offset + chunkSize
          : ordered.length;
      final chunk = MigrationPlanChunk(ordered.sublist(offset, end));
      final name =
          '${chunk.firstTargetVersion.toString().padLeft(4, '0')}-'
          '${chunk.lastTargetVersion.toString().padLeft(4, '0')}.json';
      files[name] = chunk.encode();
      chunkRecords.add(
        MigrationChunkRecord(
          firstTargetVersion: chunk.firstTargetVersion,
          lastTargetVersion: chunk.lastTargetVersion,
          file: name,
        ),
      );
    }
    final manifest = MigrationManifest(
      latestVersion: latest,
      supportedStartingVersions: [for (var v = first - 1; v < latest; v++) v],
      chunks: chunkRecords,
      transitions: records,
    );
    final bundle = MigrationArtifactBundle._(manifest, files);
    bundle.validate();
    return bundle;
  }

  /// Validates that all indexed files exist and agree with manifest metadata.
  void validate() {
    final seen = <(int, int)>{};
    for (final record in manifest.chunks) {
      final source = chunkFiles[record.file];
      if (source == null) {
        throw FormatException('Migration chunk "${record.file}" is missing.');
      }
      final chunk = MigrationPlanChunk.decode(source);
      if (chunk.firstTargetVersion != record.firstTargetVersion ||
          chunk.lastTargetVersion != record.lastTargetVersion) {
        throw FormatException(
          'Migration chunk "${record.file}" does not match its manifest range.',
        );
      }
      for (final plan in chunk.plans) {
        final key = (plan.fromVersion, plan.toVersion);
        if (!seen.add(key)) {
          throw FormatException(
            'Duplicate plan transition ${key.$1}->${key.$2}.',
          );
        }
        final transition = manifest.transitions.where(
          (item) => item.fromVersion == key.$1 && item.toVersion == key.$2,
        );
        if (transition.length != 1 ||
            transition.single.destructive != plan.hasDestructiveChanges) {
          throw FormatException(
            'Plan ${key.$1}->${key.$2} conflicts with manifest transition metadata.',
          );
        }
      }
    }
    if (seen.length != manifest.transitions.length) {
      throw FormatException(
        'Migration chunks do not contain every manifest transition.',
      );
    }
  }
}

/// Platform-neutral, lazy access to a production migration artifact set.
///
/// Implementations can read Flutter assets, files, embedded strings, or a
/// custom source. The core package performs no I/O until [loadPath] is called.
abstract interface class MigrationArtifactLoader {
  /// Reads the manifest document.
  Future<String> loadManifest();

  /// Reads one chunk by its manifest-relative [file] path.
  Future<String> loadChunk(String file);
}

/// Validated plans and transition metadata for one requested forward path.
final class LoadedMigrationPath {
  /// Manifest used to resolve this path.
  final MigrationManifest manifest;

  /// Plans from [fromVersion] to [toVersion], in execution order.
  final List<MigrationPlan> plans;

  /// Matching manifest records, in execution order.
  final List<MigrationTransitionRecord> transitions;

  /// Starting database version.
  final int fromVersion;

  /// Requested destination version.
  final int toVersion;

  LoadedMigrationPath._({
    required this.manifest,
    required List<MigrationPlan> plans,
    required List<MigrationTransitionRecord> transitions,
    required this.fromVersion,
    required this.toVersion,
  }) : plans = List.unmodifiable(plans),
       transitions = List.unmodifiable(transitions);
}

/// Loads only artifact chunks that intersect a requested version path.
final class MigrationArtifactStore {
  /// Lazily accessed source of migration manifest and chunk files.
  final MigrationArtifactLoader loader;

  /// Creates a store around a caller-provided lazy loader.
  const MigrationArtifactStore(this.loader);

  /// Loads and validates `fromVersion -> toVersion`.
  ///
  /// Call this only after fresh-install and already-current fast paths. The
  /// manifest is read exactly once per call, then only intersecting chunks are
  /// fetched. Chunk contents outside the requested path are ignored.
  Future<LoadedMigrationPath> loadPath({
    required int fromVersion,
    required int toVersion,
  }) async {
    if (fromVersion >= toVersion) {
      throw ArgumentError('Precomputed migrations are forward-only.');
    }
    final manifestSource = await loader.loadManifest();
    final manifest = MigrationManifest.decode(manifestSource);
    if (toVersion > manifest.latestVersion) {
      throw FormatException(
        'Requested target version $toVersion exceeds migration history latest '
        'version ${manifest.latestVersion}.',
      );
    }
    if (!manifest.supportedStartingVersions.contains(fromVersion)) {
      throw FormatException(
        'Migration history does not declare a complete path from version $fromVersion.',
      );
    }
    if (toVersion <= fromVersion) {
      throw ArgumentError(
        'Target version must be greater than the installed version.',
      );
    }
    final pathTransitions =
        manifest.transitions
            .where(
              (transition) =>
                  transition.fromVersion >= fromVersion &&
                  transition.toVersion <= toVersion,
            )
            .toList()
          ..sort((a, b) => a.toVersion.compareTo(b.toVersion));
    if (pathTransitions.length != toVersion - fromVersion) {
      throw FormatException(
        'Migration history has an incomplete path from $fromVersion to $toVersion.',
      );
    }
    for (var i = 0; i < pathTransitions.length; i++) {
      final expectedFrom = fromVersion + i;
      if (pathTransitions[i].fromVersion != expectedFrom ||
          pathTransitions[i].toVersion != expectedFrom + 1) {
        throw FormatException(
          'Migration history path is incomplete at $expectedFrom -> ${expectedFrom + 1}.',
        );
      }
    }

    final selectedChunks =
        manifest.chunks
            .where(
              (chunk) =>
                  chunk.lastTargetVersion > fromVersion &&
                  chunk.firstTargetVersion <= toVersion,
            )
            .toList()
          ..sort(
            (a, b) => a.firstTargetVersion.compareTo(b.firstTargetVersion),
          );
    final plansByRange = <(int, int), MigrationPlan>{};
    for (final record in selectedChunks) {
      final String chunkSource;
      try {
        chunkSource = await loader.loadChunk(record.file);
      } catch (error) {
        throw FormatException(
          'Unable to load required migration chunk "${record.file}": $error',
        );
      }
      final chunk = MigrationPlanChunk.decode(chunkSource);
      if (chunk.firstTargetVersion != record.firstTargetVersion ||
          chunk.lastTargetVersion != record.lastTargetVersion) {
        throw FormatException(
          'Migration chunk "${record.file}" does not match its manifest range.',
        );
      }
      for (final plan in chunk.plans) {
        if (plan.toVersion <= fromVersion || plan.toVersion > toVersion) {
          continue;
        }
        final key = (plan.fromVersion, plan.toVersion);
        if (plansByRange.containsKey(key)) {
          throw FormatException(
            'Duplicate precomputed plan ${key.$1}->${key.$2}.',
          );
        }
        final recordMatches = pathTransitions.where(
          (transition) =>
              transition.fromVersion == key.$1 &&
              transition.toVersion == key.$2,
        );
        if (recordMatches.length != 1 ||
            recordMatches.single.destructive != plan.hasDestructiveChanges) {
          throw FormatException(
            'Precomputed plan ${key.$1}->${key.$2} conflicts with manifest metadata.',
          );
        }
        plansByRange[key] = plan;
      }
    }
    final plans = <MigrationPlan>[];
    for (final transition in pathTransitions) {
      final key = (transition.fromVersion, transition.toVersion);
      final plan = plansByRange[key];
      if (plan == null) {
        throw FormatException(
          'Missing precomputed plan ${key.$1}->${key.$2} in selected migration chunks.',
        );
      }
      plans.add(plan);
    }
    return LoadedMigrationPath._(
      manifest: manifest,
      plans: plans,
      transitions: pathTransitions,
      fromVersion: fromVersion,
      toVersion: toVersion,
    );
  }
}
