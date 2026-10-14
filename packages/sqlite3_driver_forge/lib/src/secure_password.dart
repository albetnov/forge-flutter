import 'dart:convert';
import 'dart:typed_data';

/// Holds database encryption password material with explicit lifetime control.
///
/// Dart strings are immutable and the GC may copy memory around, so a password
/// can never be *guaranteed* erased. This class minimizes the risk window:
///
/// - Passwords are stored as mutable bytes ([Uint8List]), never as retained
///   [String]s. Call [dispose] to synchronously zero the bytes when done.
/// - The driver only borrows the bytes for the duration of `connect()` /
///   `changePassword()`: it sends one copy to the background isolate (which
///   zeroes its copy immediately after running `PRAGMA key`) and never
///   retains them afterwards. Reconnecting requires passing the password again.
/// - Prefer [SecurePassword.rawKey] (a 32-byte random key, e.g. from
///   `Random.secure()` stored in secure storage) over text passwords: raw keys
///   are hex-encoded straight from bytes and never decoded into a [String].
///   Text passwords ([SecurePassword.text]) must briefly exist as a [String]
///   inside the worker to run `PRAGMA key = '...'`; the reference is dropped
///   immediately after, but only GC removes the memory.
///
/// Basic hygiene still applies: never log or print passwords, load them from
/// secure storage (e.g. flutter_secure_storage) only when connecting, and
/// [dispose] them as soon as the connection is established if you will not
/// reconnect later.
final class SecurePassword {
  Uint8List _bytes;
  final bool _rawKey;
  bool _disposed = false;

  SecurePassword._(this._bytes, this._rawKey);

  /// Text password (runs through the cipher KDF via `PRAGMA key = '...'`).
  ///
  /// The input [password] String itself cannot be zeroed; drop your reference
  /// to it after calling this factory.
  factory SecurePassword.text(String password) =>
      SecurePassword._(Uint8List.fromList(utf8.encode(password)), false);

  /// Raw 32-byte encryption key (used as `PRAGMA key = "x'HEX'"`).
  ///
  /// This is the preferred form: no password string is ever materialized.
  /// Generate with `Random.secure()` and persist in secure storage.
  factory SecurePassword.rawKey(List<int> keyBytes) {
    if (keyBytes.length != 32) {
      throw ArgumentError.value(
        keyBytes.length,
        'keyBytes',
        'Raw keys must be exactly 32 bytes.',
      );
    }
    return SecurePassword._(Uint8List.fromList(keyBytes), true);
  }

  /// Copies from existing bytes (e.g. read from secure storage).
  factory SecurePassword.bytes(List<int> bytes) =>
      SecurePassword._(Uint8List.fromList(bytes), false);

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// Whether this holds a raw key ([SecurePassword.rawKey]).
  bool get isRawKey => _rawKey;

  void _ensure() {
    if (_disposed) {
      throw StateError('SecurePassword has been disposed.');
    }
  }

  /// Returns an independent copy of the bytes.
  ///
  /// The caller owns the copy and should zero it (`fillRange(0, len, 0)`)
  /// when done.
  Uint8List copyBytes() {
    _ensure();
    return Uint8List.fromList(_bytes);
  }

  /// Zeroes the held bytes. The instance must not be used afterwards.
  void dispose() {
    if (!_disposed) {
      _disposed = true;
      _bytes.fillRange(0, _bytes.length, 0);
    }
  }
}
