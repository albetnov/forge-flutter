/// Wire protocol between [SqliteDriver] and the background isolate.
///
/// Kept to primitives + `Uint8List` so every message is isolate-transferable.
/// This file is internal; the only public member is [sqliteDriverWorkerEntry],
/// which must stay a top-level function so it can be used with
/// `Isolate.spawn`.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

// ---------------------------------------------------------------------------
// Message keys (main -> worker init).
// ---------------------------------------------------------------------------

const String _kPort = 'port';
const String _kPath = 'path';
const String _kReadOnly = 'readOnly';
const String _kForeignKeys = 'foreignKeys';
const String _kJournalMode = 'journalMode';
const String _kSynchronous = 'synchronous';
const String _kBusyTimeoutMs = 'busyTimeoutMs';
const String _kCipherMigrate = 'cipherMigrate';
const String _kVfs = 'vfs';
const String _kUri = 'uri';
const String _kKeyBytes = 'keyBytes';
const String _kKeyIsRaw = 'keyIsRaw';

// ---------------------------------------------------------------------------
// Message keys (requests / responses).
// ---------------------------------------------------------------------------

const String _kId = 'id';
const String _kOp = 'op';
const String _kSql = 'sql';
const String _kArgs = 'args';
const String _kDest = 'dest';

/// Request ops understood by the worker.
abstract final class WorkerOp {
  /// `SELECT` returning result rows.
  static const String query = 'query';

  /// A statement with no result rows.
  static const String execute = 'execute';

  /// `INSERT` returning the last row id and the change count.
  static const String insert = 'insert';

  /// `VACUUM INTO` online backup to a destination path.
  static const String backup = 'backup';

  /// Re-key the (encrypted) database.
  static const String rekey = 'rekey';

  /// Close the connection and stop the worker.
  static const String close = 'close';
}

/// Error codes sent back with `ok: false`.
abstract final class WorkerError {
  /// A [SqliteException] from SQLite itself.
  static const String sqlite = 'sqlite';

  /// The encryption key was rejected (wrong password / not a database).
  static const String cipherAuth = 'cipher_auth';

  /// Bad request shape (unknown op, bad arg types, ...).
  static const String args = 'args';
}

const String _kOk = 'ok';
const String _kRows = 'rows';
const String _kChanges = 'changes';
const String _kLastId = 'lastId';
const String _kCode = 'code';
const String _kMessage = 'message';
const String _kResultCode = 'resultCode';
const String _kType = 'type';
const String _kReady = 'ready';
const String _kPortMsg = 'port';
const String _kError = 'error';

/// Builds the isolate-spawn message. Exported for tests; not public API.
Map<String, Object?> buildWorkerInit({
  required SendPort replyTo,
  required String? path,
  required bool readOnly,
  required bool foreignKeys,
  required String? journalMode,
  required String? synchronous,
  required int busyTimeoutMs,
  required bool cipherMigrate,
  required String? vfs,
  required bool uri,
  required Uint8List? keyBytes,
  required bool keyIsRaw,
}) => <String, Object?>{
  _kPort: replyTo,
  _kPath: path,
  _kReadOnly: readOnly,
  _kForeignKeys: foreignKeys,
  _kJournalMode: journalMode,
  _kSynchronous: synchronous,
  _kBusyTimeoutMs: busyTimeoutMs,
  _kCipherMigrate: cipherMigrate,
  _kVfs: vfs,
  _kUri: uri,
  _kKeyBytes: keyBytes,
  _kKeyIsRaw: keyIsRaw,
};

/// Escapes [value] for embedding in a single-quoted SQL literal.
///
/// Hex literals (`x'...'`) are used for raw keys instead, so this only ever
/// sees file paths and text passwords.
String quoteLiteral(String value) => "'${value.replaceAll("'", "''")}'";

