import 'secure_password.dart';
import 'trace.dart';

/// Static configuration for a [SqliteDriver] connection.
///
/// The config deliberately carries no live state: opening, closing and the
/// encryption password are handled by `connect()` / `disconnect()` so the
/// password never has to live longer than a single connect call.
///
/// To use an encrypted database, build the app with an encryption-capable
/// SQLite (recommended: SQLite3MultipleCiphers) via `package:sqlite3` hooks
/// in the *app's* `pubspec.yaml`:
///
/// ```yaml
/// hooks:
///   user_defines:
///     sqlite3:
///       source: sqlite3mc # or: sqlcipher
/// ```
///
/// Then pass a [SecurePassword] to `connect(cipher: ...)`.
final class SqliteDriverConfig {
  /// Absolute database file path, or `null` for a private in-memory database.
  ///
  /// Exposed so callers can export / copy the file themselves while
  /// disconnected.
  final String? path;

  /// Open the file read-only (`SQLITE_OPEN_READONLY`).
  ///
  /// `journalMode` and `synchronous` are skipped in this mode.
  final bool readOnly;

  /// Run `PRAGMA foreign_keys = ON` after opening.
  final bool foreignKeys;

  /// `PRAGMA journal_mode = <journalMode>` after opening (file databases
  /// only, skipped when [readOnly] or in-memory). Defaults to `'WAL'`;
  /// set to `null` to leave the database default untouched.
  final String? journalMode;

  /// `PRAGMA synchronous = <synchronous>` after opening. `null` (default)
  /// leaves the SQLite default (`FULL`); `'NORMAL'` is the usual choice
  /// with WAL.
  final String? synchronous;

  /// `PRAGMA busy_timeout = <busyTimeoutMs>` after opening.
  final int busyTimeoutMs;

  /// Run `PRAGMA cipher_migrate;` after applying the key.
  ///
  /// Only meaningful when upgrading a database encrypted with an older
  /// SQLCipher version. Off by default.
  final bool cipherMigrate;

  /// Custom VFS name passed to `sqlite3.open`. `null` uses the default.
  final String? vfs;

  /// Interpret [path] as a SQLite URI (see https://www.sqlite.org/uri.html).
  final bool uri;

  /// Default password used when `connect()` is called without one.
  ///
  /// Setting this retains the password for the config's lifetime — prefer
  /// passing the password per-`connect()` call and disposing it afterwards.
  final SecurePassword? cipher;

  /// Receives one trace per statement that reaches the database.
  ///
  /// `null` (the default) traces nothing. Pass [ConsoleSqlTrace] to print
  /// the executed SQL, the parameters, the rows returned and the rows
  /// affected to the debug console.
  ///
  /// The sink is called on the isolate that issued the statement, after it
  /// settles. It never sees the encryption password: the key travels to the
  /// worker in the connect handshake and `PRAGMA key` runs inside the worker,
  /// never through a traced statement.
  final SqlTraceSink? onTrace;

  /// Creates a config for a file at [path], or an in-memory database when
  /// [path] is `null`.
  ///
  /// See each field for its default. For a strictly in-memory database use
  /// [SqliteDriverConfig.inMemory] instead.
  const SqliteDriverConfig({
    required this.path,
    this.readOnly = false,
    this.foreignKeys = true,
    this.journalMode = 'WAL',
    this.synchronous,
    this.busyTimeoutMs = 5000,
    this.cipherMigrate = false,
    this.vfs,
    this.uri = false,
    this.cipher,
    this.onTrace,
  });

  /// Private in-memory database living in the background isolate.
  const SqliteDriverConfig.inMemory({
    this.foreignKeys = true,
    this.busyTimeoutMs = 5000,
    this.cipherMigrate = false,
    this.cipher,
    this.onTrace,
  }) : path = null,
       readOnly = false,
       journalMode = null,
       synchronous = null,
       vfs = null,
       uri = false;

  /// `true` when this config describes an in-memory database.
  bool get isInMemory => path == null;

  /// Validates the config early with a clear error instead of a native crash.
  void validate() {
    if (path != null && path!.isEmpty) {
      throw ArgumentError.value(
        path,
        'path',
        'Database path must not be empty.',
      );
    }
    if (busyTimeoutMs < 0) {
      throw ArgumentError.value(
        busyTimeoutMs,
        'busyTimeoutMs',
        'Must not be negative.',
      );
    }
  }
}
