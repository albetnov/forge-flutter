import 'package:fetch_forge/fetch_forge.dart';
import 'package:test/test.dart';

void main() {
  group('QueryClient', () {
    late DateTime now;
    late QueryClient client;

    setUp(() {
      now = DateTime.utc(2026, 1, 1);
      client = QueryClient(clock: () => now);
    });

    test('a write is readable with its timestamp', () {
      client.write('users', 42);

      final entry = client.read<int>('users', const Duration(seconds: 5));

      expect(entry, isA<CacheEntry<int>>());
      expect(entry?.data, 42);
      expect(entry?.fetchedAt, now);
      expect(entry.toString(), 'CacheEntry(data: 42, fetchedAt: $now)');
    });

    test('a missing key is a miss, not a failure', () {
      expect(client.read<int>('missing', const Duration(seconds: 5)), isNull);
    });

    test('an entry older than cacheTime is a miss and is dropped on read', () {
      client.write('users', 42);

      now = now.add(const Duration(minutes: 1));

      expect(client.read<int>('users', const Duration(seconds: 30)), isNull);
      // The entry was evicted by the read itself: a wider window cannot bring
      // it back, so no timer ever had to run.
      expect(client.read<int>('users', const Duration(hours: 1)), isNull);
    });

    test('cacheTime is inclusive of the boundary', () {
      client.write('users', 42);

      now = now.add(const Duration(seconds: 30));

      expect(client.read<int>('users', const Duration(seconds: 30))?.data, 42);

      now = now.add(const Duration(microseconds: 1));

      expect(client.read<int>('users', const Duration(seconds: 30)), isNull);
    });

    test('a null cacheTime never expires an entry', () {
      client.write('users', 42);

      now = now.add(const Duration(days: 365));

      expect(client.read<int>('users', null)?.data, 42);
    });

    test('a writer can bound its own entry for every reader', () {
      client.write('users', 42, expiresIn: const Duration(minutes: 5));

      now = now.add(const Duration(minutes: 5));

      final generous = client.read<int>('users', const Duration(hours: 1));
      expect(generous?.data, 42, reason: 'the boundary is still fresh');

      now = now.add(const Duration(microseconds: 1));

      expect(
        client.read<int>('users', const Duration(hours: 1)),
        isNull,
        reason: 'the writer expiry outranks the caller cache time',
      );
    });

    test('a writer bound applies to a caller who asked for nothing', () {
      client.write('users', 42, expiresIn: const Duration(minutes: 5));

      now = now.add(const Duration(minutes: 6));

      expect(client.read<int>('users', null), isNull);
    });

    test('the earlier of the two expiries wins', () {
      client.write('users', 42, expiresIn: const Duration(minutes: 30));

      now = now.add(const Duration(seconds: 45));

      expect(
        client.read<int>('users', const Duration(seconds: 30)),
        isNull,
        reason: 'the caller asked for 30s and the entry is 45s old',
      );
    });

    test('reading does not refresh the timestamp', () {
      client.write('users', 42);

      now = now.add(const Duration(seconds: 10));

      final entry = client.read<int>('users', const Duration(seconds: 20));

      expect(entry?.fetchedAt, DateTime.utc(2026, 1, 1));
    });

    test('a later write replaces both the value and the timestamp', () {
      client.write('users', 42);
      now = now.add(const Duration(seconds: 10));
      client.write('users', 7);

      final entry = client.read<int>('users', null);

      expect(entry?.data, 7);
      expect(entry?.fetchedAt, now);
    });

    test('entries are independent per key', () {
      client.write('a', 1);
      client.write('b', 2);

      expect(client.read<int>('a', null)?.data, 1);
      expect(client.read<int>('b', null)?.data, 2);
    });

    test('the default clock is the wall clock', () {
      final real = QueryClient();

      real.write('users', 42);
      final difference = real
          .read<int>('users', null)!
          .fetchedAt
          .difference(DateTime.now());

      expect(difference.inSeconds.abs(), lessThan(5));
    });
  });

  group('QueryClient invalidation', () {
    late DateTime now;
    late QueryClient client;

    setUp(() {
      now = DateTime.utc(2026, 1, 1);
      client = QueryClient(clock: () => now);
    });

    test('invalidate drops the entry', () {
      client.write('users', 42);

      client.invalidate('users');

      expect(client.read<int>('users', const Duration(minutes: 5)), isNull);
    });

    test('invalidate notifies every listener of the key', () {
      var calls = 0;
      client.onInvalidate('users', () => calls++);
      client.onInvalidate('users', () => calls++);

      client.invalidate('users');

      expect(calls, 2);
    });

    test('invalidate notifies even when there is nothing to drop', () {
      var calls = 0;
      client.onInvalidate('users', () => calls++);

      client.invalidate('users');

      expect(calls, 1);
    });

    test('invalidate leaves other keys alone', () {
      var notifications = <Object?>[];
      client.onInvalidate('a', () => notifications.add('a'));
      client.onInvalidate('b', () => notifications.add('b'));
      client.write('a', 1);
      client.write('b', 2);

      client.invalidate('a');

      expect(notifications, ['a']);
      expect(client.read<int>('b', null)?.data, 2);
    });

    test('invalidateAll drops every entry and notifies every key', () {
      var notifications = <Object?>[];
      client.onInvalidate('a', () => notifications.add('a'));
      client.onInvalidate('b', () => notifications.add('b'));
      client.write('a', 1);
      client.write('b', 2);

      client.invalidateAll();

      expect(client.read<int>('a', null), isNull);
      expect(client.read<int>('b', null), isNull);
      expect(notifications, containsAll(['a', 'b']));
    });

    test('clear drops every entry without notifying anyone', () {
      var calls = 0;
      client.onInvalidate('users', () => calls++);
      client.write('users', 42);

      client.clear();

      expect(client.read<int>('users', const Duration(minutes: 5)), isNull);
      expect(calls, 0);
    });

    test('the returned function removes its listener', () {
      var calls = 0;

      final unsubscribe = client.onInvalidate('users', () => calls++);
      client.invalidate('users');
      unsubscribe();
      client.invalidate('users');

      expect(calls, 1);
    });

    test('listeners added during a notification wait for the next one', () {
      var early = 0;
      var late = 0;

      client.onInvalidate('users', () {
        early++;
        client.onInvalidate('users', () => late++);
      });

      client.invalidate('users');

      expect(early, 1);
      expect(late, 0);
    });
  });

  group('QueryClient dedupe', () {
    test('concurrent calls for one key share a single execution', () async {
      final client = QueryClient();
      var calls = 0;

      Future<String> task() async {
        calls++;
        await Future<void>.delayed(Duration.zero);

        return 'value';
      }

      final first = client.dedupe('users', task);
      final second = client.dedupe('users', task);

      expect(identical(first, second), isTrue);
      await expectLater(first, completion('value'));
      await expectLater(second, completion('value'));
      expect(calls, 1);
    });

    test('the key is free again once the task settles', () async {
      final client = QueryClient();
      var calls = 0;

      Future<int> task() async {
        calls++;
        await Future<void>.delayed(Duration.zero);

        return calls;
      }

      await expectLater(client.dedupe('users', task), completion(1));
      await expectLater(client.dedupe('users', task), completion(2));

      expect(calls, 2);
    });

    test(
      'a failed task is handed to every caller and then forgotten',
      () async {
        final client = QueryClient();
        var calls = 0;

        Future<int> task() async {
          calls++;
          await Future<void>.delayed(Duration.zero);
          throw StateError('boom');
        }

        final first = client.dedupe('users', task);
        final second = client.dedupe('users', task);

        await expectLater(first, throwsStateError);
        await expectLater(second, throwsStateError);

        final third = client.dedupe('users', task);
        await expectLater(third, throwsStateError);

        expect(calls, 2);
      },
    );

    test('different keys never share an execution', () async {
      final client = QueryClient();
      var calls = 0;

      Future<int> task() async {
        calls++;
        await Future<void>.delayed(Duration.zero);

        return calls;
      }

      await Future.wait([client.dedupe('a', task), client.dedupe('b', task)]);

      expect(calls, 2);
    });
  });

  group('QueryClient disposal', () {
    test('a disposed client reports misses and swallows writes', () {
      final client = QueryClient();
      client.write('users', 42);

      client.dispose();

      expect(client.disposed, isTrue);
      expect(client.read<int>('users', const Duration(minutes: 5)), isNull);

      client.write('users', 7);
      expect(client.read<int>('users', null), isNull);
    });

    test('a disposed client releases its listeners', () {
      final client = QueryClient();
      var calls = 0;
      client.onInvalidate('users', () => calls++);

      client.dispose();
      client.invalidateAll();

      expect(calls, 0);
    });

    test('a disposed client accepts no new listeners', () {
      final client = QueryClient();
      client.dispose();

      var calls = 0;
      final unsubscribe = client.onInvalidate('users', () => calls++);
      client.invalidate('users');
      unsubscribe();

      expect(calls, 0);
    });

    test(
      'a disposed client still runs deduplicated work without leaking',
      () async {
        final client = QueryClient();
        client.dispose();

        var calls = 0;
        Future<int> task() async {
          calls++;
          await Future<void>.delayed(Duration.zero);

          return calls;
        }

        await expectLater(client.dedupe('users', task), completion(1));
        await expectLater(client.dedupe('users', task), completion(2));

        expect(calls, 2);
      },
    );

    test('dispose is idempotent', () {
      final client = QueryClient();

      client.dispose();
      client.dispose();

      expect(client.disposed, isTrue);
    });
  });
}