/// Entry point for the background isolate that owns the SQLite connection.
///
/// Opens the database, applies the key + pragmas, acknowledges readiness,
/// then serves requests sequentially on its own `ReceivePort`.
void sqliteDriverWorkerEntry(Map<String, Object?> init) {
  final toMain = init[_kPort] as SendPort;
  final inbox = ReceivePort();
  // Hand the main isolate our SendPort first so it can always reach us,
  // even if opening the database below fails.
  toMain.send({_kType: _kPortMsg, _kPort: inbox.sendPort});

  Database? db;
  try {
    db = _openDatabase(init);
    toMain.send({_kType: _kReady});
  } catch (e) {
    toMain.send({_kType: _kError, _kMessage: _describe(e), _kCode: _codeOf(e)});
    inbox.close();
    return;
  }

  final database = db;
  inbox.listen((dynamic message) {
    final request = (message as Map).cast<String, Object?>();
    final id = request[_kId] as int;
    try {
      toMain.send(
        <String, Object?>{_kId: id, _kOk: true}
          ..addAll(_handle(database, request)),
      );
    } catch (e) {
      toMain.send(<String, Object?>{
        _kId: id,
        _kOk: false,
        _kCode: _codeOf(e),
        _kMessage: _describe(e),
        _kResultCode: e is SqliteException ? e.extendedResultCode : null,
      });
    }
  });
}

Database _openDatabase(Map<String, Object?> init) {
  final path = init[_kPath] as String?;
  final readOnly = init[_kReadOnly] as bool? ?? false;
  final vfs = init[_kVfs] as String?;
  final uri = init[_kUri] as bool? ?? false;

  final Database db;
  if (path == null) {
    db = sqlite3.openInMemory(vfs: vfs);
  } else {
    db = sqlite3.open(
      path,
      mode: readOnly ? OpenMode.readOnly : OpenMode.readWriteCreate,
      vfs: vfs,
      uri: uri,
    );
  }

  try {
    final keyBytes = init[_kKeyBytes] as Uint8List?;
    final keyIsRaw = init[_kKeyIsRaw] as bool? ?? false;
    if (keyBytes != null) {
      _applyKey(db, keyBytes, keyIsRaw);
      if (init[_kCipherMigrate] as bool? ?? false) {
        db.execute('PRAGMA cipher_migrate;');
      }
      // Fail fast on a wrong key instead of surfacing it on first use.
      _probeKey(db);
    }

    db.execute(
      'PRAGMA busy_timeout = ${init[_kBusyTimeoutMs] as int? ?? 5000};',
    );
    if (init[_kForeignKeys] as bool? ?? true) {
      db.execute('PRAGMA foreign_keys = ON;');
    }
    if (!readOnly && path != null) {
      final journalMode = init[_kJournalMode] as String?;
      if (journalMode != null && journalMode.isNotEmpty) {
        db.execute('PRAGMA journal_mode = $journalMode;');
      }
      final synchronous = init[_kSynchronous] as String?;
      if (synchronous != null && synchronous.isNotEmpty) {
        db.execute('PRAGMA synchronous = $synchronous;');
      }
    }
  } catch (_) {
    db.close();
    rethrow;
  }
  return db;
}

/// Runs `PRAGMA key` and zeroes [keyBytes] before returning.
///
/// Raw keys are hex-encoded straight from bytes (no password string ever
/// exists). Text passwords are UTF-8 decoded and SQL-escaped; the decoded
/// string reference is dropped immediately after use — only the GC can
/// reclaim the memory, which is documented on [SecurePassword].
void _applyKey(Database db, Uint8List keyBytes, bool raw) {
  final String literal;
  if (raw) {
    final hex = StringBuffer();
    for (var i = 0; i < keyBytes.length; i++) {
      hex.write(keyBytes[i].toRadixString(16).padLeft(2, '0'));
    }
    keyBytes.fillRange(0, keyBytes.length, 0);
    literal = '"x\'$hex\'"';
  } else {
    late String password;
    try {
      password = utf8.decode(keyBytes, allowMalformed: false);
    } finally {
      keyBytes.fillRange(0, keyBytes.length, 0);
    }
    literal = quoteLiteral(password);
    // Drop the reference; GC reclaims the memory when it can.
    password = '';
  }
  db.execute('PRAGMA key = $literal;');
}

