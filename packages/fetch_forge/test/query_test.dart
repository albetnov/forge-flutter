import 'dart:async';

import 'package:fetch_forge/fetch_forge.dart';
import 'package:signals/signals.dart';
import 'package:test/test.dart';

/// A clock a test moves by hand, handed to the client that stamps entries.
class _Clock {
  _Clock(this.now);

  DateTime now;

  void advance(Duration duration) => now = now.add(duration);
}

void main() {
  late _Clock clock;

  /// Builds a query with a private cache wired to [clock].
  Query<T, V> query<T, V>(
    Future<T> Function(V variables) fetcher, {
    QueryClient? client,
    RetryPolicy? retry,
    Duration? staleTime,
    Duration? cacheTime,
    Object? Function(V variables)? cacheKey,
    bool enabled = true,
  }) {
    return Query<T, V>(
      fetcher: fetcher,
      client: client ?? QueryClient(clock: () => clock.now),
      retry: retry,
      staleTime: staleTime,
      cacheTime: cacheTime,
      cacheKey: cacheKey,
      enabled: enabled,
    );
  }

  setUp(() => clock = _Clock(DateTime.utc(2026, 1, 1)));

  group('Query lifecycle', () {
    test('starts idle with nothing to show', () {
      final target = query<int, int>((id) async => id);

      expect(target.status.value, QueryStatus.idle);
      expect(target.data.value, isNull);
      expect(target.error.value, isNull);
      expect(target.stackTrace.value, isNull);
      expect(target.isFetching.value, isFalse);
      expect(target.isLoading.value, isFalse);
      expect(target.isSuccess.value, isFalse);
      expect(target.isError.value, isFalse);
      expect(target.isStale.value, isTrue);
      expect(target.snapshot.value, isA<AsyncValueIdle<int>>());
      expect(target.disposed, isFalse);
    });

    test('a settled fetch publishes data and success', () async {
      final target = query<int, int>((id) async => id * 10);

      await target.watch(4);

      expect(target.status.value, QueryStatus.success);
      expect(target.data.value, 40);
      expect(target.isSuccess.value, isTrue);
      expect(target.isFetching.value, isFalse);
      expect(target.error.value, isNull);
      expect(target.snapshot.value, isA<AsyncValueData<int>>());
    });

    test('fetch is watch by another name', () async {
      final target = query<int, int>((id) async => id);

      await target.fetch(1);

      expect(target.status.value, QueryStatus.success);
      expect(target.data.value, 1);
    });

    test('the read counts as loading while the fetch is in flight', () async {
      final gate = Completer<int>();
      final target = query<int, int>((id) async => gate.future);

      final pending = target.watch(1);

      expect(target.status.value, QueryStatus.loading);
      expect(target.isLoading.value, isTrue);
      expect(target.isFetching.value, isTrue);

      gate.complete(1);
      await pending;

      expect(target.isLoading.value, isFalse);
      expect(target.isFetching.value, isFalse);
    });
  });

  group('Query cache', () {
    test('a fresh entry is served without a second call', () async {
      var calls = 0;
      final target = query<int, int>((id) async {
        calls++;

        return id;
      }, staleTime: const Duration(minutes: 5));

      await target.watch(1);
      await target.watch(1);
      await target.fetch(1);

      expect(calls, 1);
      expect(target.data.value, 1);
    });

    test('a stale entry is refetched', () async {
      var calls = 0;
      final target = query<int, int>((id) async {
        calls++;

        return id * calls;
      }, staleTime: const Duration(minutes: 5));

      await target.watch(1);
      expect(target.data.value, 1);

      clock.advance(const Duration(minutes: 6));
      await target.watch(1);

      expect(calls, 2);
      expect(target.data.value, 2);
    });

    test('a null staleTime never skips the fetch', () async {
      var calls = 0;
      final target = query<int, int>((id) async {
        calls++;

        return id;
      });

      await target.watch(1);
      await target.watch(1);

      expect(calls, 2);
    });

    test('an entry older than cacheTime is a miss', () async {
      var calls = 0;
      final target = query<int, int>(
        (id) async {
          calls++;

          return id;
        },
        staleTime: const Duration(minutes: 5),
        cacheTime: const Duration(minutes: 1),
      );

      await target.watch(1);
      expect(calls, 1);

      clock.advance(const Duration(minutes: 2));
      await target.watch(1);

      expect(calls, 2, reason: 'the read decides, no timer ever ran');
    });

    test('a cache hit is indistinguishable from a fetch', () async {
      var calls = 0;
      final target = query<int, int>((id) async {
        calls++;

        return id;
      }, staleTime: const Duration(minutes: 5));

      await target.watch(1);
      clock.advance(const Duration(minutes: 1));
      await target.watch(1);

      expect(calls, 1);
      expect(target.status.value, QueryStatus.success);
      expect(target.data.value, 1);
      expect(target.isFetching.value, isFalse);
      expect(target.isStale.value, isFalse);
    });

    test('refetch ignores a fresh entry', () async {
      var calls = 0;
      final target = query<int, int>((id) async {
        calls++;

        return calls;
      }, staleTime: const Duration(hours: 1));

      await target.watch(1);
      await target.refetch(1);

      expect(calls, 2);
      expect(target.data.value, 2);
    });
  });

  group('Query reactivity', () {
    test('a change in the variables signal refetches', () async {
      final calls = <int>[];
      final target = query<int, int>((id) async {
        calls.add(id);

        return id * 10;
      });
      final page = signal(1);

      final dispose = effect(() => target.watch(page.value).ignore());
      await pumpEventQueue();

      expect(target.data.value, 10);
      expect(calls, [1]);

      page.value = 2;
      await pumpEventQueue();

      expect(target.data.value, 20);
      expect(calls, [1, 2]);

      dispose();
    });

    test('reading status inside an effect subscribes to it', () async {
      final target = query<int, int>((id) async => id);
      final seen = <QueryStatus>[];

      final dispose = effect(() => seen.add(target.status.value));
      await target.watch(1);
      await pumpEventQueue();
      dispose();

      expect(seen, [
        QueryStatus.idle,
        QueryStatus.loading,
        QueryStatus.success,
      ]);
    });

    test('reading snapshot inside a computed derives from it', () async {
      final target = query<int, int>((id) async => id);
      final label = computed(
        () => switch (target.snapshot.value) {
          AsyncValueIdle() => 'idle',
          AsyncValueLoading() => 'loading',
          AsyncValueData(:final value) => 'data:$value',
          AsyncValueError(:final error) => 'error:$error',
        },
      );

      expect(label.value, 'idle');

      await target.watch(1);

      expect(label.value, 'data:1');
    });

    test('two effects watching one key fetch once', () async {
      var calls = 0;
      final target = query<int, int>((id) async {
        calls++;
        await Future<void>.delayed(Duration.zero);

        return id;
      });
      final first = signal(1);
      final second = signal(1);

      final disposeFirst = effect(() => target.watch(first.value).ignore());
      final disposeSecond = effect(() => target.watch(second.value).ignore());
      await pumpEventQueue();

      expect(calls, 1);
      expect(target.data.value, 1);

      disposeFirst();
      disposeSecond();
    });

    test('a disabled query does not fetch', () async {
      var calls = 0;
      final target = query<int, int>((id) async {
        calls++;

        return id;
      }, enabled: false);

      await target.watch(1);

      expect(calls, 0);
      expect(target.status.value, QueryStatus.idle);
      expect(target.snapshot.value, isA<AsyncValueIdle<int>>());
    });

    test('a disabled query does not fetch on invalidation either', () async {
      final client = QueryClient(clock: () => clock.now);
      var calls = 0;
      final target = query<int, int>(
        (id) async {
          calls++;

          return id;
        },
        client: client,
        enabled: false,
      );

      await target.watch(1);
      target.invalidate(1);
      await pumpEventQueue();

      expect(calls, 0);
      expect(target.status.value, QueryStatus.idle);
    });

    test('a disabled query still fetches on demand', () async {
      var calls = 0;
      final target = query<int, int>((id) async {
        calls++;

        return id;
      }, enabled: false);

      await target.refetch(1);

      expect(calls, 1, reason: 'refetch is the explicit override');
      expect(target.data.value, 1);
    });
  });

  group('Query deduplication', () {
    test('concurrent calls for one key share a single fetch', () async {
      var calls = 0;
      final target = query<int, int>((id) async {
        calls++;

        return id;
      });

      await Future.wait([target.watch(1), target.watch(1)]);

      expect(calls, 1);
    });

    test('refetch joins a fetch that is already in flight', () async {
      var calls = 0;
      final target = query<int, int>((id) async {
        calls++;

        return id;
      });

      await Future.wait([target.watch(1), target.refetch(1)]);

      expect(calls, 1);
    });

    test('a settled key can be fetched again', () async {
      var calls = 0;
      final target = query<int, int>((id) async {
        calls++;

        return id;
      });

      await target.watch(1);
      await target.refetch(1);

      expect(calls, 2);
    });

    test('isFetching covers every key in flight', () async {
      final gate = Completer<int>();
      final target = query<int, int>((id) async => id == 1 ? gate.future : id);
      final slow = target.watch(1);

      expect(target.isFetching.value, isTrue);

      final fast = target.watch(2);

      expect(target.isFetching.value, isTrue);

      gate.complete(1);
      await Future.wait([slow, fast]);

      expect(target.isFetching.value, isFalse);
    });
  });

  group('Query errors', () {
    test('watch never throws and lands on the error signal', () async {
      final target = query<int, int>((id) async => throw StateError('nope'));

      await target.watch(1);

      expect(target.status.value, QueryStatus.error);
      expect(target.isError.value, isTrue);
      expect(target.error.value, isA<StateError>());
      expect(target.stackTrace.value, isNotNull);
      expect(target.snapshot.value, isA<AsyncValueError<int>>());
      expect(target.data.value, isNull);
    });

    test('a later success clears the error', () async {
      var calls = 0;
      final target = query<int, int>((id) async {
        calls++;
        if (calls == 1) throw StateError('nope');

        return id;
      });

      await target.watch(1);
      await target.watch(1);

      expect(target.status.value, QueryStatus.success);
      expect(target.error.value, isNull);
      expect(target.stackTrace.value, isNull);
    });

    test('a new fetch clears the error while it is in flight', () async {
      var calls = 0;
      final gate = Completer<int>();
      final target = query<int, int>((id) async {
        calls++;
        if (calls == 1) throw StateError('nope');

        return gate.future;
      });

      await target.watch(1);
      final pending = target.watch(1);

      expect(target.error.value, isNull);
      expect(target.status.value, QueryStatus.loading);
      expect(target.isLoading.value, isTrue);

      gate.complete(1);
      await pending;

      expect(target.status.value, QueryStatus.success);
    });
  });

  group('Query retry', () {
    test('retries up to maxAttempts and surfaces the last error', () async {
      var calls = 0;
      final target = query<int, int>((id) async {
        calls++;
        throw StateError('attempt $calls');
      }, retry: RetryPolicy(maxAttempts: 3, sleep: _instant));

      await target.watch(1);

      expect(calls, 3);
      expect(target.status.value, QueryStatus.error);
      expect((target.error.value as StateError).message, 'attempt 3');
    });

    test('a retried attempt can still succeed', () async {
      var calls = 0;
      final target = query<int, int>((id) async {
        calls++;
        if (calls < 3) throw StateError('nope');

        return id;
      }, retry: RetryPolicy(maxAttempts: 3, sleep: _instant));

      await target.watch(1);

      expect(calls, 3);
      expect(target.data.value, 1);
      expect(target.status.value, QueryStatus.success);
    });

    test('retryIf short-circuits a non-retryable error', () async {
      var calls = 0;
      final target = query<int, int>(
        (id) async {
          calls++;
          throw FormatException('bad request');
        },
        retry: RetryPolicy(
          maxAttempts: 3,
          retryIf: (error) => error is! FormatException,
          sleep: _instant,
        ),
      );

      await target.watch(1);

      expect(calls, 1);
      expect(target.error.value, isA<FormatException>());
    });

    test('the backoff is awaited before the next attempt', () async {
      final waits = <Duration>[];
      final target = query<int, int>(
        (id) async => throw StateError('nope'),
        retry: RetryPolicy(
          maxAttempts: 3,
          sleep: (duration) async => waits.add(duration),
        ),
      );

      await target.watch(1);

      expect(waits, [
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 500),
      ]);
    });
  });

  group('Query staleness', () {
    test('isStale starts true and a fresh read clears it', () async {
      final target = query<int, int>(
        (id) async => id,
        staleTime: const Duration(minutes: 5),
      );

      expect(target.isStale.value, isTrue);

      await target.watch(1);

      expect(target.isStale.value, isFalse);
    });

    test('isStale is true again once the data ages out', () async {
      var calls = 0;
      final gate = Completer<int>();
      final target = query<int, int>(
        (id) async {
          calls++;
          if (calls == 1) return 1;

          return gate.future;
        },
        staleTime: const Duration(minutes: 1),
        cacheTime: const Duration(hours: 1),
      );

      await target.watch(1);
      expect(target.isStale.value, isFalse);

      clock.advance(const Duration(minutes: 2));
      final pending = target.watch(1);

      expect(
        target.isStale.value,
        isTrue,
        reason: 'the data is aged out while the refetch is in flight',
      );

      gate.complete(2);
      await pending;

      expect(target.isStale.value, isFalse);
    });

    test('a snapshot reports stale data as such', () async {
      var calls = 0;
      final gate = Completer<int>();
      final target = query<int, int>(
        (id) async {
          calls++;
          if (calls == 1) return 1;

          return gate.future;
        },
        staleTime: const Duration(minutes: 1),
        cacheTime: const Duration(hours: 1),
      );

      await target.watch(1);
      clock.advance(const Duration(minutes: 2));
      final pending = target.watch(1);

      expect(
        target.snapshot.value,
        isA<AsyncValueLoading<int>>().having(
          (loading) => loading.previous,
          'previous',
          1,
        ),
      );

      gate.complete(2);
      await pending;

      expect(
        target.snapshot.value,
        isA<AsyncValueData<int>>().having(
          (data) => data.isStale,
          'isStale',
          isFalse,
        ),
      );
    });

    test('a null staleTime means always stale', () async {
      final target = query<int, int>((id) async => id);

      await target.watch(1);

      expect(target.isStale.value, isTrue);
      expect((target.snapshot.value as AsyncValueData<int>).isStale, isTrue);
    });
  });

  group('Query keep-last-data', () {
    test('a refetch keeps the data and reports it as previous', () async {
      final gate = Completer<int>();
      var calls = 0;
      final target = query<int, int>((id) async {
        calls++;

        return calls == 1 ? 1 : gate.future;
      });

      await target.watch(1);
      final pending = target.refetch(1);

      expect(target.data.value, 1);
      expect(target.status.value, QueryStatus.loading);
      expect(target.isLoading.value, isFalse);
      expect(
        target.snapshot.value,
        isA<AsyncValueLoading<int>>().having(
          (loading) => loading.previous,
          'previous',
          1,
        ),
      );

      gate.complete(2);
      await pending;

      expect(target.data.value, 2);
      expect(target.snapshot.value, isA<AsyncValueData<int>>());
    });

    test('the first load reports no previous data', () async {
      final gate = Completer<int>();
      final target = query<int, int>((id) async => gate.future);

      final pending = target.watch(1);

      expect(target.isLoading.value, isTrue);
      expect(
        target.snapshot.value,
        isA<AsyncValueLoading<int>>().having(
          (loading) => loading.previous,
          'previous',
          isNull,
        ),
      );

      gate.complete(1);
      await pending;

      expect(target.isLoading.value, isFalse);
    });
  });

  group('Query setData', () {
    test('seeds the signals and the cache', () async {
      final client = QueryClient(clock: () => clock.now);
      var calls = 0;
      final target = query<int, int>(
        (id) async {
          calls++;

          return id;
        },
        client: client,
        staleTime: const Duration(minutes: 5),
      );

      target.setData(42, 1);

      expect(target.status.value, QueryStatus.success);
      expect(target.data.value, 42);
      expect(target.isSuccess.value, isTrue);
      expect(target.error.value, isNull);
      expect(client.read<int>(1, const Duration(minutes: 5))?.data, 42);

      await target.watch(1);

      expect(calls, 0, reason: 'the entry is fresh, so nothing is fetched');
    });

    test('an in-flight fetch still settles on top of the seed', () async {
      final gate = Completer<int>();
      final target = query<int, int>((id) async => id == 2 ? gate.future : 99);

      final pending = target.watch(2);
      target.setData(1, 2);

      gate.complete(99);
      await pending;

      expect(target.data.value, 99);
    });
  });

  group('Query invalidation', () {
    test('invalidate refetches a key that is being watched', () async {
      var calls = 0;
      final client = QueryClient(clock: () => clock.now);
      final target = query<int, int>((id) async {
        calls++;

        return calls;
      }, client: client);

      await target.watch(1);
      expect(calls, 1);

      target.invalidate(1);
      await pumpEventQueue();

      expect(calls, 2);
      expect(target.data.value, 2);
    });

    test('invalidate leaves a key nobody watches alone', () async {
      final client = QueryClient(clock: () => clock.now);
      var untouched = 0;
      var watching = 0;
      final target = query<int, int>((id) async {
        untouched++;

        return id;
      }, client: client);
      final other = query<int, int>((id) async {
        watching++;

        return id;
      }, client: client);

      await other.watch(1);
      target.invalidate(1);
      await pumpEventQueue();

      expect(untouched, 0);
      expect(watching, 2, reason: 'the other query is the one watching');
    });

    test('invalidate marks the read stale before the refetch lands', () async {
      final gate = Completer<int>();
      var calls = 0;
      final client = QueryClient(clock: () => clock.now);
      final target = query<int, int>(
        (id) async {
          calls++;
          if (calls == 1) return 1;

          return gate.future;
        },
        client: client,
        staleTime: const Duration(hours: 1),
      );

      await target.watch(1);
      expect(target.isStale.value, isFalse);

      target.invalidate(1);
      expect(target.isStale.value, isTrue);

      gate.complete(2);
      await pumpEventQueue();

      expect(target.isStale.value, isFalse);
    });

    test('invalidateAll refetches every watched key', () async {
      final calls = <int>[];
      final client = QueryClient(clock: () => clock.now);
      final target = query<int, int>((id) async {
        calls.add(id);

        return id;
      }, client: client);

      await target.watch(1);
      await target.watch(2);
      expect(calls, hasLength(2));

      target.invalidateAll();
      await pumpEventQueue();

      expect(calls..sort(), [1, 1, 2, 2]);
    });

    test('invalidateAll on a shared client refetches every query', () async {
      final client = QueryClient(clock: () => clock.now);
      var firstCalls = 0;
      var secondCalls = 0;
      final first = query<int, int>((id) async {
        firstCalls++;

        return id * 10;
      }, client: client);
      final second = query<int, int>((id) async {
        secondCalls++;

        return id * 10;
      }, client: client);

      await first.watch(1);
      await second.watch(1);

      first.invalidateAll();
      await pumpEventQueue();

      expect(firstCalls, 2);
      expect(secondCalls, 1, reason: 'the client dedupes the in-flight fetch');
      expect(second.data.value, 10, reason: 'the joiner settles from it');
      expect(second.isFetching.value, isFalse);
    });
  });

  group('Query shared cache', () {
    test('two queries share one entry for the same key', () async {
      final client = QueryClient(clock: () => clock.now);
      var calls = 0;
      Future<int> fetcher(int id) async {
        calls++;

        return id;
      }

      final first = query<int, int>(
        fetcher,
        client: client,
        staleTime: const Duration(minutes: 5),
      );
      final second = query<int, int>(
        fetcher,
        client: client,
        staleTime: const Duration(minutes: 5),
      );

      await first.watch(1);
      await second.watch(1);

      expect(calls, 1, reason: 'the shared entry is fresh');
      expect(second.data.value, 1);
    });

    test('a query that joins an in-flight fetch settles from it', () async {
      final client = QueryClient(clock: () => clock.now);
      final gate = Completer<int>();
      var calls = 0;
      Future<int> fetcher(int id) async {
        calls++;
        await gate.future;

        return id * 10;
      }

      final first = query<int, int>(fetcher, client: client);
      final second = query<int, int>(fetcher, client: client);

      // Both watches run their synchronous prefix before anything is
      // awaited, so the second joins while the first is still in flight.
      final Future<void> settling = Future.wait([
        first.watch(1),
        second.watch(1),
      ]);
      expect(second.status.value, QueryStatus.loading);
      expect(second.isFetching.value, isTrue);

      gate.complete(0);
      await settling;

      expect(calls, 1);
      expect(first.data.value, 10);
      expect(second.data.value, 10);
      expect(second.status.value, QueryStatus.success);
      expect(second.isFetching.value, isFalse);
      expect(second.snapshot.value, isA<AsyncValueData<int>>());
    });

    test('a joiner reports the shared failure on its own signals', () async {
      final client = QueryClient(clock: () => clock.now);
      final gate = Completer<int>();
      var calls = 0;
      Future<int> fetcher(int id) async {
        calls++;
        await gate.future;

        throw StateError('offline');
      }

      final first = query<int, int>(fetcher, client: client);
      final second = query<int, int>(fetcher, client: client);

      final Future<void> settling = Future.wait([
        first.watch(1),
        second.watch(1),
      ]);
      gate.complete(0);
      // Both futures complete normally: `watch` never throws, even for the
      // joiner, whose failure lands on its signals instead.
      await settling;

      expect(calls, 1);
      expect(first.status.value, QueryStatus.error);
      expect(second.status.value, QueryStatus.error);
      expect(second.error.value, isStateError);
      expect(second.stackTrace.value, isNotNull);
      expect(second.snapshot.value, isA<AsyncValueError<int>>());
    });

    test('a joiner whose leader is disposed fetches on its own', () async {
      final client = QueryClient(clock: () => clock.now);
      final gate = Completer<int>();
      var calls = 0;
      Future<int> fetcher(int id) async {
        calls++;
        await gate.future;

        return id * 10;
      }

      final first = query<int, int>(fetcher, client: client);
      final second = query<int, int>(fetcher, client: client);

      final Future<void> firstSettling = first.watch(1);
      final Future<void> secondSettling = second.watch(1);
      first.dispose();
      gate.complete(0);
      await firstSettling;
      await secondSettling;
      // The join settled, but the leader discarded its result on dispose, so
      // the joiner fell back to its own fetch in the background.
      await Future<void>.delayed(Duration.zero);

      expect(calls, 2);
      expect(second.data.value, 10);
      expect(second.status.value, QueryStatus.success);
    });

    test('a custom cache key decides what is shared', () async {
      final client = QueryClient(clock: () => clock.now);
      var calls = 0;
      final target = query<String, ({int page, int nonce})>(
        (variables) async {
          calls++;

          return 'page ${variables.page}';
        },
        client: client,
        staleTime: const Duration(minutes: 5),
        cacheKey: (variables) => 'page:${variables.page}',
      );

      await target.watch((page: 1, nonce: 1));
      await target.watch((page: 1, nonce: 2));

      expect(calls, 1);
      expect(target.data.value, 'page 1');
    });
  });

  group('Query cache keys', () {
    test('a key that cannot be compared structurally is refused', () {
      final target = Query<int, List<int>>(
        fetcher: (List<int> ids) async => ids.length,
      );

      expect(() => target.watch([1, 2, 3]), throwsA(isA<CacheKeyError>()));
      expect(() => target.setData(1, [1, 2, 3]), throwsA(isA<CacheKeyError>()));
      expect(() => target.invalidate([1, 2, 3]), throwsA(isA<CacheKeyError>()));
    });

    test('records are the idiomatic key', () async {
      final target = Query<String, ({int page, String tag})>(
        fetcher: (variables) async => '${variables.page}-${variables.tag}',
      );

      await target.watch((page: 1, tag: 'newest'));

      expect(target.data.value, '1-newest');
    });
  });

  group('Query bind', () {
    test(
      'bind fetches at once and refetches when the signal changes',
      () async {
        final calls = <int>[];
        final target = query<int, int>((id) async {
          calls.add(id);

          return id * 10;
        });
        final page = signal(1);

        final stop = target.bind(page);
        await pumpEventQueue();

        expect(calls, [1]);
        expect(target.data.value, 10);

        page.value = 2;
        await pumpEventQueue();

        expect(calls, [1, 2]);
        expect(target.data.value, 20);

        stop();
      },
    );

    test('bind is the effect you would write by hand', () {
      final target = query<int, int>((id) async => id);
      final page = signal(1);

      final bound = target.bind(page);
      final manual = effect(() => target.watch(page.value).ignore());

      expect(bound, isA<EffectCleanup>());
      expect(manual, isA<EffectCleanup>());

      bound();
      manual();
    });

    test('the returned cleanup stops watching but keeps the query', () async {
      final calls = <int>[];
      final target = query<int, int>((id) async {
        calls.add(id);

        return id;
      });
      final page = signal(1);

      final stop = target.bind(page);
      await pumpEventQueue();
      stop();

      page.value = 2;
      await pumpEventQueue();

      expect(calls, [1], reason: 'the effect is gone, so nothing refetches');
      expect(target.disposed, isFalse);

      await target.refetch(2);
      expect(calls, [1, 2], reason: 'the query itself is still alive');
    });

    test('one dispose stops every binding', () async {
      final calls = <int>[];
      final target = query<int, int>((id) async {
        calls.add(id);

        return id;
      });
      final page = signal(1);
      final other = signal(2);

      target.bind(page);
      target.bind(other);
      await pumpEventQueue();
      expect(calls, [1, 2]);

      target.dispose();
      page.value = 3;
      other.value = 4;
      await pumpEventQueue();

      expect(calls, [1, 2], reason: 'both effects stopped with the query');
      expect(target.disposed, isTrue);
    });

    test('binding a disposed query is a no-op', () async {
      final target = query<int, int>((id) async => id);
      final page = signal(1);

      target.dispose();
      final stop = target.bind(page);

      expect(stop, isA<EffectCleanup>());
      expect(() => stop(), returnsNormally);
    });

    test('binding several signals to one query disposes once', () async {
      final target = query<int, int>((id) async => id);
      final page = signal(1);

      final first = target.bind(page);
      final second = target.bind(page);

      first();
      second();
      target.dispose();

      expect(target.disposed, isTrue);
    });
  });

  group('Query disposal', () {
    test('disposing releases the signals', () async {
      final target = query<int, int>((id) async => id);

      await target.watch(1);
      target.dispose();

      expect(target.disposed, isTrue);
      expect(target.status.disposed, isTrue);
      expect(target.data.disposed, isTrue);
      expect(target.snapshot.disposed, isTrue);
      expect(target.isStale.disposed, isTrue);
      expect(target.isFetching.disposed, isTrue);
      expect(target.isLoading.disposed, isTrue);
      expect(target.isSuccess.disposed, isTrue);
      expect(target.isError.disposed, isTrue);
    });

    test(
      'an in-flight fetch settles on a disposed query without throwing',
      () async {
        final gate = Completer<int>();
        final target = query<int, int>((id) async => gate.future);

        final pending = target.watch(1);
        target.dispose();
        gate.complete(1);

        await expectLater(pending, completes);
        await expectLater(target.refetch(1), completes);
        expect(target.disposed, isTrue);
      },
    );

    test('a disposed query stops watching for invalidations', () async {
      final client = QueryClient(clock: () => clock.now);
      var calls = 0;
      final target = query<int, int>((id) async {
        calls++;

        return id;
      }, client: client);

      await target.watch(1);
      target.dispose();
      client.invalidate(1);
      await pumpEventQueue();

      expect(calls, 1);
    });

    test('a shared client outlives the queries that use it', () async {
      final client = QueryClient(clock: () => clock.now);
      final target = query<int, int>((id) async => id, client: client);
      final owned = query<int, int>((id) async => id);

      target.dispose();
      owned.dispose();

      expect(client.disposed, isFalse);
      expect(client.read<int>(1, const Duration(minutes: 5)), isNull);
    });

    test('dispose is idempotent', () async {
      final target = query<int, int>((id) async => id);

      target.dispose();
      target.dispose();

      expect(target.disposed, isTrue);
    });
  });
}

Future<void> _instant(Duration duration) async {}
