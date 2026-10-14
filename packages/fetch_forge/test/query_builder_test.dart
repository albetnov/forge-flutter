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
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: QueryBuilder<String, int>(
      fetcher: fetcher,
      variables: page,
      client: client,
      refresh: refresh,
      staleTime: staleTime,
      builder: (BuildContext context, AsyncValue<String> snapshot) =>
          Text(switch (snapshot) {
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
                builder: (BuildContext context, AsyncValue<String> snapshot) =>
                    Text(switch (snapshot) {
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
                builder: (BuildContext context, AsyncValue<String> snapshot) =>
                    Text(switch (snapshot) {
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
