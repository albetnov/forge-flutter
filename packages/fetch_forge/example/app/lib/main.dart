import 'package:fetch_forge/flutter.dart';
import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

/// A stand-in for a real HTTP service.
final class Directory {
  /// How many times the service was hit.
  int calls = 0;

  /// The users created through the service, per page.
  final Map<int, List<String>> _created = <int, List<String>>{};

  Future<List<String>> users(int page) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 300));

    return _page(page);
  }

  Future<List<String>> createUser(int page, String name) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _created.putIfAbsent(page, () => <String>[]).add('$name@$page');

    return _page(page);
  }

  List<String> _page(int page) => <String>[
    'ada@$page',
    'grace@$page',
    'alan@$page',
    ...?_created[page],
  ];
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
  final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
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
          Padding(
            padding: const EdgeInsets.all(8),
            child: MutationBuilder<List<String>, ({int page, String name})>(
              mutator: (variables) =>
                  _directory.createUser(variables.page, variables.name),
              // The written list is cached under the page's key — the same
              // key the query above uses — so the two share one cache entry.
              cacheKey: (variables) => variables.page,
              cacheDuration: const Duration(minutes: 5),
              builder:
                  (
                    BuildContext context,
                    MutationView<List<String>, ({int page, String name})>
                    mutation,
                  ) => Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: _name,
                          decoration: const InputDecoration(
                            labelText: 'New user',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: mutation.isPending.value
                            ? null
                            : () {
                                final String name = _name.text.trim();
                                if (name.isEmpty) return;
                                // The write, then the refetch: the
                                // mutation caches what it wrote, and
                                // invalidating that key asks the query
                                // above to fetch it again.
                                mutation
                                    .mutateAsync((page: page.value, name: name))
                                    .then<void>((_) {
                                      _name.clear();
                                      mutation.invalidateCache();
                                    })
                                    .ignore();
                              },
                        child: Text(
                          mutation.isPending.value ? 'Saving...' : 'Add user',
                        ),
                      ),
                    ],
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
