/// Opt-in sugar for qualifying a column without naming its table.
///
/// Import this alongside the main library for
/// `transactions.userId.qualifyAs('t')` instead of
/// `transactions.qualify(transactions.userId, 't')`. The two are the same call:
/// `Table.qualify` remains the built-in spelling, and this file changes nothing
/// about it.
library;

import 'src/expression.dart';

/// Adds `qualifyAs` to a [Column], qualifying it under a joined alias.
extension ColumnQualify<T extends Object> on Column<T> {
  /// Qualifies this column under [alias], the name a joined source binds.
  ///
  /// The alias is a plain string, matching `Table.qualify`, and nothing checks
  /// that it matches the source the join actually binds.
  QualifiedColumn<T> qualifyAs(String alias) => QualifiedColumn<T>(alias, name);
}
