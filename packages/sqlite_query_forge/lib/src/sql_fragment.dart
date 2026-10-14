/// SQL text accumulator paired with its bound-argument list.
final class SqlFragment {
  final StringBuffer _sql = StringBuffer();
  final List<Object?> _args = <Object?>[];

  void write(String sql) => _sql.write(sql);

  void writeIdentifier(String name) => _sql.write(quoteIdentifier(name));

  void writeLiteral(String text) => _sql.write(quoteStringLiteral(text));

  void bind(Object? value) {
    _sql.write('?');
    // SQLite has no boolean type.
    _args.add(switch (value) {
      bool b => b ? 1 : 0,
      _ => value,
    });
  }

  void bindAll(List<Object?> values) {
    for (var i = 0; i < values.length; i++) {
      if (i > 0) _sql.write(', ');
      bind(values[i]);
    }
  }

  String get sql => _sql.toString();

  /// The live internal list; callers must not mutate it.
  List<Object?> get args => _args;
}

String quoteIdentifier(String name) => '"${name.replaceAll('"', '""')}"';

String quoteStringLiteral(String text) => "'${text.replaceAll("'", "''")}'";
