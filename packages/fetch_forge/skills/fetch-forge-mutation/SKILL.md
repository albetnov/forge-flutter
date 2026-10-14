---
name: fetch-forge-mutation
description: One-shot writes with Mutation. mutate vs mutateAsync, all seven signals, reset and cache invalidation, cacheDuration sharing, disposal, caveats.
---

# `Mutation<T, V>`

A one-shot write. Same signal shape as a query but never auto-fetches, is
never deduplicated, and speaks `pending` instead of `loading`. Import from
`package:fetch_forge/fetch_forge.dart`.

```dart
final createUser = Mutation<String, String>(
  mutator: (name) => api.createUser(name),
);

// Fire and forget: failure lands on `error`, never throws here.
createUser.mutate('ada').ignore();

// Or await the value: this one rethrows, like calling the API directly.
final user = await createUser.mutateAsync('ada');
```

The constructor's write function is called `mutator` because `mutate` is
taken by the method. Config mirrors a query: `client`, `retry` (default:
never), `cacheDuration`, `cacheKey`, `clock` (same clock-ownership rule).

## Signals — what each is for

All are `ReadonlySignal`. There is intentionally **no `snapshot`**: a write
has no staleness, so branching on the status signals is the whole UI.

| Signal | For |
| --- | --- |
| `status` (`MutationStatus`: idle, pending, success, error) | Lifecycle branching. |
| `data` (`T?`) | Last successful write. Survives a later failure; replaced only by a new success or cleared by `reset`. |
| `error` / `stackTrace` | Last settled failure, cleared at the start of every write. |
| `isPending` | Any write in flight (counter-based: two concurrent writes keep it true). Button spinners subscribe here. |
| `isSuccess` / `isError` | One-line outcome checks. |

There is also `disposed` (plain bool).

## Methods

- `mutate(v)` — run and report on the signals; the future **never fails**.
  The cache key is computed *synchronously*, so a bad key throws
  `CacheKeyError` at the call site (programmer error, not a write
  failure). On a disposed mutation it is a silent no-op.
- `mutateAsync(v)` — run and resolve with the value, rethrowing on
  failure. On a disposed mutation it throws `StateError` immediately
  instead of resolving, because it has no result to hand back.
- `reset()` — back to idle: clears value and failure. The cache is
  untouched — that is `invalidateCache`'s job.
- `invalidateCache([v])` — drop what this mutation wrote (one key with
  `v`, everything without) and notify through the client, so every query
  watching a dropped key refetches. This is the "write, then refetch"
  loop; the mutation knows nothing about queries.
- `dispose()` — disposes signals, forgets written keys. Idempotent.
  In-flight writes settle silently.

## Sharing results with readers

`cacheDuration: null` (default) caches nothing. Otherwise a successful
result is written under the variables' key with that writer-side expiry,
where a query for the same key finds it without fetching. The earlier of
the writer expiry and the reader's `cacheTime` wins. For the loop to
connect, mutation and query must share the `client` **and** the same
`cacheKey` mapper.

## Caveats

- Writes are never deduplicated: two concurrent `mutate` calls run two
  writes. `isPending` covers all of them.
- Do not drive `mutate` from an `effect` that also reads the mutation's
  own signals — same subscription-loop rule as queries. An auto-save
  effect must read only its trigger signals.
- `invalidateCache` only drops keys *this mutation* wrote. To clear
  unrelated entries use the client's `invalidate`/`invalidateAll`.
- `data` from a previous success is still visible while a new write is
  pending and after it fails — check `status`/`isPending` before
  treating `data` as the latest outcome.
