# fetch_forge

`fetch_forge` puts remote data behind the same mental model as `signals`: state
is a `ReadonlySignal`, derived state is a `computed`, and reacting is an
`effect`. A fetch becomes a value that lives in the reactive graph instead of a
callback you have to remember to unregister. Everything a query exposes — its
status, its data, its last error — is readable with `.value`, and everything it
does — refetch, invalidate, seed — is a method that writes to those signals.

## Hello world

```dart
import 'package:fetch_forge/fetch_forge.dart';
import 'package:signals/signals.dart';

Future<List<String>> fetchUsers(int page) async => ['ada', 'grace', 'alan'];

Future<void> main() async {
  final users = Query<List<String>, int>(
    fetcher: fetchUsers,
    staleTime: const Duration(seconds: 30),
  );
  final page = signal(1);

  // One line wires the variables signal to the fetch, and `dispose` unwires it.
  users.bind(page);
  await Future<void>.delayed(Duration.zero);
  print(users.snapshot.value); // AsyncValueData(value: [ada, grace, alan], ...)

  page.value = 2; // New variables, new fetch, same binding.
  await Future<void>.delayed(Duration.zero);
  print(users.data.value?.length); // 3

  users.dispose(); // The binding and the signals, together.
}
```

Run the full walkthrough with:

```sh
dart run --enable-asserts example/cli/bin/fetch_forge.dart
```

(`--enable-asserts` turns on the cache-key guard, which is a debug-only check by
design. Flutter debug builds have assertions on already.)

## Install

From pub.dev:

```yaml
dependencies:
  fetch_forge: ^0.1.0
  signals: ^7.0.0
```

From this monorepo:

```yaml
dependencies:
  fetch_forge:
    path: ../fetch_forge
```

## Core concepts

| Type | One sentence |
| --- | --- |
| `Query<T, V>` | A cached, retryable, reactive read: it takes `V → Future<T>` and turns every bit of its progress into a `ReadonlySignal`. |
| `Mutation<T, V>` | A one-shot write: it takes `V → Future<T>` and reports the outcome on `ReadonlySignal`s, optionally caching the result for readers. |
| `AsyncValue<T>` | The sealed snapshot of a request: idle, loading (optionally carrying the previous value), data (with an `isStale` flag), or error, matchable with Dart patterns. |
| `QueryStatus` | The four states a read moves through: `idle`, `loading`, `success`, `error`. |
| `MutationStatus` | The four states a write moves through: `idle`, `pending`, `success`, `error`. |
| `QueryClient` | An optional shared cache keyed by query variables, expired on read rather than by a timer, that deduplicates concurrent work per key. |
| `RetryPolicy` | How a failed call is retried: an attempt cap, a backoff, an optional predicate, and `run` to execute the loop. |
| `CacheEntry<T>` | One cached result: the value, the moment it was written, and an optional expiry set by the writer. |
| `QueryBuilder<T, V>` | A widget that owns a `Query`, binds it to a variables signal and builds from its snapshot; a `refresh` signal forces a refetch. |
| `MutationBuilder<T, V>` | A widget that owns a `Mutation` and builds from its signals; a `trigger` signal starts the write declaratively. |
| `MutationView<T, V>` | The read-only view a `MutationBuilder` hands to its builder: the mutation's signals, the calls that start a write, and the calls that tidy up after it. |
| `QueryScope` | An `InheritedWidget` that shares one `QueryClient` with the builders below it. |
| `cacheKeyFor` | Turns query variables into a cache key, and refuses a key that cannot be compared structurally. |
| `CacheKeyError` | The debug-mode error that tells you exactly which variables are broken and how to fix them. |

## Signals are the API

There is nothing Flutter-specific in `fetch_forge`, and nothing widget-specific
in the data layer: a query's state is ordinary signal state, so `computed` and
`effect` compose with it the way they compose with `int`.

```dart
final query = Query<List<String>, int>(fetcher: fetchUsers);
final page = signal(1);

query.bind(page); // The variables signal drives the fetch. One call, owned.

// Derived state, same as for any other signal.
final names = computed(() => switch (query.snapshot.value) {
      AsyncValueData(:final value) => value,
      _ => const <String>[],
    });

// An effect that re-runs on every change, with no widget in sight.
final prints = effect(() => print('users: ${names.value.length}'));

page.value = 2; // New variables, new fetch, same binding.
query.dispose(); // The binding and the signals, together.
prints();
```

`bind(variables)` is the `effect(() => watch(variables.value).ignore())` line
you would otherwise write by hand, with one difference: the query owns the
effect. That means a binding has one cleanup instead of two — `dispose()`
releases the binding and the signals together, so a caller never has to remember
an `EffectCleanup` alongside the query:

```dart
final query = Query<List<String>, int>(fetcher: fetchUsers);
final page = signal(1);

query.bind(page); // Watches, refetches on change, owned by the query.
page.value = 2; // New variables, new fetch, no extra wiring.
query.dispose(); // The binding and the signals, together.
```