/// A key probe: encrypted stores throw "file is not a database" here when
/// the key is wrong. Cheap on plain databases too.
void _probeKey(Database db) {
  try {
    db.select('SELECT count(*) FROM sqlite_master;');
  } on SqliteException catch (e) {
    throw _CipherAuthFailure(
      'Encryption key rejected (${e.message}).',
      e.extendedResultCode,
    );
  }
}

Map<String, Object?> _handle(Database db, Map<String, Object?> request) {
  final op = request[_kOp] as String?;
  switch (op) {
    case WorkerOp.query:
      final result = db.select(
        request[_kSql] as String,
        _castArgs(request[_kArgs]),
      );
      return {
        _kRows: [for (final row in result) Map<String, Object?>.from(row)],
      };
    case WorkerOp.execute:
      db.execute(request[_kSql] as String, _castArgs(request[_kArgs]));
      return {_kChanges: db.updatedRows};
    case WorkerOp.insert:
      db.execute(request[_kSql] as String, _castArgs(request[_kArgs]));
      return {_kLastId: db.lastInsertRowId, _kChanges: db.updatedRows};
    case WorkerOp.backup:
      final dest = request[_kDest] as String?;
      if (dest == null || dest.isEmpty) {
        throw const _BadRequest('Backup destination path must not be empty.');
      }
      // Online-safe: runs on the live connection, keeps encryption as-is.
      db.execute('VACUUM INTO ${quoteLiteral(dest)};');
      return {};
    case WorkerOp.rekey:
      final keyBytes = request[_kKeyBytes] as Uint8List?;
      if (keyBytes == null) {
        throw const _BadRequest('Missing key material for rekey.');
      }
      final raw = request[_kKeyIsRaw] as bool? ?? false;
      _rekey(db, keyBytes, raw);
      _probeKey(db);
      return {};
    case WorkerOp.close:
      db.close();
      return {};
    default:
      throw _BadRequest('Unknown op: $op.');
  }
}

void _rekey(Database db, Uint8List keyBytes, bool raw) {
  // Same literal rules as _applyKey, against PRAGMA rekey.
  if (raw) {
    final hex = StringBuffer();
    for (var i = 0; i < keyBytes.length; i++) {
      hex.write(keyBytes[i].toRadixString(16).padLeft(2, '0'));
    }
    keyBytes.fillRange(0, keyBytes.length, 0);
    db.execute('PRAGMA rekey = "x\'$hex\'";');
  } else {
    late String password;
    try {
      password = utf8.decode(keyBytes, allowMalformed: false);
    } finally {
      keyBytes.fillRange(0, keyBytes.length, 0);
    }
    db.execute('PRAGMA rekey = ${quoteLiteral(password)};');
    // Drop the reference; GC reclaims the memory when it can.
    password = '';
  }
}

List<Object?> _castArgs(Object? args) {
  if (args == null) return const [];
  final list = (args as List).cast<Object?>();
  for (final arg in list) {
    if (arg == null ||
        arg is bool ||
        arg is int ||
        arg is double ||
        arg is String ||
        arg is Uint8List) {
      continue;
    }
    throw _BadRequest(
      'Unsupported argument type ${arg.runtimeType}; '
      'use null, bool, int, double, String or Uint8List.',
    );
  }
  return list;
}

String _describe(Object? e) => e.toString();

String _codeOf(Object? e) {
  if (e is _CipherAuthFailure) return WorkerError.cipherAuth;
  if (e is _BadRequest) return WorkerError.args;
  if (e is SqliteException) return WorkerError.sqlite;
  return WorkerError.sqlite;
}

/// Wrong-key probe failure. Never leaves the worker; mapped to [SqlCipherAuthException].
final class _CipherAuthFailure implements Exception {
  final String message;
  final int? resultCode;
  const _CipherAuthFailure(this.message, this.resultCode);
  @override
  String toString() => 'CipherAuthFailure: $message';
}

/// Malformed request. Never leaves the worker; mapped to [ArgumentError].
final class _BadRequest implements Exception {
  final String message;
  const _BadRequest(this.message);
  @override
  String toString() => 'BadRequest: $message';
}
