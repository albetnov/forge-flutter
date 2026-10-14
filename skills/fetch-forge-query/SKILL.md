---
name: fetch-forge-query
description: Cached, retryable, reactive reads with Query. Constructor config, all ten signals and what each is for, methods, instance management, disposal, behavior contracts, caveats.
---

# `Query<T, V>`

A cached, retryable, reactive read. Takes `V → Future<T>` and turns every
bit of its progress into a `ReadonlySignal`. Import from
`package:fetch_forge/fetch_forge.dart` (pure Dart, no Flutter).

```dart
final users = Query<List<String>, int>(
  fetcher: (page) => api.users(page),
  staleTime: const Duration(seconds: 30),
);
final page = signal(1);

// One line wires the variables signal to the fetch; dispose unwires it.
users.bind(page);
```

## Constructor config

| Param | Meaning |
| --- | --- |
| `fetcher` (required) | `V → Future<T>`, the read. |
| `client` | Shared cache. Omitted: the query owns a private client (which is what lets a bare query dedupe at all). |
| `retry` | `RetryPolicy`. Default never retries — retrying is opt-in. |
| `staleTime` | Freshness window. `null` means always stale (fresh reads never skip the fetch). |
| `cacheTime` | Survival window, checked on read. `null` means until evicted. No timers anywhere. |
| `cacheKey` | Maps variables to a different key (e.g. drop a `nonce` field). Same rules as the variables themselves. |
| `enabled` | Gates fetching. Constructor-only bool with **no public accessor**: the dynamic-enable pattern is a conditional `effect`. |
| `clock` | Injects time. Only valid when no `client` is shared (`assert`: pass the clock to the client that stamps entries, not to every reader). |

## Signals — what each is for

All are `ReadonlySignal`. Read them in `Watch`/`effect`/`computed`; write
only through the methods below.

| Signal | For |
| --- | --- |
| `status` (`QueryStatus`: idle, loading, success, error) | Lifecycle branching. |
| `data` (`T?`) | Last success. Survives refetches and failures; replaced only by a new success or `setData`, cleared never (stays until overwritten). |
| `error` / `stackTrace` | Last settled failure. Cleared at the start of every new fetch. |
| `isFetching` | True while **any** fetch is in flight (counter-based, so two keys in flight keep it true). Use for global spinners. |
| `isLoading` | First-ever load: fetching with no data yet. Use for full-screen spinners vs stale-data badges. |
| `isSuccess` / `isError` | One-line status checks. |
| `isStale` | Older than `staleTime`. Recomputed only when the query observes time — start of `watch`/`refetch`, every settle, `setData`, invalidation. A plain signal, not a `computed`: nothing subscribes to the wall clock. Reading it after a long pause reports the last recomputation. |
| `snapshot` (`AsyncValue<T>`) | The single value for UI: idle / loading (carries `previous` on refetch) / data (with `isStale`) / error. Pattern-match it in builders. |

There is also `disposed` (plain bool).

## Methods

- `watch(v)` — serve the fresh entry, fetch otherwise. **Never throws.**
- `refetch(v)` — always fetch, even disabled. **Never throws.**
- `fetch(v)` — alias of `watch`.
- `setData(value, v)` — seed signals + cache (optimistic updates). An in-flight fetch still settles on top of it.
- `invalidate(v)` — drop the entry, mark stale; refetches only if this query has watched `v` (watched keys are remembered).
- `invalidateAll()` — via the shared client; every watching query refetches.
- `bind(signal)` — owns `effect(() => watch(signal.value).ignore())`. Returns the effect's cleanup (stop watching, keep the query); `dispose()` stops all bindings **and** the signals — one cleanup to remember instead of two.
- `dispose()` — stops bindings, unsubscribes invalidations, disposes signals. Idempotent. In-flight fetches settle silently (results discarded, never throw). A private client is disposed too; a shared one outlives the query.

## Behavior contracts

- **Errors are signals.** `watch`/`refetch` complete normally on failure. `effect(() => query.watch(v).ignore())` needs no `catchError`.
- **Fresh hit ≈ fetch.** A cache hit still moves the query to success and refreshes its own `fetchedAt` — but the *entry's* timestamp never moves. Reads never refresh.
- **Keep-last-data.** Refetch with data held reports `AsyncValueLoading(previous: data)`.
- **Dedupe + join-settle.** Concurrent fetches for one key run once; every caller — including other queries on a shared client — settles its own signals from it (data served from the written entry, failures reported on `error`).
- **`cacheTime` is read-time.** Expiry is evaluated by the read that wants the entry, which drops it.

## Caveats

- The driving effect must read **only the variables**. Never read `status`/`data`/`snapshot` inside the same `effect(() => watch(...))` — that subscribes the effect to the query's own signals and re-triggers it in a loop. Subscribe from a *separate* effect, `computed`, or `Watch`.
- `isStale` does not tick on its own. If UI must show staleness aging, drive a re-check (`watch`/`refetch`) from a timer you own.
- `setData` for a key nobody watches only warms the shared cache — no query moves.
- The cache does not type-check keys: entries written as one `T` must be read as the same `T`.