`bind` returns the effect's own cleanup if you want to stop watching while
keeping the query alive — for a manual `refetch`, say. And if you would rather
own the effect yourself, `watch` takes the value directly and every field stays
a `ReadonlySignal`. Either way `watch` and `refetch` complete their futures
normally on failure, so none of this needs a `catchError`.

## Variables and equality

Query variables are the cache key. Two variables are the same request when they
are `==`, which is why the variables type has to be a value type:

```dart
final users = Query<List<String>, ({int page, String tag})>(
  fetcher: (variables) => api.users(variables.page, variables.tag),
);

// A record has structural equality out of the box.
await users.watch((page: 1, tag: 'newest'));

// So does a class that overrides == and hashCode.
final pages = Query<List<String>, Page>(fetcher: (page) => api.pages());
await pages.watch(Page(1));
```

The footgun is identity equality. A `List`, a `Map` or a `Set` compares by
identity, so two collections holding the same contents never match in the cache
and two concurrent fetches for the same page never deduplicate. Rather than
letting that stay silent, the query refuses it in debug builds:

```sh
CacheKeyError: variables of type `List<int>` cannot be used as a cache key.

Query variables are the cache key: two values are the same request only when
they are `==`, which is how a cached result is found and how concurrent fetches
are deduplicated. Lists, maps and sets compare by identity, so two collections
holding the same contents never match in the cache.

Fix one of the following:
  * pass a Dart record: (page: 1, tag: "newest")
  * pass a class that overrides `operator ==` and `hashCode`, for example with
    freezed or built_value
  * map the variables onto a hashable value with the `cacheKey` option
```

When the variables carry a field that must not take part in the comparison, map
them:

```dart
final filtered = Query<Page, Filter>(
  fetcher: (filter) => api.page(filter.page),
  cacheKey: (filter) => filter.page, // `nonce` no longer forks the cache
);
```

The same key decides what a shared [QueryClient] shares: give both queries the
same mapper and they find each other's entries.

## Mutation

A mutation is a one-shot write. It has the same signal shape as a query —
`status`, `data`, `error`, `stackTrace` — but it never fetches on its own,
it is never deduplicated, and its status speaks `pending` instead of
`loading`. There is intentionally no `snapshot`: a write has no staleness,
so branching on `isPending`/`isSuccess`/`isError` is the whole UI.

```dart
final createUser = Mutation<String, String>(
  mutator: (name) async => name,
  cacheDuration: const Duration(minutes: 5),
);

// Fire and forget: the failure lands on `error`, it never throws here.
createUser.mutate('ada').ignore();

// Await the value instead: this one rethrows, like calling the API directly.
final user = await createUser.mutateAsync('ada');
```

`mutate` computes its cache key synchronously, so a bad key throws at the
call site even though the returned future never fails. `mutate` on a
disposed mutation is a silent no-op; `mutateAsync` throws a `StateError`
instead, because it has no result to hand back.

`cacheDuration: null` (the default) means the result is not cached at all.
Pass one and the successful result is written to the client under the
variables' key, where a query reading the same key finds it without
fetching — bounded from the writer's side, so every reader sees the same
expiry. `invalidateCache` drops what the mutation wrote and, through the
client, asks every query watching that key to fetch again:

```dart
final client = QueryClient();
final users = Query<List<String>, int>(fetcher: fetchUsers, client: client);
final createUser = Mutation<String, int>(
  mutator: (page) async => 'grace',
  client: client,
  cacheDuration: const Duration(minutes: 5),
);

await users.watch(1);
await createUser.mutate(1); // the new user is in the cache now
createUser.invalidateCache(1); // ...and the list refetches it
```

That is the "write, then refetch" loop, without the mutation knowing
anything about queries. `invalidateCache()` with no arguments drops every
key this mutation wrote; `reset()` clears the last value and failure while
leaving the cache alone.

## Flutter

The Flutter entrypoint (`package:fetch_forge/flutter.dart`) re-exports
everything on this page and adds three widgets. `QueryBuilder` owns a `Query`,
binds it to a variables signal and rebuilds from its snapshot through
signals; `QueryScope` shares one `QueryClient` with a subtree, so two
builders watching the same variables share one fetch and settle together;
`MutationBuilder` owns a `Mutation` and rebuilds from its signals.

```dart
final page = signal(1);

QueryScope(
  client: client,
  child: QueryBuilder<List<String>, int>(
    fetcher: fetchUsers,
    variables: page,
    staleTime: const Duration(seconds: 30),
    builder: (context, snapshot) => switch (snapshot) {
      AsyncValueData(:final value) => Text(value.join(', ')),
      AsyncValueLoading() => const Text('Loading...'),
      AsyncValueError(:final error) => Text('Failed: $error'),
      AsyncValueIdle() => const Text('Idle'),
    },
  ),
);
```

A `refresh` signal forces a refetch of the current variables when bumped.
When the widget's arguments change — a new fetcher, timings, or variables
signal — the old query no longer describes the request, so the state
disposes it and builds a new one in `didUpdateWidget`. Unmount disposes the
bindings and the query together.

