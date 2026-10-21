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
