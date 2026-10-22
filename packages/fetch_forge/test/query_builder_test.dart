import 'package:fetch_forge/flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signals/signals_flutter.dart';

/// Builds a [QueryBuilder] under a [Directionality], which [Text] needs.
Widget harness({
  required Future<String> Function(int page) fetcher,
  required ReadonlySignal<int> page,
  QueryClient? client,
  ReadonlySignal<Object?>? refresh,
  Duration? staleTime,
  bool autoFetch = true,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: QueryBuilder<String, int>(
      fetcher: fetcher,
      variables: page,
      client: client,
      refresh: refresh,
      staleTime: staleTime,
      autoFetch: autoFetch,
      builder: (BuildContext context, QueryView<String, int> query) =>
          Text(switch (query.snapshot.value) {
            AsyncValueData(:final value) => 'data: $value',
            AsyncValueLoading() => 'loading',
            AsyncValueError(:final error) => 'error: $error',
            AsyncValueIdle() => 'idle',
          }),
    ),
  );
}

void main() {
  testWidgets('mount fetches and renders the data', (
    WidgetTester tester,
  ) async {
    final Map<int, int> calls = <int, int>{};
    Future<String> fetcher(int page) async {
      calls[page] = (calls[page] ?? 0) + 1;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return 'page $page';
    }

    final Signal<int> page = signal(1);
    await tester.pumpWidget(harness(fetcher: fetcher, page: page));

    expect(find.text('loading'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('data: page 1'), findsOneWidget);
    expect(calls[1], 1);
  });

  testWidgets('a variables change refetches', (WidgetTester tester) async {
    final Map<int, int> calls = <int, int>{};
    Future<String> fetcher(int page) async {
      calls[page] = (calls[page] ?? 0) + 1;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return 'page $page';
    }

    final Signal<int> page = signal(1);
    await tester.pumpWidget(harness(fetcher: fetcher, page: page));
    await tester.pumpAndSettle();

    page.value = 2;
    await tester.pumpAndSettle();

    expect(find.text('data: page 2'), findsOneWidget);
    expect(calls[1], 1);
    expect(calls[2], 1);
  });

  testWidgets('unmount disposes the query and stops watching', (
    WidgetTester tester,
  ) async {
    final Map<int, int> calls = <int, int>{};
    Future<String> fetcher(int page) async {
      calls[page] = (calls[page] ?? 0) + 1;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return 'page $page';
    }

    final Signal<int> page = signal(1);
    await tester.pumpWidget(harness(fetcher: fetcher, page: page));
    await tester.pumpAndSettle();
    expect(calls[1], 1);

    await tester.pumpWidget(
      const Directionality(textDirection: TextDirection.ltr, child: SizedBox()),
    );

    page.value = 2;
    await tester.pumpAndSettle();
    expect(calls[2], isNull);
  });

  testWidgets('a refresh bump refetches the current variables', (
    WidgetTester tester,
  ) async {
    final Map<int, int> calls = <int, int>{};
    Future<String> fetcher(int page) async {
      calls[page] = (calls[page] ?? 0) + 1;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return 'page $page';
    }

    final Signal<int> page = signal(1);
    final Signal<int> refresh = signal(0);
    await tester.pumpWidget(
      harness(fetcher: fetcher, page: page, refresh: refresh),
    );
    await tester.pumpAndSettle();
    expect(calls[1], 1);

    refresh.value++;
    await tester.pumpAndSettle();

    expect(find.text('data: page 1'), findsOneWidget);
    expect(calls[1], 2);
  });

  testWidgets('without autoFetch nothing is fetched until asked', (
    WidgetTester tester,
  ) async {
    final Map<int, int> calls = <int, int>{};
    Future<String> fetcher(int page) async {
      calls[page] = (calls[page] ?? 0) + 1;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return 'page $page';
    }

    final Signal<int> page = signal(1);
    late QueryView<String, int> view;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: QueryBuilder<String, int>(
          fetcher: fetcher,
          variables: page,
          autoFetch: false,
          builder: (BuildContext context, QueryView<String, int> query) {
            view = query;

            return Text(switch (query.snapshot.value) {
              AsyncValueData(:final value) => 'data: $value',
              AsyncValueLoading() => 'loading',
              AsyncValueError(:final error) => 'error: $error',
              AsyncValueIdle() => 'idle',
            });
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Mounting fetches nothing, and a variables change alone fetches
    // nothing either.
    expect(find.text('idle'), findsOneWidget);
    expect(calls.isEmpty, isTrue);

    page.value = 2;
    await tester.pumpAndSettle();
    expect(calls.isEmpty, isTrue);
    expect(find.text('idle'), findsOneWidget);

    // An explicit refetch fetches with the current variables.
    view.refetch(page.value).ignore();
    await tester.pumpAndSettle();

    expect(calls[2], 1);
    expect(find.text('data: page 2'), findsOneWidget);
  });

  testWidgets('without autoFetch a refresh bump fetches', (
    WidgetTester tester,
  ) async {
    final Map<int, int> calls = <int, int>{};
    Future<String> fetcher(int page) async {
      calls[page] = (calls[page] ?? 0) + 1;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return 'page $page';
    }

    final Signal<int> page = signal(1);
    final Signal<int> refresh = signal(0);
    await tester.pumpWidget(
      harness(fetcher: fetcher, page: page, refresh: refresh, autoFetch: false),
    );
    await tester.pumpAndSettle();
    expect(calls.isEmpty, isTrue);

    refresh.value++;
    await tester.pumpAndSettle();

    expect(calls[1], 1);
    expect(find.text('data: page 1'), findsOneWidget);
  });

  testWidgets('the view seeds, invalidates and reads the state', (
    WidgetTester tester,
  ) async {
    final Map<int, int> calls = <int, int>{};
    Future<String> fetcher(int page) async {
      calls[page] = (calls[page] ?? 0) + 1;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return 'page $page';
    }

    final Signal<int> page = signal(1);
    late QueryView<String, int> view;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: QueryBuilder<String, int>(
          fetcher: fetcher,
          variables: page,
          staleTime: const Duration(minutes: 5),
          builder: (BuildContext context, QueryView<String, int> query) {
            view = query;

            return Text(switch (query.snapshot.value) {
              AsyncValueData(:final value) => 'data: $value',
              AsyncValueLoading() => 'loading',
              AsyncValueError(:final error) => 'error: $error',
              AsyncValueIdle() => 'idle',
            });
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(view.status.value, QueryStatus.success);
    expect(view.isSuccess.value, isTrue);
    expect(view.isFetching.value, isFalse);
    expect(view.data.value, 'page 1');
    expect(view.error.value, isNull);
    expect(view.stackTrace.value, isNull);
    expect(view.isStale.value, isFalse);

    // Seeding replaces the data without fetching.
    view.setData('seeded', 1);
    await tester.pumpAndSettle();
    expect(find.text('data: seeded'), findsOneWidget);
    expect(calls[1], 1);

    // Invalidating drops the entry and refetches the watched key.
    view.invalidate(1);
    await tester.pumpAndSettle();
    expect(calls[1], 2);
    expect(find.text('data: page 1'), findsOneWidget);
  });

  testWidgets('builders under one scope share a single fetch', (
    WidgetTester tester,
  ) async {
    final QueryClient client = QueryClient();
    addTearDown(client.dispose);

    int fetches = 0;
    Future<String> fetcher(int page) async {
      fetches++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return 'page $page';
    }

    final Signal<int> page = signal(1);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: QueryScope(
          client: client,
          child: Column(
            children: <Widget>[
              QueryBuilder<String, int>(
                fetcher: fetcher,
                variables: page,
                staleTime: const Duration(minutes: 5),
                builder: (BuildContext context, QueryView<String, int> query) =>
                    Text(switch (query.snapshot.value) {
                      AsyncValueData(:final value) => 'first: $value',
                      AsyncValueLoading() => 'first: loading',
                      AsyncValueError(:final error) => 'first: $error',
                      AsyncValueIdle() => 'first: idle',
                    }),
              ),
              QueryBuilder<String, int>(
                fetcher: fetcher,
                variables: page,
                staleTime: const Duration(minutes: 5),
                builder: (BuildContext context, QueryView<String, int> query) =>
                    Text(switch (query.snapshot.value) {
                      AsyncValueData(:final value) => 'second: $value',
                      AsyncValueLoading() => 'second: loading',
                      AsyncValueError(:final error) => 'second: $error',
                      AsyncValueIdle() => 'second: idle',
                    }),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(fetches, 1);
    expect(find.text('first: page 1'), findsOneWidget);
    expect(find.text('second: page 1'), findsOneWidget);
  });
}
