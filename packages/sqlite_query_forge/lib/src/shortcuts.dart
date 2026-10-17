import 'table.dart';
import 'write_builder.dart';

/// Convenience accessors for the compiled SQL of a [SelectBuilder].
extension SelectBuilderShortcuts<T extends Object> on SelectBuilder<T> {
  /// The compiled SQL, without arguments.
  String toSql() => compile().sql;

  /// The bound arguments of the compiled statement.
  List<Object?> getRawArgs() => compile().args;
}

/// Convenience accessors for the compiled SQL of an [InsertBuilder].
extension InsertBuilderShortcuts on InsertBuilder {
  /// The compiled SQL, without arguments.
  String toSql() => compile().sql;

  /// The bound arguments of the compiled statement.
  List<Object?> getRawArgs() => compile().args;
}

/// Convenience accessors for the compiled SQL of an [UpdateBuilder].
extension UpdateBuilderShortcuts on UpdateBuilder {
  /// The compiled SQL, without arguments.
  String toSql() => compile().sql;

  /// The bound arguments of the compiled statement.
  List<Object?> getRawArgs() => compile().args;
}

/// Convenience accessors for the compiled SQL of a [DeleteBuilder].
extension DeleteBuilderShortcuts on DeleteBuilder {
  /// The compiled SQL, without arguments.
  String toSql() => compile().sql;

  /// The bound arguments of the compiled statement.
  List<Object?> getRawArgs() => compile().args;
}