### Writing from a widget

`MutationBuilder` is the same idea for a write: it owns the mutation, hands
its builder a `MutationView` — the mutation's signals plus the calls that
start a write — and disposes everything on unmount.

```dart
MutationBuilder<int, String>(
  mutator: createUser,
  builder: (context, mutation) => ElevatedButton(
    onPressed: () => mutation.mutate('ada').ignore(),
    child: Text(mutation.isPending.value ? 'Saving...' : 'Save'),
  ),
);
```

The builder can also start the write declaratively: a `trigger` signal runs
the write with the current `variables` whenever it is bumped, so a parent
drives the write by bumping a signal instead of wiring a callback. The first
run of the trigger is skipped — a trigger is a bump, not an initial value —
and the variables are read without subscribing, so a variables change alone
never writes.

```dart
final submit = signal(0);
final name = signal('ada');

MutationBuilder<int, String>(
  mutator: createUser,
  variables: name,
  trigger: submit,
  builder: (context, mutation) => Text(
    mutation.isPending.value ? 'Saving...' : 'Save',
  ),
);

submit.value++; // The write runs with `name.value`.
```

A write and a read meet in the shared client: the mutation caches what it
wrote under its key, and `invalidateCache` drops that key and asks every
query watching it to fetch again — the "write, then refetch" loop, with the
mutation knowing nothing about queries.

```dart
QueryScope(
  client: client,
  child: MutationBuilder<List<String>, int>(
    mutator: api.saveUsers,
    cacheDuration: const Duration(minutes: 5),
    builder: (context, mutation) => FilledButton(
      onPressed: () => mutation
          .mutateAsync(page.value)
          .then<void>((_) => mutation.invalidateCache())
          .ignore(),
      child: const Text('Save'),
    ),
  ),
);
```

The query and the mutation use the same variables, so they use the same key.

The layer stays thin: nothing here you couldn't write with `Query` + `bind`
+ `SignalBuilder` in about twenty lines, and the core never imports Flutter.

Run the demo in `example/app` — one shared client, paging, refresh, and a
write that lands in the cache the query reads:

```sh
cd example/app && flutter run -d chrome
```

## Recipes

Four things people ask for on day one, none of which needs library support.

**Optimistic update.** Seed the cache, then let the write fall where it may.

```dart
final page = signal(1);
query.setData([...query.data.value ?? const [], newUser], page.value);

// If the write fails, roll back by seeding again with the previous value.
```

**Invalidate and refetch after a write.** The mutation remembers the keys it
wrote, so invalidating them is one call — and every query watching one
refetches through the shared client.

```dart
final client = QueryClient();
final users = Query<List<String>, int>(fetcher: fetchUsers, client: client);
final createUser = Mutation<String, int>(
  mutator: (page) async => 'grace',
  client: client,
);

void onUserCreated(int page) {
  createUser.invalidateCache(page);
}
```

**Polling while stale.** The core owns no timers, so the timer is yours — and it
only ever asks the query to re-check.

```dart
effect(() {
  if (!query.isStale.value) return;

  query.refetch(page.value).ignore();
});

// Or drive it from a Timer you own:
// Timer.periodic(const Duration(seconds: 30), (_) => query.refetch(2));
```

**Refetch on resume.** No lifecycle listener, because the app already knows when
it resumed.

```dart
final resumed = signal(0);

effect(() {
  resumed.value; // read on purpose
  query.refetch(page.value).ignore();
});

void onAppResumed() => resumed.value++;
```

## What's not included

| Not included | Why |
| --- | --- |
| Background polling | A `Timer` you own plus `refetch` is three lines; a library timer is policy. |
| Refetch on app resume, window focus, network reconnect | All three are a signal bump plus one `effect`, which is why the core has no lifecycle listener to get wrong. |
| Tag-based invalidation (`invalidateQueries(['users'])`) | A version signal plus `invalidate`/`invalidateAll` covers it, without a tag registry in the core. |
| Persistence, offline queues, request cancellation | Each one is a storage engine, a retry queue or an abort signal bolted onto the side; they do not belong behind value equality. |
| Suspense bridges to Riverpod, Bloc, or any other state library | `AsyncValue` is a plain value, so a bridge is a ten-line adapter — and one you should own. |
| Automatic cache GC | Timers are policy. `cacheTime` is checked on read, and `clear` reclaims memory on demand. |
| GraphQL, codegen, or schema awareness | Out of scope by design; the fetcher is any `V → Future<T>`. |

If something cannot be built from the public API in under twenty lines, file an
issue: that is a gap in the API, not a feature to add quietly.

## The Forge umbrella

`fetch_forge` is the remote-data sibling of
[`sqlite_query_forge`](../sqlite_query_forge): both are thin, typed layers over
state you already model with `signals`, and neither invents a new abstraction.
`sqlite_query_forge` turns Dart expressions into bound SQL parameters;
`fetch_forge` turns remote requests into signals. They don't depend on each
other and share only the philosophy: small surface, value types, no hidden
policy.
