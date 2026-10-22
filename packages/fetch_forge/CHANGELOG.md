## 0.2.1

- Internal only: the Flutter layer moved out of `lib/flutter.dart` into one
  file per widget under `lib/src/flutter/` (`query_scope.dart`,
  `query_builder.dart`, `mutation_builder.dart`), and `lib/flutter.dart` is
  now a barrel that re-exports the core and those files. No API change, no
  behavior change — the same names, signatures and docs, imported the same
  way as before.

## 0.2.0

- `MutationBuilder<T, V>`: a Flutter widget that owns a `Mutation` and
  rebuilds from its signals. Its builder receives a `MutationView<T, V>` —
  the mutation's signals plus the calls that start a write — and an optional
  `trigger` signal starts the write declaratively with the current
  `variables`.

## 0.1.0

- Initial release in the `the_forge_ecosystem` monorepo (reset from prior
  standalone versioning).
- Cached, retryable, reactive remote data on top of `signals`: `Query`,
  `Mutation`, `AsyncValue`, `QueryClient`, `RetryPolicy`, plus the Flutter
  `QueryBuilder` / `QueryScope` layer.
