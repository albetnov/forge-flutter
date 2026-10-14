import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sqlite_query_forge/sqlite_query_forge.dart';
import 'package:sqlite_schema_forge/sqlite_schema_forge.dart';

import 'config.dart';
import 'exceptions.dart';
import 'secure_password.dart';
import 'worker.dart';

/// Zone token marking "inside a transaction owned by this driver".
///
/// Lets operations issued from a transaction callback bypass the connection
/// mutex (the transaction already holds it), while unrelated concurrent
/// callers correctly queue behind it.
const _txnToken = #sqliteDriverForgeTxn;

/// A background-isolate driver over `package:sqlite3`.
///
/// The SQLite connection lives on a dedicated worker isolate (like drift's
/// connection manager): the main isolate never touches SQLite directly, so
/// UI code never blocks on I/O and all access is serialized through one
/// connection. This single class implements both
/// [ForgeExecutor] (`sqlite_query_forge`) and [DatabaseExecutor]
/// (`sqlite_schema_forge`), so one instance serves both packages.
///
/// Lifecycle:
///
/// ```dart
/// final driver = SqliteDriver.file('/data/app.db');
/// await driver.connect(); // or: await driver.connect(cipher: password);
/// // ... query / execute / transaction ...
/// await driver.backupTo('/data/app.backup.db'); // hot backup while open
/// await driver.disconnect();
/// ```
///
/// The driver never retains password bytes: [connect] / [changePassword]
/// forward a single copy to the worker (which zeroes it right after running
/// `PRAGMA key`) and drop their own reference. Reconnecting requires passing
/// the password again. See [SecurePassword] for the full story.
final class SqliteDriver implements ForgeExecutor, DatabaseExecutor {
  /// Static configuration for this driver.
  final SqliteDriverConfig config;

  Isolate? _isolate;
  SendPort? _worker;
  ReceivePort? _responses;
  StreamSubscription<dynamic>? _subscription;
  ReceivePort? _exitPort;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  int _nextId = 0;
  bool _connecting = false;

  final _Mutex _mutex = _Mutex();

  /// Creates a driver for the given [config].
  SqliteDriver({required this.config});

  /// Creates a driver for the database file at [path].
  factory SqliteDriver.file(
    String path, {
    bool readOnly = false,
    bool foreignKeys = true,
    String? journalMode = 'WAL',
    String? synchronous,
    int busyTimeoutMs = 5000,
    bool cipherMigrate = false,
    String? vfs,
    bool uri = false,
    SecurePassword? cipher,
  }) => SqliteDriver(
    config: SqliteDriverConfig(
      path: path,
      readOnly: readOnly,
      foreignKeys: foreignKeys,
      journalMode: journalMode,
      synchronous: synchronous,
      busyTimeoutMs: busyTimeoutMs,
      cipherMigrate: cipherMigrate,
      vfs: vfs,
      uri: uri,
      cipher: cipher,
    ),
  );

  /// Creates a driver for a private in-memory database.
  ///
  /// The database lives in the worker isolate and vanishes on [disconnect].
  /// Useful for tests and caches. [backupTo] can persist it to a file.
  factory SqliteDriver.inMemory({
    bool foreignKeys = true,
    int busyTimeoutMs = 5000,
    SecurePassword? cipher,
  }) => SqliteDriver(
    config: SqliteDriverConfig.inMemory(
      foreignKeys: foreignKeys,
      busyTimeoutMs: busyTimeoutMs,
      cipher: cipher,
    ),
  );

  /// Absolute database file path, or `null` for in-memory.
  ///
  /// Exposed so callers can export / copy / delete the file themselves
  /// (do so while disconnected, or use [backupTo] for a hot backup).
  String? get path => config.path;

  /// Whether this driver holds an in-memory database.
  bool get isInMemory => config.isInMemory;

  /// Whether the worker isolate + connection are currently up.
  bool get isConnected => _worker != null;

