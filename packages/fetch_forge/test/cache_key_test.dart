import 'package:fetch_forge/fetch_forge.dart';
import 'package:test/test.dart';

void main() {
  group('cacheKeyFor', () {
    test('uses the variables themselves by default', () {
      expect(cacheKeyFor(42), 42);
      expect(cacheKeyFor('page'), 'page');
      expect(cacheKeyFor(true), true);
      expect(cacheKeyFor(null), isNull);
    });

    test('records are valid keys', () {
      final key = cacheKeyFor((page: 1, tag: 'newest'));

      expect(key, isA<({int page, String tag})>());
      expect(key, (page: 1, tag: 'newest'));
    });

    test('value classes with structural equality are valid keys', () {
      Page page = const Page(1);

      expect(cacheKeyFor(page), Page(1));
      expect(cacheKeyFor(Page(1)), cacheKeyFor(Page(1)));
    });

    test('the mapper result becomes the key', () {
      final key = cacheKeyFor(
        Filter(page: 1, tag: 'newest', noise: 'ignored'),
        mapper: (filter) => (filter.page, filter.tag),
      );

      expect(key, (1, 'newest'));
    });

    test('the mapper output is validated too', () {
      expect(
        () => cacheKeyFor<int>(1, mapper: (int page) => [1]),
        throwsA(isA<CacheKeyError>()),
      );
    });

    test('rejects lists', () {
      expect(() => cacheKeyFor([1, 2, 3]), throwsA(isA<CacheKeyError>()));
    });

    test('rejects sets', () {
      expect(() => cacheKeyFor({1, 2, 3}), throwsA(isA<CacheKeyError>()));
    });

    test('rejects maps', () {
      expect(() => cacheKeyFor({'a': 1}), throwsA(isA<CacheKeyError>()));
    });

    test('rejects values that are not equal to themselves', () {
      expect(() => cacheKeyFor(double.nan), throwsA(isA<CacheKeyError>()));
    });

    test('the error explains how to fix the key', () {
      try {
        cacheKeyFor([1, 2, 3]);
        fail('expected a CacheKeyError');
      } on CacheKeyError catch (error) {
        expect(error.variables, [1, 2, 3]);
        expect(error.toString(), contains('List<int>'));
        expect(error.toString(), contains('pass a Dart record'));
        expect(error.toString(), contains('operator =='));
        expect(error.toString(), contains('cacheKey'));
      }
    });

    test('CacheKeyError is an Error, not an Exception', () {
      expect(CacheKeyError([1]).toString(), isA<String>());
      expect(CacheKeyError([1]), isA<Error>());
    });
  });
}

final class Page {
  const Page(this.number);

  final int number;

  @override
  bool operator ==(Object other) => other is Page && other.number == number;

  @override
  int get hashCode => number.hashCode;
}

final class Filter {
  const Filter({required this.page, required this.tag, required this.noise});

  final int page;
  final String tag;
  final String noise;
}
