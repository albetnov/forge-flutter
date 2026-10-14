/// Errors thrown by [SqliteDriver].
library;

// ignore_for_file: use_super_parameters, SqlCipherAuthException forwards
// resultCode explicitly, so `message` can't be a super parameter.

/// Base class for all errors thrown by the driver.
class SqliteDriverException implements Exception {
  /// Human-readable description of what went wrong.
  final String message;

  /// SQLite extended result code, when the failure came from SQLite itself.
  final int? resultCode;

  const SqliteDriverException(this.message, {this.resultCode});

  @override
  String toString() => resultCode == null
      ? 'SqliteDriverException: $message'
      : 'SqliteDriverException ($resultCode): $message';
}

/// Thrown when an operation is attempted while the driver is not connected.
class SqliteDriverClosedException extends SqliteDriverException {
  const SqliteDriverClosedException([
    super.message = 'Not connected. Call connect() first.',
  ]);
}

/// Thrown when the encryption key is rejected.
///
/// This surfaces when the post-key probe (`SELECT count(*) FROM
/// sqlite_master`) fails, which is how SQLCipher / SQLite3MultipleCiphers
/// reports a wrong key ("file is not a database").
class SqlCipherAuthException extends SqliteDriverException {
  const SqlCipherAuthException([
    String message = 'Encryption key rejected.',
    int? resultCode,
  ]) : super(message, resultCode: resultCode);
}