  /// Opens the connection on a background isolate.
  ///
  /// [cipher] overrides [SqliteDriverConfig.cipher] for this connect only
  /// and is not retained afterwards.
  ///
  /// Throws [SqlCipherAuthException] when the key is rejected,
  /// [SqliteDriverException] when opening or applying pragmas fails.
  Future<void> connect({SecurePassword? cipher}) async {
    if (isConnected || _connecting) {
      throw StateError('Already connected (or connecting).');
    }
    config.validate();
    final password = cipher ?? config.cipher;
    if (password != null && password.isDisposed) {
      throw StateError('The provided SecurePassword has been disposed.');
    }
    _connecting = true;

    final responses = ReceivePort();
    final exitPort = ReceivePort();
    _responses = responses;
    _exitPort = exitPort;
    final ready = Completer<void>();
    _subscription = responses.listen((dynamic message) {
      _onMessage(message, ready);
    });
    exitPort.listen((_) => _onWorkerExit());

    try {
      final isolate = await Isolate.spawn(
        sqliteDriverWorkerEntry,
        buildWorkerInit(
          replyTo: responses.sendPort,
          path: config.path,
          readOnly: config.readOnly,
          foreignKeys: config.foreignKeys,
          journalMode: config.journalMode,
          synchronous: config.synchronous,
          busyTimeoutMs: config.busyTimeoutMs,
          cipherMigrate: config.cipherMigrate,
          vfs: config.vfs,
          uri: config.uri,
          // One copy crosses the isolate boundary; the worker zeroes its
          // copy right after PRAGMA key. This local reference is dropped
          // when connect() returns.
          keyBytes: password?.copyBytes(),
          keyIsRaw: password?.isRawKey ?? false,
        ),
        debugName: 'sqlite3_driver_forge',
      );
      _isolate = isolate;
      isolate.addOnExitListener(exitPort.sendPort);
      await ready.future;
    } catch (_) {
      await _tearDown();
      rethrow;
    } finally {
      _connecting = false;
    }
  }

  /// Alias for [connect].
  Future<void> open({SecurePassword? cipher}) => connect(cipher: cipher);

  /// Closes the connection and shuts down the worker isolate.
  ///
  /// Idempotent: does nothing when not connected.
  Future<void> disconnect() async {
    if (!isConnected) {
      await _tearDown();
      return;
    }
    try {
      // Queued behind in-flight work; the worker is strictly sequential.
      await _roundTrip(WorkerOp.close);
    } catch (_) {
      // Best effort: fall through to kill + cleanup.
    }
    await _tearDown();
  }

  /// Alias for [disconnect].
  Future<void> close() => disconnect();

  /// [disconnect] plus nothing retained (the driver retains no passwords;
  /// dispose your own [SecurePassword]s when done).
  Future<void> dispose() => disconnect();

  // -------------------------------------------------------------------------
  // Export / backup.
  // -------------------------------------------------------------------------

  /// Hot backup of the live database to [destPath] via `VACUUM INTO`.
  ///
  /// Safe to call while connected; keeps encryption as-is. Must not be
  /// called inside a transaction (SQLite forbids `VACUUM` there).
  Future<void> backupTo(String destPath) async {
    if (destPath.isEmpty) {
      throw ArgumentError.value(destPath, 'destPath', 'Must not be empty.');
    }
    await _guarded(() => _roundTrip(WorkerOp.backup, dest: destPath));
  }

  /// Cold restore: copies [srcPath] over this driver's file.
  ///
  /// The driver must be [disconnect]ed first (copying over a live SQLite
  /// file corrupts it). Throws [UnsupportedError] for in-memory databases —
  /// there is no file to restore over.
  Future<void> restoreFrom(String srcPath) async {
    if (isConnected) {
      throw StateError('Disconnect before restoreFrom (cold copy).');
    }
    final target = config.path;
    if (target == null) {
      throw UnsupportedError('restoreFrom needs a file database.');
    }
    await File(srcPath).copy(target);
  }

