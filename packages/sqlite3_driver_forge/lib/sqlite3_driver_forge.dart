/// Background-isolate driver over `package:sqlite3` for the forge packages.
///
/// Owns the connection lifecycle on a dedicated worker isolate and exposes
/// one object implementing both `ForgeExecutor` (`sqlite_query_forge`) and
/// `DatabaseExecutor` (`sqlite_schema_forge`).
library;

export 'src/config.dart';
export 'src/driver.dart';
export 'src/exceptions.dart';
export 'src/secure_password.dart';
