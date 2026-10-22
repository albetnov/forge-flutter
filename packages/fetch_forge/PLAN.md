# fetch_forge — remaining work

Shipped: `0.3.0` — `Query`, `Mutation`, `AsyncValue`, `QueryClient`,
`RetryPolicy`, `QueryBuilder`, `QueryView`, `MutationBuilder`,
`MutationView`, `QueryScope`, CLI + Flutter examples.
The Flutter layer lives in `lib/src/flutter/` (one file per widget) and
`lib/flutter.dart` is the barrel that re-exports it.
Both builders hand their builder a view — `QueryView` for reads,
`MutationView` for writes — so a widget never owns a query or a mutation by
hand, and the read side can fetch on demand with `autoFetch: false`.
179 tests green via `flutter test`. Everything else in the original brief
is built (including the decided deviations: no `Mutation.snapshot`, bare
`dart test` superseded by `flutter test`, `invalidateCache` instead of the
version-signal recipe, minimal android+web example shells); this file keeps
only what is open.

`dart pub publish --dry-run` passes with 0 warnings for all four workspace
packages, so nothing is left to unblock a release.

## Standing guards

- Signals are the API: every observable is a `ReadonlySignal`; no
  callbacks.
- Core stays pure Dart: no `package:flutter` outside `lib/flutter.dart`.
- No hidden policy: no timers, polling, or lifecycle listeners in core.
- Small surface: no `Mutation.snapshot` and no new widgets without a
  proven gap.
- Variables are the cache key: structural equality, debug-guarded.
- Out of scope — compose from public signals in ~20 lines instead, or
  file the gap as an issue rather than extending core: background
  polling; refetch on resume/focus/reconnect; tag-based invalidation;
  persistence, offline queues, cancellation; bridges to Riverpod/Bloc;
  cache GC timers; GraphQL/codegen.
