/// Thrown when query or mutation variables cannot serve as a cache key.
///
/// Cache keys are looked up with `==` and `hashCode`, so a value whose equality
/// is identity-based silently breaks caching: identical requests no longer
/// match and concurrent fetches stop deduplicating. Rather than letting that
/// failure stay silent, this error is raised in debug builds as soon as such a
/// value reaches the cache.
///
/// Fix one of:
/// * pass a Dart record as variables, for example `(page: 1, tag: 'newest')`;
/// * pass a class that overrides `operator ==` and `hashCode`, for example with
///   `freezed` or `built_value`;
/// * map the variables to a hashable value with the `cacheKey` option.
final class CacheKeyError extends Error {
  /// Creates an error for [variables], which cannot be used as a cache key.
  CacheKeyError(this.variables);

  /// The offending value.
  final Object? variables;

  @override
  String toString() {
    final type = variables?.runtimeType ?? 'Null';

    return 'CacheKeyError: variables of type `$type` cannot be used as a cache '
        'key.\n'
        '\n'
        'Query variables are the cache key: two values are the same request '
        'only when they are `==`, which is how a cached result is found and how '
        'concurrent fetches are deduplicated. Lists, maps and sets compare by '
        'identity, so two collections holding the same contents never match '
        'in the cache.\n'
        '\n'
        'Fix one of the following:\n'
        '  * pass a Dart record: (page: 1, tag: "newest")\n'
        '  * pass a class that overrides `operator ==` and `hashCode`, for '
        'example with freezed or built_value\n'
        '  * map the variables onto a hashable value with the `cacheKey` '
        'option\n'
        '\n'
        'Offending value: $variables';
  }
}

/// Returns the structural cache key for [variables].
///
/// By default the variables themselves are the key, which works for any value
/// with structural equality: records, strings, numbers, enums, and value
/// classes that implement `operator ==` and `hashCode`. Pass [mapper] to derive
/// a key from the variables instead, for example when the variables carry a
/// field that must not take part in the comparison.
///
/// The resulting key is validated in debug builds and throws a [CacheKeyError]
/// when it cannot be looked up structurally. The check is a debug-only assert:
/// release builds skip it to keep hot paths allocation free.
///
/// A guard can only catch the footguns it can see: collections and values that
/// are not equal to themselves. A plain class that does not override
/// `operator ==` passes the check, because validation holds a single instance and
/// has nothing to compare it against. Use records or value classes for anything
/// that identifies a request.
///
/// ```dart
/// final key = cacheKeyFor((page: 1, tag: 'newest'));
/// ```
Object? cacheKeyFor<V>(V variables, {Object? Function(V variables)? mapper}) {
  final key = mapper == null ? variables : mapper(variables);

  assert(() {
    _assertCacheKey(key);
    return true;
  }(), 'Query variables must be usable as a structural cache key.');

  return key;
}

void _assertCacheKey(Object? key) {
  // Fast path: the scalars that are always structurally equal.
  if (key == null || key is bool || key is int || key is String) return;

  // A key that is not even equal to itself (a NaN, or a class whose equality
  // depends on mutable state) can never be looked up twice.
  if (key != key) throw CacheKeyError(key);

  // Mutable collections are compared by identity, so two of them never match.
  if (key is Map || key is Iterable || key is Iterator) {
    throw CacheKeyError(key);
  }
}
