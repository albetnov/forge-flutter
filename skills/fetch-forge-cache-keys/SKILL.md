---
name: fetch-forge-cache-keys
description: Variables-are-the-cache-key. Value-equality requirement, CacheKeyError and its debug-only limits, the cacheKey mapper, sharing rules.
---

# Variables are the cache key

The variables value **is** the cache key. Two values are the same request
only when they are `==`: that decides cache hits, dedupe, and what a
shared client shares.

## Good keys

Records, primitives, enums, and classes overriding `==`/`hashCode`:

```dart
await query.watch((page: 1, tag: 'newest')); // record: structural equality
await query.watch(Page(1));                  // value class: overrides ==/hashCode
```

## Bad keys

`List`, `Map`, `Set`, and other `Iterable`s compare by identity, so equal
contents never match and concurrent fetches never dedupe. So do values
not equal to themselves (e.g. `NaN`). These throw `CacheKeyError` with a
fix-it message:

```dart
query.watch([1, 2, 3]); // CacheKeyError in debug builds
```

## The guard and its limits

- **Debug-only assert.** Release builds skip the check to keep hot paths
  allocation-free. It is live in `dart test`, Flutter debug builds, and
  CLI runs with `dart run --enable-asserts` (this toolchain does *not*
  enable asserts for `dart run` by default — pass the flag).
- **Cannot detect a plain class without `==`.** Validation holds one
  instance and has nothing to compare it against, so such a class passes
  the check and then silently never shares. This limitation is
  documented on `cacheKeyFor`: use records or value classes for anything
  identifying a request.

## `cacheKey` mapper

Derive the key when the variables carry a field that must not fork the
cache:

```dart
final q = Query<Page, Filter>(
  fetcher: (f) => api.page(f.page),
  cacheKey: (f) => f.page, // `nonce` no longer forks the cache
);
```

Rules: the mapper's output follows the same equality rules (and is
guarded the same way). Queries — and mutations writing for them — share
entries only when they resolve the same key, so give sharers the same
mapper. `cacheKeyFor(variables, mapper: ...)` is public if a key is ever
needed by hand.
