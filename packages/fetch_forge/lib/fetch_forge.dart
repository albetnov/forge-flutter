/// Cached, retryable, reactive queries and mutations on top of `signals`.
///
/// `fetch_forge` extends the `signals` mental model to remote data: every piece
/// of state a query exposes is a `ReadonlySignal`, so `signal`, `computed`,
/// `effect` and `Watch` compose with it without a new abstraction to learn.
///
/// This entrypoint is pure Dart. Flutter widgets live in
/// `package:fetch_forge/flutter.dart`, which re-exports everything here.
library;

export 'src/async_value.dart';
export 'src/cache_key.dart';
export 'src/mutation.dart';
export 'src/query.dart';
export 'src/query_client.dart';
export 'src/retry_policy.dart';
export 'src/status.dart';
