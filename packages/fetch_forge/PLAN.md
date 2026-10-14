# fetch_forge — remaining work

Shipped: `0.1.0` — `Query`, `Mutation`, `AsyncValue`, `QueryClient`,
`RetryPolicy`, `QueryBuilder`, `QueryScope`, CLI + Flutter examples.
167 tests green via `flutter test`. Everything else in the original brief
is built (including the decided deviations: no `Mutation.snapshot`, bare
`dart test` superseded by `flutter test`, `invalidateCache` instead of the
version-signal recipe, minimal android+web example shells); this file keeps
only what is open.

## Open decisions

1. **LICENSE vs `dart pub publish --dry-run`.** `LICENSE` was removed at
   the human's instruction and `publish_to` is `none`, but pub still
   hard-errors without a `LICENSE` file — so definition-of-done item 1
   cannot pass. Either restore `LICENSE` or formally drop that item.

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
