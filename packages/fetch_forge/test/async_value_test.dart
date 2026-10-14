import 'package:fetch_forge/fetch_forge.dart';
import 'package:test/test.dart';

String describe<T>(AsyncValue<T> value) => switch (value) {
  AsyncValueIdle() => 'idle',
  AsyncValueLoading(:final previous) => 'loading($previous)',
  AsyncValueData(:final value) => 'data($value)',
  AsyncValueError(:final error) => 'error($error)',
};

void main() {
  group('AsyncValue', () {
    test('idle is a canonical instance', () {
      const first = AsyncValue<String>.idle();
      const second = AsyncValue<String>.idle();

      expect(identical(first, second), isTrue);
      expect(first, isA<AsyncValueIdle<String>>());
      expect(describe(first), 'idle');
    });

    test('loading carries the previous value only while there is one', () {
      final without = AsyncValue<String>.loading();
      final withPrevious = AsyncValue<String>.loading(previous: 'ada');

      expect(describe(without), 'loading(null)');
      expect(describe(withPrevious), 'loading(ada)');

      expect(
        withPrevious,
        isA<AsyncValueLoading<String>>().having(
          (loading) => loading.previous,
          'previous',
          'ada',
        ),
      );
    });

    test('data defaults to fresh', () {
      final fresh = AsyncValue.data(42);

      expect(fresh, isA<AsyncValueData<int>>());
      expect(
        fresh,
        isA<AsyncValueData<int>>()
            .having((data) => data.value, 'value', 42)
            .having((data) => data.isStale, 'isStale', isFalse),
      );
      expect(describe(fresh), 'data(42)');
    });

    test('data can be flagged stale', () {
      final stale = AsyncValue.data(42, isStale: true);

      expect(
        stale,
        isA<AsyncValueData<int>>()
            .having((data) => data.value, 'value', 42)
            .having((data) => data.isStale, 'isStale', isTrue),
      );
      expect(stale.toString(), 'AsyncValueData(value: 42, isStale: true)');
    });

    test('error carries the failure and its stack trace', () {
      final error = StateError('nope');
      final stack = StackTrace.current;

      final snapshot = AsyncValue<int>.error(error, stack);

      expect(
        snapshot,
        isA<AsyncValueError<int>>()
            .having((value) => value.error, 'error', same(error))
            .having((value) => value.stackTrace, 'stackTrace', same(stack)),
      );
      expect(describe(snapshot), 'error(Bad state: nope)');
    });

    test('every case is reachable through the switch', () {
      expect(describe(AsyncValue<String>.idle()), 'idle');
      expect(describe(AsyncValue<String>.loading()), 'loading(null)');
      expect(describe(AsyncValue.data('ada')), 'data(ada)');
      expect(
        describe(AsyncValue<String>.error('boom', StackTrace.empty)),
        'error(boom)',
      );
    });

    test('snapshots are compared by identity, not by payload', () {
      expect(
        AsyncValue.data(42) == AsyncValue.data(42),
        isFalse,
        reason: 'snapshots have no structural equality',
      );
      expect(
        AsyncValue<String>.loading() == AsyncValue<String>.loading(),
        isFalse,
      );

      // Identity is still observable: only const instances are canonical.
      const idle = AsyncValue<String>.idle();
      expect(identical(idle, const AsyncValue<String>.idle()), isTrue);
    });
  });
}
