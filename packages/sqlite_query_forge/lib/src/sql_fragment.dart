/// SQL text accumulator paired with its bound-argument list.
final class SqlFragment {
  final StringBuffer _sql = StringBuffer();
  final List<Object?> _args = <Object?>[];

  /// Appends [sql] verbatim.
  void write(String sql) => _sql.write(sql);

  /// Appends [name] quoted as a SQL identifier.
  void writeIdentifier(String name) => _sql.write(quoteIdentifier(name));

  /// Appends [text] quoted as a SQL string literal.
  void writeLiteral(String text) => _sql.write(quoteStringLiteral(text));

  /// Appends a `?` placeholder and records [value] to bind.
  void bind(Object? value) {
    _sql.write('?');
    // SQLite has no boolean type.
    _args.add(switch (value) {
      bool b => b ? 1 : 0,
      _ => value,
    });
  }

  /// Appends a comma-separated placeholder list for [values].
  void bindAll(List<Object?> values) {
    for (var i = 0; i < values.length; i++) {
      if (i > 0) _sql.write(', ');
      bind(values[i]);
    }
  }

  /// The accumulated SQL text.
  String get sql => _sql.toString();

  /// The live internal list; callers must not mutate it.
  List<Object?> get args => _args;
}

/// Quotes [name] as a SQL identifier, doubling embedded quotes.
String quoteIdentifier(String name) => '"${name.replaceAll('"', '""')}"';

/// Quotes [text] as a SQL string literal, doubling embedded quotes.
String quoteStringLiteral(String text) => "'${text.replaceAll("'", "''")}'";
