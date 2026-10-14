---
name: fetch-forge-client-retry
description: Supporting types. QueryClient read-time cache and invalidation, CacheEntry expiry, RetryPolicy configuration, AsyncValue snapshots.
---

# Supporting types

## `QueryClient` — the shared cache

Hand one client to every query (and mutation) that should share results.
No timers: entries expire only when read.

- `read<T>(key, cacheTime)` — hit or `null`. Drops the entry when older
  than the caller's `cacheTime` **or** past the entry's own `expiresAt`,
  whichever comes first. Expiry is strictly *after* the boundary. `null`
  `cacheTime` never expires. Never refreshes timestamps.
- `write<T>(key, value, {expiresIn})` — stamp with the client's clock.
  `expiresIn` bounds the result writer-side for every reader.
- `invalidate(key)` — evict **and notify** listeners (watching queries
  refetch). Notified even with no entry present: the point is staleness.
- `invalidateAll()` — clear everything, notify every listened key.
- `clear()` — evict **silently** (reclaim memory, e.g. test teardown).
- `dedupe(key, task)` — first caller runs, concurrent callers get the
  same future; bookkeeping is forgotten on settle.
- `onInvalidate(key, listener)` — subscribe, returns the unsubscriber.
  How a mutation's invalidation reaches queries without the client knowing
  queries exist.
- `dispose()` — clear entries, drop in-flight bookkeeping and listeners.
  Keeps working degraded afterwards (misses, ignored writes), so settling
  work cannot fail on it. A query disposes only a client it created
  itself; a shared client outlives its queries.
- `QueryClient(clock:)` — inject time in tests; move it by hand to pin
  staleness and expiry deterministically.

## `CacheEntry<T>`

`data`, `fetchedAt` (client-clock stamp), `expiresAt` (writer bound,
`null` = caller's `cacheTime` alone decides).

## `RetryPolicy` — inert data plus `run`

Retrying is opt-in: the default policy (`maxAttempts: 1`, also available
as `RetryPolicy.none`) never retries.

- `maxAttempts` counts the **first** attempt (`3` = at most two retries).
- `delay(attempt, error)` is **1-indexed** (attempt 1 = the failure before
  the 2nd try). Default backoff: 250ms doubling, capped at 30s.
- `retryIf(error)` short-circuits: `false` surfaces immediately even with
  attempts left. Only consulted when a retry would actually happen.
- `exponentialBackoff(maxAttempts: 3, initialDelay: 1s, factor: 2,
  maxDelay: 30s)` is the ready-made constructor.
- `run(task)` awaits the whole loop; the last error surfaces with its
  stack trace. `sleep` is injectable (default `Future.delayed`) so tests
  assert durations without virtual time. One instance is shareable across
  operations.

## `AsyncValue<T>` — the snapshot

Sealed, four `const`-constructible cases, exhaustive under `switch`:

```dart
switch (snapshot) {
  AsyncValueIdle() => ...,
  AsyncValueLoading(:final previous) => previous == null ? 'loading' : 'refreshing',
  AsyncValueData(:final value, :final isStale) => ...,
  AsyncValueError(:final error, :final stackTrace) => ...,
}
```

Cases are named `AsyncValue*` (not `AsyncData`/`AsyncLoading`/`AsyncError`)
because `package:signals` exports those names for its own hierarchy — both
packages must stay importable together. Deliberately no `==`: snapshots
are moments in time, compare payloads. Factories `AsyncValue.idle()`,
`.loading(previous:)`, `.data(value)`, `.error(e, st)` also exist.
