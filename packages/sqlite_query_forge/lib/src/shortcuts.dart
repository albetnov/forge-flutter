import 'table.dart';
import 'write_builder.dart';

extension SelectBuilderShortcuts<T extends Object> on SelectBuilder<T> {
  String toSql() => compile().sql;

  List<Object?> getRawArgs() => compile().args;
}

extension InsertBuilderShortcuts on InsertBuilder {
  String toSql() => compile().sql;

  List<Object?> getRawArgs() => compile().args;
}

extension UpdateBuilderShortcuts on UpdateBuilder {
  String toSql() => compile().sql;

  List<Object?> getRawArgs() => compile().args;
}

extension DeleteBuilderShortcuts on DeleteBuilder {
  String toSql() => compile().sql;

  List<Object?> getRawArgs() => compile().args;
}
