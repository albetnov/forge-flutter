import 'package:fetch_forge/fetch_forge.dart';
import 'package:signals/signals.dart';
import 'package:test/test.dart';

void main() {
  group('with signals', () {
    test('a snapshot is an ordinary signal value', () {
      final snapshot = signal<AsyncValue<int>>(AsyncValue.idle());

      snapshot.value = AsyncValue.loading(previous: 7);
      snapshot.value = AsyncValueData(7, isStale: true);

      expect(snapshot.value, isA<AsyncValueData<int>>());
      expect((snapshot.value as AsyncValueData<int>).isStale, isTrue);
    });

    test('derived state recomputes when the snapshot changes', () {
      final snapshot = signal<AsyncValue<int>>(AsyncValue.idle());
      final label = computed(
        () => switch (snapshot.value) {
          AsyncValueIdle() => 'idle',
          AsyncValueLoading() => 'loading',
          AsyncValueData() => 'ready',
          AsyncValueError() => 'failed',
        },
      );

      expect(label.value, 'idle');

      snapshot.value = AsyncValueData(1);
      expect(label.value, 'ready');
    });

    test('an effect sees every change and nothing else', () {
      final snapshot = signal<AsyncValue<int>>(AsyncValue.idle());
      final seen = <AsyncValue<int>>[];

      final dispose = effect(() => seen.add(snapshot.value));

      snapshot.value = AsyncValue.loading();
      snapshot.value = AsyncValue.data(1);
      dispose();
      snapshot.value = AsyncValue.idle();

      expect(seen.map((value) => value.isData).toList(), [false, false, true]);
    });

    test('peek reads without subscribing', () {
      final snapshot = signal<AsyncValue<String>>(AsyncValue.data('ada'));
      var runs = 0;

      final dispose = effect(() {
        snapshot.peek();
        runs++;
      });

      snapshot.value = AsyncValue.data('grace');
      dispose();
      snapshot.value = AsyncValue.idle();

      expect(runs, 1, reason: 'peek never subscribes');
    });
  });
}

extension on AsyncValue<int> {
  bool get isData => this is AsyncValueData<int>;
}