  /// Rotates the encryption key (`PRAGMA rekey`).
  ///
  /// The caller owns [next] (dispose it when done); the driver forwards one
  /// copy to the worker and retains nothing.
  Future<void> changePassword(SecurePassword next) async {
    _ensureConnected();
    if (next.isDisposed) {
      throw StateError('The provided SecurePassword has been disposed.');
    }
    await _guarded(
      () => _roundTrip(
        WorkerOp.rekey,
        keyBytes: next.copyBytes(),
        keyIsRaw: next.isRawKey,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // ForgeExecutor + DatabaseExecutor.
  // -------------------------------------------------------------------------

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    _checkArgs(args);
    final response = await _guarded(
      () => _roundTrip(WorkerOp.query, sql: sql, args: args),
    );
    final rows = response['rows'] as List<Object?>? ?? const [];
    return [for (final row in rows) (row as Map).cast<String, Object?>()];
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => query(sql, arguments);

  /// Runs a statement, returning the affected row count.
  ///
  /// Satisfies both `ForgeExecutor.execute` (`Future<int>`) and
  /// `DatabaseExecutor.execute` (`Future<void>`).
  @override
  Future<int> execute(String sql, [List<Object?>? args]) async {
    _checkArgs(args);
    final response = await _guarded(
      () => _roundTrip(WorkerOp.execute, sql: sql, args: args),
    );
    return response['changes'] as int? ?? 0;
  }

  @override
  Future<int> insert(String sql, [List<Object?>? args]) async {
    _checkArgs(args);
    final response = await _guarded(
      () => _roundTrip(WorkerOp.insert, sql: sql, args: args),
    );
    return response['lastId'] as int? ?? 0;
  }

  /// Runs [action] in a transaction, rolling back if it throws.
  ///
  /// Nested calls use `SAVEPOINT`s. Concurrent transactions (and any other
  /// operation issued while one is active) are serialized through the single
  /// connection in call order.
  ///
  /// The callback receives this driver typed as [SqliteDriver], which is a
  /// [ForgeExecutor] and a [DatabaseExecutor] at once, so the signature
  /// satisfies both interfaces.
  @override
  Future<T> transaction<T>(Future<T> Function(SqliteDriver txn) action) async {
    _ensureConnected();
    if (Zone.current[_txnToken] == this) {
      return _savepoint(action);
    }
    return _mutex.run(
      () => runZoned(() => _topLevel(action), zoneValues: {_txnToken: this}),
    );
  }

  Future<T> _topLevel<T>(Future<T> Function(SqliteDriver txn) action) async {
    await _roundTrip(WorkerOp.execute, sql: 'BEGIN IMMEDIATE');
    try {
      final result = await action(this);
      await _roundTrip(WorkerOp.execute, sql: 'COMMIT');
      return result;
    } catch (_) {
      try {
        await _roundTrip(WorkerOp.execute, sql: 'ROLLBACK');
      } catch (_) {
        // The connection may be broken; preserve the original error.
      }
      rethrow;
    }
  }

  static const _savepointPrefix = 'forge_sp_';

  Future<T> _savepoint<T>(Future<T> Function(SqliteDriver txn) action) async {
    final depth = _savepointDepth++;
    final name = '$_savepointPrefix$depth';
    await _roundTrip(WorkerOp.execute, sql: 'SAVEPOINT $name');
    try {
      final result = await action(this);
      await _roundTrip(WorkerOp.execute, sql: 'RELEASE SAVEPOINT $name');
      return result;
    } catch (_) {
      try {
        await _roundTrip(WorkerOp.execute, sql: 'ROLLBACK TO SAVEPOINT $name');
        await _roundTrip(WorkerOp.execute, sql: 'RELEASE SAVEPOINT $name');
      } catch (_) {
        // Preserve the original error.
      }
      rethrow;
    } finally {
      _savepointDepth = depth;
    }
  }

  int _savepointDepth = 0;

  // -------------------------------------------------------------------------
  // Plumbing.
  // -------------------------------------------------------------------------

  void _ensureConnected() {
    if (!isConnected) {
      throw const SqliteDriverClosedException();
    }
  }

  /// Runs [fn] serialized against other callers, unless already inside this
  /// driver's transaction (zone bypass — the transaction holds the mutex).
  Future<T> _guarded<T>(Future<T> Function() fn) {
    _ensureConnected();
    if (Zone.current[_txnToken] == this) {
      return fn();
    }
    return _mutex.run(fn);
  }

  Future<Map<String, Object?>> _roundTrip(
    String op, {
    String? sql,
    List<Object?>? args,
    String? dest,
    Uint8List? keyBytes,
    bool keyIsRaw = false,
  }) {
    final worker = _worker;
    if (worker == null) {
      throw const SqliteDriverClosedException();
    }
    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    worker.send(<String, Object?>{
      'id': id,
      'op': op,
      'sql': sql,
      'args': args == null ? null : List<Object?>.from(args),
      'dest': dest,
      'keyBytes': keyBytes,
      'keyIsRaw': keyIsRaw,
    });
    return completer.future;
  }

  void _onMessage(dynamic message, Completer<void> ready) {
    final map = (message as Map).cast<String, Object?>();
    if (map.containsKey('type')) {
      _onHandshake(map, ready);
      return;
    }
    final id = map['id'] as int?;
    final completer = id == null ? null : _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    if (map['ok'] == true) {
      completer.complete(map);
    } else {
      completer.completeError(_mapError(map));
    }
  }

  void _onHandshake(Map<String, Object?> map, Completer<void> ready) {
    if (ready.isCompleted) return;
    switch (map['type']) {
      case 'port':
        _worker = map['port'] as SendPort;
      case 'ready':
        ready.complete();
      case 'error':
        ready.completeError(_mapError(map));
    }
  }

  void _onWorkerExit() {
    if (!isConnected) return; // Expected during disconnect().
    _worker = null;
    final pending = Map.of(_pending);
    _pending.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const SqliteDriverException('Database connection lost.'),
        );
      }
    }
    unawaited(_tearDown());
  }

