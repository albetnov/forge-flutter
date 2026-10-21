import 'package:fetch_forge/flutter.dart';
import 'package:fetch_forge_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the example loads a page of users', (WidgetTester tester) async {
    await tester.pumpWidget(UsersApp(client: QueryClient()));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('ada@1'), findsOneWidget);
    expect(find.text('grace@1'), findsOneWidget);

    await tester.tap(find.byTooltip('Next page'));
    await tester.pumpAndSettle();
    expect(find.text('ada@2'), findsOneWidget);

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('ada@2'), findsOneWidget);
  });

  testWidgets('adding a user writes and refetches the list', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(UsersApp(client: QueryClient()));
    await tester.pumpAndSettle();
    expect(find.text('ada@1'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hopper');
    await tester.tap(find.text('Add user'));
    await tester.pumpAndSettle();

    // The write is cached under the page's key, and invalidating that key
    // asks the query above to fetch it again.
    expect(find.text('hopper@1'), findsOneWidget);
  });
}
