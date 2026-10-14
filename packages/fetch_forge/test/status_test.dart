import 'package:fetch_forge/fetch_forge.dart';
import 'package:test/test.dart';

void main() {
  group('QueryStatus', () {
    test('has four states in order', () {
      expect(QueryStatus.values, [
        QueryStatus.idle,
        QueryStatus.loading,
        QueryStatus.success,
        QueryStatus.error,
      ]);
    });

    test('every state survives a round trip through its name', () {
      for (final status in QueryStatus.values) {
        expect(QueryStatus.values.byName(status.name), status);
      }
    });
  });

  group('MutationStatus', () {
    test('has four states in order', () {
      expect(MutationStatus.values, [
        MutationStatus.idle,
        MutationStatus.pending,
        MutationStatus.success,
        MutationStatus.error,
      ]);
    });

    test('every state survives a round trip through its name', () {
      for (final status in MutationStatus.values) {
        expect(MutationStatus.values.byName(status.name), status);
      }
    });

    test('a write is pending while a read is loading', () {
      expect(
        QueryStatus.loading.name,
        isNot(equals(MutationStatus.pending.name)),
        reason: 'the two vocabularies stay distinct',
      );
    });
  });
}