  Future<void> _tearDown() async {
    _worker = null;
    _nextId = 0;
    final pending = Map.of(_pending);
    _pending.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(const SqliteDriverClosedException());
      }
    }
    await _subscription?.cancel();
    _subscription = null;
    _responses?.close();
    _responses = null;
    _exitPort?.close();
    _exitPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }

  static Object _mapError(Map<String, Object?> map) {
    final message = map['message'] as String? ?? 'Unknown database error.';
    final resultCode = map['resultCode'] as int?;
    return switch (map['code']) {
      'cipher_auth' => SqlCipherAuthException(message, resultCode),
      'args' => ArgumentError(message),
      _ => SqliteDriverException(message, resultCode: resultCode),
    };
  }

  static void _checkArgs(List<Object?>? args) {
    if (args == null) return;
    for (final arg in args) {
      if (arg == null ||
          arg is bool ||
          arg is int ||
          arg is double ||
          arg is String ||
          arg is Uint8List) {
        continue;
      }
      throw ArgumentError(
        'Unsupported SQLite argument type ${arg.runtimeType}; '
        'use null, bool, int, double, String or Uint8List.',
      );
    }
  }
}

/// Simple FIFO mutex serializing access to the single connection.
final class _Mutex {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() fn) {
    final previous = _tail;
    final completer = Completer<T>();
    _tail = previous.then((_) async {
      try {
        completer.complete(await fn());
      } catch (e, stack) {
        completer.completeError(e, stack);
      }
    });
    return completer.future;
  }
}
