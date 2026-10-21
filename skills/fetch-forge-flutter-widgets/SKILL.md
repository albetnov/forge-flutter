---
name: fetch-forge-flutter-widgets
description: Flutter layer. QueryBuilder and MutationBuilder props and lifecycle, QueryScope sharing, refresh and trigger signals, disposal, thin-layer rule and testing.
---

# Flutter layer

Import `package:fetch_forge/flutter.dart` (re-exports the core). The core
never imports Flutter — keep it that way. The layer is optional sugar over
`Query` + `bind` + `SignalBuilder`; do not add policy (timers, lifecycle
listeners) to it.

## `QueryBuilder<T, V>`

Owns a `Query`, binds it to a variables signal, rebuilds from its snapshot.

```dart
QueryScope(
  client: client,
  child: QueryBuilder<List<String>, int>(
    fetcher: fetchUsers,
    variables: page,           // ReadonlySignal<int>: new value refetches
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

| Prop | Meaning |
| --- | --- |
| `fetcher`, `variables`, `builder` (required) | Async fn, variables signal, `Widget Function(BuildContext, AsyncValue<T>)`. |
| `client` | Shared cache. Default: nearest `QueryScope`. Neither: private client owned by the query. |
| `retry`, `staleTime`, `cacheTime`, `cacheKey`, `enabled` | Passed straight to the owned query. |
| `refresh` (`ReadonlySignal<Object?>?`) | Any bump refetches the **current** variables — even while `enabled` is `false` (explicit-`refetch` semantics). Only the bump matters, not the value. |

Lifecycle: created + bound in `didChangeDependencies` (scope must be
readable); any argument change except `builder` disposes the old query and
builds a new one in `didUpdateWidget`; unmount stops the refresh effect
and disposes the query (bindings go with it). Rebuilds go through
`SignalBuilder` with the **named** `builder` parameter (signals v7 API);
`Watch` is deprecated — do not use it in new code.

## `QueryScope`

`InheritedWidget` sharing one client with descendant builders. `maybeOf`
returns `null` without a scope (builder then owns a private cache); `of`
throws a descriptive `StateError`. `updateShouldNotify` fires on client
identity change, which rebuilds consumers' queries. The scope never
disposes the client — the creator owns it (app-lifetime is fine).

## `MutationBuilder<T, V>`

Owns a `Mutation` and rebuilds from its signals. The builder callback gets a
`MutationView<T, V>`, not the mutation itself: the view carries the signals
(`status`, `data`, `error`, `stackTrace`, `isPending`, `isSuccess`,
`isError`) and the calls (`mutate`, `mutateAsync`, `reset`,
`invalidateCache`), and hides `dispose` so the widget-owned mutation cannot
be killed from outside.

```dart
MutationBuilder<int, String>(
  mutator: createUser,
  builder: (context, mutation) => ElevatedButton(
    onPressed: () => mutation.mutate('ada').ignore(),
    child: Text(mutation.isPending.value ? 'Saving...' : 'Save'),
  ),
);
```

| Prop | Meaning |
| --- | --- |
| `mutator`, `builder` (required) | Async fn, `Widget Function(BuildContext, MutationView<T, V>)`. |
| `client` | Shared cache. Default: nearest `QueryScope`. Neither: private client owned by the mutation. |
| `retry`, `cacheDuration`, `cacheKey` | Passed straight to the owned mutation. |
| `variables` (`ReadonlySignal<V>?`) | The variables a `trigger` runs the write with. Read with `peek`, so a change never writes on its own. |
| `trigger` (`ReadonlySignal<Object?>?`) | Any bump starts the write with the current `variables`. Requires `variables`. The first run is skipped — a trigger is a bump, not an initial value. |

Two ways to start a write: the builder calls `mutation.mutate(...)`, or a
parent bumps `trigger` and the widget writes with the current `variables`.
Both are available at the same time.

Lifecycle: created in `didChangeDependencies` (scope must be readable);
`mutator`, `client`, `retry`, `cacheDuration` or `cacheKey` changing
identity disposes the old mutation and builds a new one in
`didUpdateWidget`; changing `builder`, `variables` or `trigger` keeps the
mutation, so its state and result survive. Unmount stops the trigger effect
and disposes the mutation. Rebuilds go through `SignalBuilder` with the
**named** `builder` parameter and `dependencies` on `status`, `data` and
`error`, so the subtree rebuilds on every state change.

## Notes for agents

- Fetchers must be referentially stable. `QueryBuilder` recreates its
  query whenever `fetcher` changes identity (`didUpdateWidget`), and a
  fresh query starts with no data — so an inline closure as `fetcher`
  refetches from a cold snapshot on every parent rebuild. In a form that
  rebuilds per keystroke, typing flashes the whole subtree back to
  loading. Pass a top-level function or a method tear-off; only `builder`
  may be an inline closure.
- The same holds for `mutator`: a new identity restarts the write from
  idle. Keep it referentially stable too.
- Two builders under one scope watching one key produce **one** network
  call and both settle — that is the canonical scope test.
- The refresh effect skips its first run (binding already fetched) and
  reads variables via `peek`, subscribing to nothing but the refresh.
- Keep-last-data works through the builder: refetch renders
  `AsyncValueLoading(previous:)` — show stale rows plus a refresh marker,
  not a full spinner.
- Test with `flutter_test`: `pumpWidget`, assert loading, `pumpAndSettle`,
  assert data; bump signals then `pumpAndSettle` again; unmount via
  `pumpWidget` of a placeholder and assert no further fetches.
