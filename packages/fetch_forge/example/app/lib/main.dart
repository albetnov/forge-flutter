import 'package:fetch_forge/flutter.dart';
import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

/// A stand-in for a real HTTP service.
final class Directory {
  /// How many times the service was hit.
  int calls = 0;

  Future<List<String>> users(int page) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 300));

    return <String>['ada@$page', 'grace@$page', 'alan@$page'];
  }
}

Future<List<String>> fetchUsers(int page) => _directory.users(page);
final Directory _directory = Directory();

void main() {
  // App-lifetime client: every page below shares one cache through the
  // scope, and nobody disposes it before the process ends.
  runApp(UsersApp(client: QueryClient()));
}

/// The demo app: one shared cache, one page of users.
class UsersApp extends StatelessWidget {
  /// Creates the app sharing [client] with the whole subtree.
  const UsersApp({super.key, required this.client});

  /// The cache every query below shares.
  final QueryClient client;

  @override
  Widget build(BuildContext context) {
    return QueryScope(
      client: client,
      child: MaterialApp(
        title: 'fetch_forge example',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        ),
        home: const UsersPage(),
      ),
    );
  }
}

/// One page of users with previous/next and refresh controls.
class UsersPage extends StatefulWidget {
  /// Creates the page.
  const UsersPage({super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  late final Signal<int> page = signal(1);
  late final Signal<int> refresh = signal(0);

  @override
  void dispose() {
    refresh.dispose();
    page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('fetch_forge example')),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(8),
            child: SignalBuilder(
              builder: (BuildContext context) => Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    tooltip: 'Previous page',
                    onPressed: page.value > 1 ? () => page.value-- : null,
                  ),
                  Text('Page ${page.value}'),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    tooltip: 'Next page',
                    onPressed: () => page.value++,
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh',
                    onPressed: () => refresh.value++,
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: QueryBuilder<List<String>, int>(
              fetcher: fetchUsers,
              variables: page,
              refresh: refresh,
              staleTime: const Duration(seconds: 30),
              builder:
                  (BuildContext context, AsyncValue<List<String>> snapshot) =>
                      switch (snapshot) {
                        AsyncValueData(:final value) => ListView(
                          children: <Widget>[
                            for (final String user in value)
                              ListTile(title: Text(user)),
                          ],
                        ),
                        AsyncValueLoading(:final previous) =>
                          previous == null
                              ? const Center(child: CircularProgressIndicator())
                              : ListView(
                                  children: <Widget>[
                                    for (final String user in previous)
                                      ListTile(title: Text(user)),
                                    const ListTile(
                                      title: Text('Refreshing...'),
                                    ),
                                  ],
                                ),
                        AsyncValueError(:final error) => Center(
                          child: Text('Failed: $error'),
                        ),
                        AsyncValueIdle() => const Center(child: Text('Idle')),
                      },
            ),
          ),
        ],
      ),
    );
  }
}
