---
name: sqlite3-driver-forge-cipher
description: sqlite3mc hook setup, SecurePassword text vs rawKey, connect/changePassword flow, disposal hygiene, auth errors.
---

# Encrypted databases with `SqliteDriver`

Encryption comes from the native build, not this package. Recommended: SQLite3MultipleCiphers (`sqlcipher` also works — the driver only speaks `PRAGMA key`, which both understand). Enable it in the **app's** `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    sqlite3:
      source: sqlite3mc # or: sqlcipher
```

```dart
final password = SecurePassword.text(await loadFromSecureStorage());
try {
  await driver.connect(cipher: password); // or config cipher
} finally {
  password.dispose(); // driver retains nothing; reconnect needs it again
}
await driver.changePassword(SecurePassword.rawKey(new32Bytes));
```

## Configuration

`SecurePassword.text(String)` (KDF password), `.bytes(List<int>)`, `.rawKey(List<int>)` (exactly 32 bytes, preferred). `SqliteDriverConfig(cipherMigrate: true)` runs `PRAGMA cipher_migrate;` after keying — only for upgrades from older SQLCipher DBs, off by default. `changePassword(next)` runs `PRAGMA rekey` + a key probe; the caller still owns `next` (dispose it). A disposed password passed to `connect`/`changePassword` throws `StateError`.

## Instance management

The driver forwards **one copy** of the bytes to the worker per `connect`/`changePassword` and drops its own reference — it never retains password material. The worker zeroes its copy immediately after `PRAGMA key`/`rekey`. Keep passwords in secure storage, load late, `dispose()` early. Raw keys never materialize as a `String` (hex-encoded from bytes); text passwords briefly exist as a `String` in the worker (GC reclaims; unavoidable in Dart).

## Behavior contracts

- **Fail-fast probe.** After keying, the worker runs `SELECT count(*) FROM sqlite_master;` — a wrong key throws `SqlCipherAuthException` at `connect`, not on first use.
- **Hot backup keeps encryption.** `backupTo` (`VACUUM INTO`) on an encrypted DB produces an encrypted copy.

## Caveats / workarounds

- Cipher can't be integration-tested on a plain SQLite build (unknown `PRAGMA key` is ignored there) — test open/query/rekey logic unencrypted, and test auth failure only in an app wired to `sqlite3mc`/`sqlcipher`.
- `PRAGMA key` uses an escaped `'...'` literal (text) or `"x'HEX'"` (raw key) — never interpolate passwords into SQL yourself; pass `SecurePassword` and let the worker quote.
- Never log/print passwords; `copyBytes()` hands you a copy you must zero (`fillRange(0, len, 0)`) when done.
