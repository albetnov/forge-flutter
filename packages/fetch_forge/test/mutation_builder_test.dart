import 'package:fetch_forge/flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signals/signals_flutter.dart';

/// Builds a [MutationBuilder] under a [Directionality], which [Text] needs.
Widget harness({
  required Future<String> Function(int page) mutator,
  required Widget Function(BuildContext context, MutationView<String, int> view)
  builder,
  QueryClient? client,
  ReadonlySignal<int>? variables,
  ReadonlySignal<Object?>? trigger,
  Duration? cacheDuration,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MutationBuilder<String, int>(
      mutator: mutator,
      builder: builder,
      client: client,
      variables: variables,
      trigger: trigger,
      cacheDuration: cacheDuration,
    ),
  );
}

/// A placeholder that replaces the tree, so the widget unmounts.
const Widget placeholder = Directionality(
  textDirection: TextDirection.ltr,
  child: SizedBox(),
);

void main() {
  testWidgets('mounting writes nothing', (WidgetTester tester) async {
    int writes = 0;
    Future<String> mutator(int page) async {
      writes++;

      return 'written $page';
    }

    await tester.pumpWidget(
      harness(
        mutator: mutator,
        builder: (BuildContext context, MutationView<String, int> view) =>
            Text(view.status.value.name),
      ),
    );

    expect(find.text('idle'), findsOneWidget);
    expect(writes, 0);
  });

  testWidgets('a write settles on success and shows its result', (
    WidgetTester tester,
  ) async {
    late MutationView<String, int> view;
    int writes = 0;
    Future<String> mutator(int page) async {
      writes++;
      await Future<void>.delayed(const Duration(milliseconds: 5));

      return 'written $page';
    }

    await tester.pumpWidget(
      harness(
        mutator: mutator,
        builder: (BuildContext context, MutationView<String, int> mutation) {
          view = mutation;

          return Text(mutation.data.value ?? 'none');
        },
      ),
    );

    view.mutate(1).ignore();
    await tester.pumpAndSettle();

    expect(writes, 1);
    expect(view.status.value, MutationStatus.success);
    expect(find.text('written 1'), findsOneWidget);
  });

  testWidgets('a write in flight is pending', (WidgetTester tester) async {
    late MutationView<String, int> view;
    Future<String> mutator(int page) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));

      return 'written $page';
    }

    await tester.pumpWidget(
      harness(
        mutator: mutator,
        builder: (BuildContext context, MutationView<String, int> mutation) {
          view = mutation;

          return Text(mutation.isPending.value ? 'pending' : 'idle');
        },
      ),
    );

    view.mutate(1).ignore();
    await tester.pump();

    expect(view.isPending.value, isTrue);
    expect(find.text('pending'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(view.isPending.value, isFalse);
    expect(find.text('idle'), findsOneWidget);
  });

  testWidgets('a failed write shows the error and never throws', (
    WidgetTester tester,
  ) async {
    late MutationView<String, int> view;
    Future<String> mutator(int page) async => throw Exception('boom');

    await tester.pumpWidget(
      harness(
        mutator: mutator,
        builder: (BuildContext context, MutationView<String, int> mutation) {
          view = mutation;

          return Text(mutation.error.value?.toString() ?? 'none');
        },
      ),
    );

    view.mutate(1).ignore();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(view.status.value, MutationStatus.error);
    expect(find.textContaining('boom'), findsOneWidget);
  });

  testWidgets('a trigger bump writes with the current variables', (
    WidgetTester tester,
  ) async {
    final List<int> written = <int>[];
    Future<String> mutator(int page) async {
      written.add(page);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      return 'written $page';
    }

    final Signal<int> variables = signal(1);
    final Signal<int> trigger = signal(0);

    await tester.pumpWidget(
      harness(
        mutator: mutator,
        variables: variables,
        trigger: trigger,
        builder: (BuildContext context, MutationView<String, int> view) =>
            Text(view.data.value ?? 'none'),
      ),
    );

    // The first run of the trigger is skipped: a trigger is a bump, not an
    // initial value.
    await tester.pumpAndSettle();
    expect(written, isEmpty);

    trigger.value++;
    await tester.pumpAndSettle();
    expect(written, <int>[1]);
    expect(find.text('written 1'), findsOneWidget);

    // A variables change alone never writes.
    variables.value = 2;
    await tester.pumpAndSettle();
    expect(written, <int>[1]);

    // The next bump writes with the new variables.
    trigger.value++;
    await tester.pumpAndSettle();
    expect(written, <int>[1, 2]);
    expect(find.text('written 2'), findsOneWidget);
  });

  testWidgets('unmount disposes the mutation', (WidgetTester tester) async {
    int writes = 0;
    Future<String> mutator(int page) async {
      writes++;

      return 'written $page';
    }

    final Signal<int> trigger = signal(0);

    await tester.pumpWidget(
      harness(
        mutator: mutator,
        variables: signal(1),
        trigger: trigger,
        builder: (BuildContext context, MutationView<String, int> view) =>
            const SizedBox(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(placeholder);

    trigger.value++;
    await tester.pumpAndSettle();

    expect(writes, 0);
  });

  testWidgets('a write lands in the shared cache', (WidgetTester tester) async {
    final QueryClient client = QueryClient();
    addTearDown(client.dispose);

    late MutationView<String, int> view;
    int writes = 0;
    Future<String> mutator(int page) async {
      writes++;
      await Future<void>.delayed(const Duration(milliseconds: 5));

      return 'written $page';
    }

    await tester.pumpWidget(
      harness(
        mutator: mutator,
        client: client,
        cacheDuration: const Duration(minutes: 5),
        builder: (BuildContext context, MutationView<String, int> mutation) {
          view = mutation;

          return const SizedBox();
        },
      ),
    );

    view.mutate(1).ignore();
    await tester.pumpAndSettle();
    expect(writes, 1);

    // A query on the same key finds the written result in the shared cache
    // instead of fetching it again.
    int fetches = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: QueryBuilder<String, int>(
          fetcher: (int page) async {
            fetches++;

            return 'fetched $page';
          },
          variables: signal(1),
          client: client,
          staleTime: const Duration(minutes: 5),
          builder: (BuildContext context, QueryView<String, int> query) =>
              Text(switch (query.snapshot.value) {
                AsyncValueData(:final value) => value,
                AsyncValueLoading() => 'loading',
                AsyncValueError(:final error) => 'error: $error',
                AsyncValueIdle() => 'idle',
              }),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(fetches, 0);
    expect(find.text('written 1'), findsOneWidget);
  });

  testWidgets('invalidating the written key refetches the query', (
    WidgetTester tester,
  ) async {
    final QueryClient client = QueryClient();
    addTearDown(client.dispose);

    int fetches = 0;
    Future<String> fetcher(int page) async {
      fetches++;
      await Future<void>.delayed(const Duration(milliseconds: 5));

      return 'fetched $page';
    }

    late MutationView<String, int> view;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: <Widget>[
            QueryBuilder<String, int>(
              fetcher: fetcher,
              variables: signal(1),
              client: client,
              builder: (BuildContext context, QueryView<String, int> query) =>
                  Text(switch (query.snapshot.value) {
                    AsyncValueData(:final value) => value,
                    AsyncValueLoading() => 'loading',
                    AsyncValueError(:final error) => 'error: $error',
                    AsyncValueIdle() => 'idle',
                  }),
            ),
            MutationBuilder<String, int>(
              mutator: (int page) async => 'written $page',
              client: client,
              cacheDuration: const Duration(minutes: 5),
              builder:
                  (BuildContext context, MutationView<String, int> mutation) {
                    view = mutation;

                    return const SizedBox();
                  },
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(fetches, 1);

    // The write is cached, but the query is not notified of it.
    view.mutate(1).ignore();
    await tester.pumpAndSettle();
    expect(fetches, 1);

    // Invalidating the written key asks the watching query to fetch again.
    view.invalidateCache(1);
    await tester.pumpAndSettle();
    expect(fetches, 2);
  });

  testWidgets('a new mutator restarts the write from idle', (
    WidgetTester tester,
  ) async {
    late MutationView<String, int> view;
    Future<String> first(int page) async => 'first';
    Future<String> second(int page) async => 'second';

    await tester.pumpWidget(
      harness(
        mutator: first,
        builder: (BuildContext context, MutationView<String, int> mutation) {
          view = mutation;

          return Text(mutation.data.value ?? 'none');
        },
      ),
    );

    view.mutate(1).ignore();
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);

    await tester.pumpWidget(
      harness(
        mutator: second,
        builder: (BuildContext context, MutationView<String, int> mutation) {
          view = mutation;

          return Text(mutation.data.value ?? 'none');
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('none'), findsOneWidget);
    expect(view.status.value, MutationStatus.idle);
  });
}
