import 'dart:async';

import 'package:fetch_forge/fetch_forge.dart';
import 'package:test/test.dart';

/// A clock a test moves by hand, handed to the client that stamps entries.
class _Clock {
  _Clock(this.now);

  DateTime now;

  void advance(Duration duration) => now = now.add(duration);
}

void main() {
  late _Clock clock;

  /// Builds a mutation with a private cache wired to [clock].
  Mutation<T, V> mutation<T, V>(
    Future<T> Function(V variables) mutator, {
    QueryClient? client,
    RetryPolicy? retry,
    Duration? cacheDuration,
    Object? Function(V variables)? cacheKey,
  }) {
    return Mutation<T, V>(
      mutator: mutator,
      client: client ?? QueryClient(clock: () => clock.now),
      retry: retry,
      cacheDuration: cacheDuration,
      cacheKey: cacheKey,
    );
  }

  setUp(() => clock = _Clock(DateTime.utc(2026, 1, 1)));

  group('Mutation lifecycle', () {
    test('starts idle with nothing to show', () {
      final target = mutation<int, int>((id) async => id);

      expect(target.status.value, MutationStatus.idle);
      expect(target.data.value, isNull);
      expect(target.error.value, isNull);
      expect(target.stackTrace.value, isNull);
      expect(target.isPending.value, isFalse);
      expect(target.isSuccess.value, isFalse);
      expect(target.isError.value, isFalse);
      expect(target.disposed, isFalse);
    });

    test('a settled write publishes its result', () async {
      final target = mutation<int, int>((id) async => id * 10);

      await target.mutate(4);

      expect(target.status.value, MutationStatus.success);
      expect(target.data.value, 40);
      expect(target.isSuccess.value, isTrue);
      expect(target.isError.value, isFalse);
      expect(target.isPending.value, isFalse);
    });

    test('isPending is true for the whole write', () async {
      final gate = Completer<int>();
      final target = mutation<int, int>((id) async => gate.future);

      final pending = target.mutate(1);

      expect(target.isPending.value, isTrue);
      expect(target.status.value, MutationStatus.pending);

      gate.complete(1);
      await pending;

      expect(target.isPending.value, isFalse);
      expect(target.status.value, MutationStatus.success);
    });

    test('isPending covers concurrent writes', () async {
      final gate = Completer<int>();
      var calls = 0;
      final target = mutation<int, int>((id) async {
        calls++;

        return id == 1 ? gate.future : id;
      });

      final slow = target.mutate(1);
      final fast = target.mutate(2);

      expect(target.isPending.value, isTrue);

      gate.complete(1);
      await Future.wait<void>([slow, fast]);

      expect(calls, 2, reason: 'a write is never deduplicated');
      expect(target.isPending.value, isFalse);
    });
  });

  group('Mutation errors', () {
    test('mutate never throws and lands on the signals', () async {
      final target = mutation<int, int>((id) async => throw StateError('nope'));

      await expectLater(target.mutate(1), completes);

      expect(target.status.value, MutationStatus.error);
      expect(target.isError.value, isTrue);
      expect(target.error.value, isA<StateError>());
      expect(target.stackTrace.value, isNotNull);
      expect(target.data.value, isNull);
    });

    test('mutateAsync rethrows with the original stack trace', () async {
      final target = mutation<int, int>((id) async => throw StateError('nope'));

      Object? caught;
      StackTrace? stackTrace;
      try {
        await target.mutateAsync(1);
      } catch (error, trace) {
        caught = error;
        stackTrace = trace;
      }

      expect(caught, isA<StateError>());
      expect(stackTrace, isNotNull);
      expect(target.error.value, same(caught));
      expect(target.stackTrace.value, same(stackTrace));
    });

    test('mutateAsync resolves with the result', () async {
      final target = mutation<int, int>((id) async => id * 10);

      await expectLater(target.mutateAsync(4), completion(40));

      expect(target.status.value, MutationStatus.success);
    });

    test('a value survives a later failure', () async {
      var calls = 0;
      final target = mutation<int, int>((id) async {
        calls++;
        if (calls == 1) return 40;

        throw StateError('nope');
      });

      await target.mutate(1);
      await target.mutate(1);

      expect(target.status.value, MutationStatus.error);
      expect(target.data.value, 40, reason: 'the last success is still there');
      expect(target.isError.value, isTrue);
    });

    test('a new write clears the error while it is in flight', () async {
      var calls = 0;
      final gate = Completer<int>();
      final target = mutation<int, int>((id) async {
        calls++;
        if (calls == 1) throw StateError('nope');

        return gate.future;
      });

      await target.mutate(1);
      final pending = target.mutate(1);

      expect(target.error.value, isNull);
      expect(target.status.value, MutationStatus.pending);

      gate.complete(2);
      await pending;

      expect(target.status.value, MutationStatus.success);
      expect(target.data.value, 2);
    });

    test('reset returns the mutation to idle', () async {
      final target = mutation<int, int>((id) async => id);
      await target.mutate(1);

      target.reset();

      expect(target.status.value, MutationStatus.idle);
      expect(target.data.value, isNull);
      expect(target.error.value, isNull);
      expect(target.stackTrace.value, isNull);
      expect(target.isPending.value, isFalse);
    });

    test('reset after a failure clears the error too', () async {
      final target = mutation<int, int>((id) async => throw StateError('nope'));

      await target.mutate(1);
      target.reset();

      expect(target.status.value, MutationStatus.idle);
      expect(target.error.value, isNull);
      expect(target.stackTrace.value, isNull);
    });
  });

  group('Mutation retry', () {
    test('retries up to maxAttempts and surfaces the last error', () async {
      var calls = 0;
      final target = mutation<int, int>((id) async {
        calls++;
        throw StateError('attempt $calls');
      }, retry: RetryPolicy(maxAttempts: 3, sleep: _instant));

      await target.mutate(1);

      expect(calls, 3);
      expect(target.status.value, MutationStatus.error);
      expect((target.error.value as StateError).message, 'attempt 3');
    });

    test('a retried write can still succeed', () async {
      var calls = 0;
      final target = mutation<int, int>((id) async {
        calls++;
        if (calls < 3) throw StateError('nope');

        return id;
      }, retry: RetryPolicy(maxAttempts: 3, sleep: _instant));

      await expectLater(target.mutateAsync(1), completion(1));

      expect(calls, 3);
      expect(target.data.value, 1);
    });

    test('retryIf short-circuits a non-retryable error', () async {
      var calls = 0;
      final target = mutation<int, int>(
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

      await target.mutate(1);

      expect(calls, 1);
      expect(target.error.value, isA<FormatException>());
    });
  });

  group('Mutation cache', () {
    test('a null cacheDuration caches nothing', () async {
      final client = QueryClient(clock: () => clock.now);
      final target = mutation<int, int>((id) async => id * 100, client: client);

      await target.mutate(7);

      expect(client.read<int>(7, const Duration(hours: 1)), isNull);
      expect(target.data.value, 700);
    });

    test('the result lands in the cache under the variables key', () async {
      final client = QueryClient(clock: () => clock.now);
      final target = mutation<int, int>(
        (id) async => id * 100,
        client: client,
        cacheDuration: const Duration(minutes: 5),
      );

      await target.mutate(7);

      final entry = client.read<int>(7, const Duration(minutes: 5));
      expect(entry?.data, 700);
      expect(entry?.fetchedAt, clock.now);
    });

    test('a query reads what the mutation wrote', () async {
      final client = QueryClient(clock: () => clock.now);
      var fetches = 0;
      final reader = Query<int, int>(
        fetcher: (id) async {
          fetches++;

          return id;
        },
        client: client,
        staleTime: const Duration(minutes: 5),
      );
      final target = mutation<int, int>(
        (id) async => id * 100,
        client: client,
        cacheDuration: const Duration(minutes: 5),
      );

      await target.mutateAsync(7);
      await reader.watch(7);

      expect(fetches, 0, reason: 'the mutation result is the cache');
      expect(reader.data.value, 700);
    });

    test('the writer own expiry bounds every reader', () async {
      final client = QueryClient(clock: () => clock.now);
      var fetches = 0;
      final reader = Query<int, int>(
        fetcher: (id) async {
          fetches++;

          return id;
        },
        client: client,
        staleTime: const Duration(hours: 1),
      );
      final target = mutation<int, int>(
        (id) async => id * 100,
        client: client,
        cacheDuration: const Duration(minutes: 5),
      );

      await target.mutateAsync(7);
      clock.advance(const Duration(minutes: 6));
      await reader.watch(7);

      expect(fetches, 1, reason: 'the entry expired from the writer side');
      expect(reader.data.value, 7);
    });

    test('a custom cache key decides what is shared', () async {
      final client = QueryClient(clock: () => clock.now);
      final target = mutation<String, ({int page, int nonce})>(
        (variables) async => 'page ${variables.page}',
        client: client,
        cacheDuration: const Duration(minutes: 5),
        cacheKey: (variables) => 'page:${variables.page}',
      );

      await target.mutate((page: 1, nonce: 1));

      expect(
        client.read<String>('page:1', const Duration(minutes: 5))?.data,
        'page 1',
      );
    });
  });

  group('Mutation invalidation', () {
    test('invalidateCache tells the query watching the key', () async {
      final client = QueryClient(clock: () => clock.now);
      var fetches = 0;
      final query = Query<int, int>(
        fetcher: (id) async {
          fetches++;

          return id;
        },
        client: client,
        staleTime: const Duration(minutes: 5),
      );
      final target = mutation<int, int>(
        (id) async => id * 100,
        client: client,
        cacheDuration: const Duration(minutes: 5),
      );

      await query.watch(7);
      await target.mutateAsync(7);
      expect(query.data.value, 7);

      target.invalidateCache();
      await pumpEventQueue();

      expect(fetches, 2, reason: 'the query refetched from the invalidation');
      expect(query.data.value, 7);
    });

    test('invalidateCache drops only the keys this mutation wrote', () async {
      final client = QueryClient(clock: () => clock.now);
      final target = mutation<int, int>(
        (id) async => id * 100,
        client: client,
        cacheDuration: const Duration(minutes: 5),
      );

      await target.mutate(1);
      await target.mutate(2);

      target.invalidateCache(1);

      expect(client.read<int>(1, const Duration(minutes: 5)), isNull);
      expect(client.read<int>(2, const Duration(minutes: 5))?.data, 200);

      target.invalidateCache();

      expect(client.read<int>(2, const Duration(minutes: 5)), isNull);
    });

    test('invalidateCache is a no-op when nothing was written', () async {
      final client = QueryClient(clock: () => clock.now);
      final target = mutation<int, int>((id) async => id, client: client);

      expect(() => target.invalidateCache(), returnsNormally);
      expect(client.read<int>(1, null), isNull);
    });

    test(
      'invalidateCache notifies other listeners of the shared client',
      () async {
        final client = QueryClient(clock: () => clock.now);
        final notified = <Object?>[];
        client.onInvalidate(7, () => notified.add(7));
        final target = mutation<int, int>(
          (id) async => id,
          client: client,
          cacheDuration: const Duration(minutes: 5),
        );

        await target.mutate(7);
        target.invalidateCache(7);

        expect(notified, [7]);
      },
    );
  });

  group('Mutation cache keys', () {
    test('a key that cannot be compared structurally is refused', () {
      final target = Mutation<int, List<int>>(
        mutator: (List<int> ids) async => ids.length,
      );

      expect(() => target.mutate([1, 2, 3]), throwsA(isA<CacheKeyError>()));
      expect(
        () => target.mutateAsync([1, 2, 3]),
        throwsA(isA<CacheKeyError>()),
      );
      expect(
        () => target.invalidateCache([1, 2, 3]),
        throwsA(isA<CacheKeyError>()),
      );
    });

    test('records are the idiomatic key', () async {
      final target = mutation<String, ({int page, String tag})>(
        (variables) async => '${variables.page}-${variables.tag}',
      );

      await expectLater(
        target.mutateAsync((page: 1, tag: 'newest')),
        completion('1-newest'),
      );
    });
  });

  group('Mutation disposal', () {
    test('disposing releases the signals', () async {
      final target = mutation<int, int>((id) async => id);

      await target.mutate(1);
      target.dispose();

      expect(target.disposed, isTrue);
      expect(target.status.disposed, isTrue);
      expect(target.data.disposed, isTrue);
      expect(target.isPending.disposed, isTrue);
      expect(target.isSuccess.disposed, isTrue);
      expect(target.isError.disposed, isTrue);
    });

    test(
      'an in-flight write settles on a disposed mutation without throwing',
      () async {
        final gate = Completer<int>();
        final target = mutation<int, int>((id) async => gate.future);

        final pending = target.mutate(1);
        target.dispose();
        gate.complete(1);

        await expectLater(pending, completes);
        await expectLater(target.mutate(1), completes);
        expect(target.disposed, isTrue);
      },
    );

    test('mutate on a disposed mutation is a silent no-op', () async {
      var calls = 0;
      final target = mutation<int, int>((id) async {
        calls++;

        return id;
      });

      target.dispose();
      await expectLater(target.mutate(1), completes);

      expect(calls, 0);
    });

    test('mutateAsync on a disposed mutation says so', () async {
      final target = mutation<int, int>((id) async => id);

      target.dispose();

      expect(() => target.mutateAsync(1), throwsA(isA<StateError>()));
    });

    test('a shared client outlives the mutation that used it', () async {
      final client = QueryClient(clock: () => clock.now);
      final target = mutation<int, int>((id) async => id, client: client);
      final owned = mutation<int, int>((id) async => id);

      target.dispose();
      owned.dispose();

      expect(client.disposed, isFalse);
    });

    test('dispose is idempotent', () async {
      final target = mutation<int, int>((id) async => id);

      target.dispose();
      target.dispose();

      expect(target.disposed, isTrue);
    });
  });
}

Future<void> _instant(Duration duration) async {}
