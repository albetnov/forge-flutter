// ignore_for_file: avoid_print

import 'package:fetch_forge/fetch_forge.dart';
import 'package:signals/signals.dart';

/// A stand-in for a real HTTP service.
final class Directory {
  Directory({this.failingCalls = 0});

  /// How many of the first calls fail.
  final int failingCalls;

  /// How many times the service was hit.
  int calls = 0;

  Future<List<String>> users(int page) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (calls <= failingCalls) throw NetworkException('503 on page $page');

    return ['ada', 'grace', 'alan'].map((name) => '$name@$page').toList();
  }
}

/// The kind of error a network call fails with.
final class NetworkException implements Exception {
  NetworkException(this.message);

  final String message;

  @override
  String toString() => 'NetworkException: $message';
}

/// Lets every pending timer and microtask run, the way `pumpEventQueue` does in
/// tests, so the example can print settled state.
Future<void> _drain() => Future<void>.delayed(const Duration(milliseconds: 25));

Future<void> main() async {
  final directory = Directory(failingCalls: 2);

  print('1. Retry a flaky request with exponential backoff.');
  final retry = RetryPolicy.exponentialBackoff(
    maxAttempts: 3,
    initialDelay: const Duration(milliseconds: 10),
  );
  final users = await retry.run(() => directory.users(1));
  print('   ${users.length} users after ${directory.calls} calls.');
  print('');

  print('2. Describe the outcome as one immutable snapshot.');
  AsyncValue<List<String>> snapshot = AsyncValue.idle();
  print('   $snapshot');
  snapshot = AsyncValue.loading();
  print('   $snapshot');
  snapshot = AsyncValue.data(users, isStale: false);
  final verdict = switch (snapshot) {
    AsyncValueIdle() => 'nothing yet',
    AsyncValueLoading(:final previous) => 'refreshing $previous',
    AsyncValueData(:final value) => '${value.length} users',
    AsyncValueError(:final error) => 'failed: $error',
  };
  print('   $snapshot -> $verdict');
  print('');

  print('3. Share results through a client.');
  final client = QueryClient();
  final key = cacheKeyFor((page: 1));
  client.write(key, users);

  final fresh = client.read<List<String>>(key, const Duration(seconds: 30));
  print('   within cacheTime: ${fresh?.data?.length} users');

  final expired = client.read<List<String>>(
    key,
    const Duration(microseconds: 1),
  );
  print('   past cacheTime: ${expired?.data?.length} users');

  client.write(key, users);
  final refreshes = <String>[];
  final unsubscribe = client.onInvalidate(key, () => refreshes.add('page 1'));
  client.invalidate(key);
  print('   invalidate notified: $refreshes');
  unsubscribe();
  client.invalidate(key);
  print('   after unsubscribe:   $refreshes');
  print('');

  print('4. Deduplicate concurrent work for the same key.');
  var started = 0;
  Future<List<String>> load() async {
    started++;
    await Future<void>.delayed(const Duration(milliseconds: 5));

    return ['ada'];
  }

  final key2 = cacheKeyFor((page: 2));
  final both = await Future.wait([
    client.dedupe(key2, load),
    client.dedupe(key2, load),
  ]);
  print('   ${both.map((page) => page.length).toList()} for $started call');
  print('');

  print('5. Query: bind the variables signal, one call to dispose.');
  final api = Directory();
  final page = signal(1);
  final query = Query<List<String>, int>(
    fetcher: api.users,
    client: client,
    staleTime: const Duration(minutes: 5),
  );

  // The binding is the effect you would write by hand — except the query owns
  // it, so `query.dispose()` below stops it too.
  final unbind = query.bind(page);
  await _drain();
  print('   page ${page.value}: ${query.data.value}');

  page.value = 2;
  await _drain();
  print('   page ${page.value}: ${query.data.value}');

  print('   snapshot: ${query.snapshot.value}');
  print('   status:   ${query.status.value}, stale: ${query.isStale.value}');

  page.value = 1;
  await _drain();
  print('   back to page 1 from cache, api calls: ${api.calls}');

  // Stopping the binding leaves the query alive; a manual `refetch` still works.
  unbind();
  print('');

  print('6. setData, invalidate, dispose.');
  query.setData(['seeded'], 7);
  print('   seeded: ${query.data.value}');

  query.invalidate(7);
  await _drain();
  print('   after invalidate: ${query.data.value}');

  query.dispose(); // stops the binding of `page` as well, plus the signals
  print('');

  print('7. Mutation: one write, then the query that reads its result.');
  var reads = 0;
  final userPage = signal(7);
  final shared = QueryClient();
  Future<List<String>> fetchPage(int page) async {
    reads++;
    await Future<void>.delayed(const Duration(milliseconds: 5));

    return ['ada@$page']; // the API knows one user on the page
  }

  final addUser = Mutation<List<String>, int>(
    mutator: (page) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));

      return ['ada@$page', 'grace@$page']; // the write added one
    },
    client: shared,
    cacheDuration: const Duration(minutes: 5),
  );

  final userQuery = Query<List<String>, int>(
    fetcher: fetchPage,
    client: shared,
    staleTime: const Duration(minutes: 5),
  );
  userQuery.bind(userPage);
  await _drain();
  print('   query:  ${userQuery.data.value} (reads: $reads)');

  // Fire and forget: a failure lands on `error`, it never throws here.
  addUser.mutate(7).ignore();
  await _drain();
  print('   write:  ${addUser.data.value}');

  // The cache holds the key now, so a query that has not loaded yet reads the
  // write instead of fetching.
  final reader = Query<List<String>, int>(
    fetcher: fetchPage,
    client: shared,
    staleTime: const Duration(minutes: 5),
  );
  await reader.watch(7);
  print('   reader: ${reader.data.value} (reads: $reads)');

  // Drop the entry and every query watching it refetches — once, because the
  // client hands the same future to both.
  addUser.invalidateCache(7);
  await _drain();
  print('   after invalidateCache: reads: $reads');

  userQuery.dispose();
  reader.dispose();
  addUser.dispose();
  shared.dispose();
  print('');

  print('8. Variables are the cache key, and a list is not a valid one.');
  final listQuery = Query<int, List<int>>(fetcher: (ids) async => ids.length);
  try {
    listQuery.watch([1, 2, 3]);
  } on CacheKeyError catch (error) {
    print('   ${error.toString().split('\n').first}');
  }
}
