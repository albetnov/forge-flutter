import 'sql_fragment.dart';

/// How a column is stored. Carries the DDL, not the Dart type.
enum ColumnType {
  /// A SQLite `INTEGER`.
  integer,

  /// A SQLite `TEXT`.
  text,

  /// A SQLite `REAL`.
  real,

  /// A SQLite `BLOB`.
  blob,
}

/// A column reference, and how the migrator creates it.
///
/// The type parameter is phantom, so `Column<int>.eq` demands an `int` while
/// `Column<String>.eq` demands a `String`.
final class Column<T extends Object> extends Expression {
  /// The name of the column, quoted as an identifier when rendered.
  final String name;

  /// Null for a column built by the plain constructor, which makes it
  /// un-migratable.
  final ColumnType? type;

  /// Whether the column is declared `PRIMARY KEY`.
  final bool primaryKey;

  /// Whether the column is declared `AUTOINCREMENT`.
  final bool autoIncrement;

  /// Whether the column accepts `NULL`.
  final bool nullable;

  /// Whether the column is declared `UNIQUE`.
  final bool unique;

  /// The default written in the column definition; a [RawSql] is emitted
  /// verbatim, any other non-null object is bound as a literal.
  final Object? defaultValue;

  /// The table this column's foreign key references, if any.
  final String? referencesTable;

  /// The column this column's foreign key references, if any.
  final String? referencesColumn;

  /// Builds a column from explicit attributes.
  ///
  /// [type] may be null, which leaves the column un-migratable.
  const Column(
    this.name, {
    this.type,
    this.primaryKey = false,
    this.autoIncrement = false,
    this.nullable = true,
    this.unique = false,
    this.defaultValue,
    this.referencesTable,
    this.referencesColumn,
  });

  /// `INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL`.
  const Column.id([String name = 'id'])
    : this(
        name,
        type: ColumnType.integer,
        primaryKey: true,
        autoIncrement: true,
        nullable: false,
      );

  /// `INTEGER`, with an optional primary key, autoincrement, and default.
  const Column.integer(
    String name, {
    bool primaryKey = false,
    bool autoIncrement = false,
    bool nullable = true,
    bool unique = false,
    int? defaultValue,
    String? referencesTable,
    String? referencesColumn,
  }) : this(
         name,
         type: ColumnType.integer,
         primaryKey: primaryKey,
         autoIncrement: autoIncrement,
         nullable: nullable,
         unique: unique,
         defaultValue: defaultValue,
         referencesTable: referencesTable,
         referencesColumn: referencesColumn,
       );

  /// `TEXT`, with an optional unique constraint and default.
  const Column.text(
    String name, {
    bool nullable = true,
    bool unique = false,
    Object? defaultValue,
  }) : this(
         name,
         type: ColumnType.text,
         nullable: nullable,
         unique: unique,
         defaultValue: defaultValue,
       );

  /// `TEXT`, for a timestamp. A [RawSql] default is written verbatim, so
  /// `CURRENT_TIMESTAMP` reaches SQL unquoted; a `String` one is quoted.
  const Column.dateTime(
    String name, {
    bool nullable = true,
    Object? defaultValue,
  }) : this(
         name,
         type: ColumnType.text,
         nullable: nullable,
         defaultValue: defaultValue,
       );

  /// `REAL`, with an optional default.
  const Column.real(String name, {bool nullable = true, double? defaultValue})
    : this(
        name,
        type: ColumnType.real,
        nullable: nullable,
        defaultValue: defaultValue,
      );

  /// `BLOB`.
  const Column.blob(String name, {bool nullable = true})
    : this(name, type: ColumnType.blob, nullable: nullable);

  @override
  String toString() => name;

  @override
  void writeTo(SqlFragment fragment) => fragment.writeIdentifier(name);

  /// `"name" = ?` with [value] bound.
  Expression eq(T value) => Comparison(this, CompareOp.eq, value);

  /// `"name" <> ?` with [value] bound.
  Expression neq(T value) => Comparison(this, CompareOp.neq, value);

  /// `"name" > ?` with [value] bound.
  Expression gt(T value) => Comparison(this, CompareOp.gt, value);

  /// `"name" >= ?` with [value] bound.
  Expression gte(T value) => Comparison(this, CompareOp.gte, value);

  /// `"name" < ?` with [value] bound.
  Expression lt(T value) => Comparison(this, CompareOp.lt, value);

  /// `"name" <= ?` with [value] bound.
  Expression lte(T value) => Comparison(this, CompareOp.lte, value);

  /// You write the `%` wildcards; the pattern stays bound.
  Expression like(T pattern) => Comparison(this, CompareOp.like, pattern);

  /// `"name" IS NULL`.
  Expression get isNull => NullCheck(this, negated: false);

  /// `"name" IS NOT NULL`.
  Expression get isNotNull => NullCheck(this, negated: true);

  /// `"name" BETWEEN ? AND ?` with both bounds bound.
  Expression between(T lower, T upper) =>
      Between(this, CompareOp.between, lower, upper);

  /// `"name" NOT BETWEEN ? AND ?` with both bounds bound.
  Expression notBetween(T lower, T upper) =>
      Between(this, CompareOp.notBetween, lower, upper);

  /// An empty [values] compiles to a constant false, since SQLite rejects
  /// `IN ()`.
  Expression inList(List<T?> values) => InList(this, values);

  /// `"name" NOT IN (...)` with each value bound.
  Expression notIn(List<T?> values) => InList(this, values, negated: true);

  /// `COUNT("name")`.
  Expression get count => Aggregate('COUNT', [this]);

  /// `COUNT(DISTINCT "name")`.
  Expression get countDistinct => Aggregate.distinct('COUNT', [this]);

  /// `SUM("name")`.
  Expression get sum => Aggregate('SUM', [this]);

  /// `AVG("name")`.
  Expression get avg => Aggregate('AVG', [this]);

  /// `MIN("name")`.
  Expression get min => Aggregate('MIN', [this]);

  /// `MAX("name")`.
  Expression get max => Aggregate('MAX', [this]);
}

/// A column qualified by its table. Renders as `"table"."column"`.
final class QualifiedColumn<T extends Object> extends Expression {
  /// The name the query binds this table under: its alias when the table is
  /// aliased, otherwise its name.
  final String reference;

  /// The name of the column, quoted as an identifier when rendered.
  final String name;

  /// Binds [name] to the table or alias [reference].
  const QualifiedColumn(this.reference, this.name);

  @override
  void writeTo(SqlFragment fragment) {
    fragment.writeIdentifier(reference);
    fragment.write('.');
    fragment.writeIdentifier(name);
  }
}

/// Comparison and aggregate helpers for [QualifiedColumn], mirroring the ones
/// on [Column] but rendering the qualified `"table"."column"` reference.
extension QualifiedColumnOps<T extends Object> on QualifiedColumn<T> {
  /// `"table"."name" = ?` with [value] bound.
  Expression eq(T value) => Comparison(this, CompareOp.eq, value);

  /// `"table"."name" <> ?` with [value] bound.
  Expression neq(T value) => Comparison(this, CompareOp.neq, value);

  /// `"table"."name" > ?` with [value] bound.
  Expression gt(T value) => Comparison(this, CompareOp.gt, value);

  /// `"table"."name" >= ?` with [value] bound.
  Expression gte(T value) => Comparison(this, CompareOp.gte, value);

  /// `"table"."name" < ?` with [value] bound.
  Expression lt(T value) => Comparison(this, CompareOp.lt, value);

  /// `"table"."name" <= ?` with [value] bound.
  Expression lte(T value) => Comparison(this, CompareOp.lte, value);

  /// You write the `%` wildcards; the pattern stays bound.
  Expression like(T pattern) => Comparison(this, CompareOp.like, pattern);

  /// `"table"."name" BETWEEN ? AND ?` with both bounds bound.
  Expression between(T lower, T upper) =>
      Between(this, CompareOp.between, lower, upper);

  /// `"table"."name" NOT BETWEEN ? AND ?` with both bounds bound.
  Expression notBetween(T lower, T upper) =>
      Between(this, CompareOp.notBetween, lower, upper);

  /// `"table"."name" IN (...)` with each value bound.
  Expression inList(List<T?> values) => InList(this, values);

  /// `"table"."name" NOT IN (...)` with each value bound.
  Expression notIn(List<T?> values) => InList(this, values, negated: true);

  /// `"table"."name" IS NULL`.
  Expression get isNull => NullCheck(this, negated: false);

  /// `"table"."name" IS NOT NULL`.
  Expression get isNotNull => NullCheck(this, negated: true);

  /// `COUNT("table"."name")`.
  Expression get count => Aggregate('COUNT', [this]);

  /// `COUNT(DISTINCT "table"."name")`.
  Expression get countDistinct => Aggregate.distinct('COUNT', [this]);

  /// `SUM("table"."name")`.
  Expression get sum => Aggregate('SUM', [this]);

  /// `AVG("table"."name")`.
  Expression get avg => Aggregate('AVG', [this]);

  /// `MIN("table"."name")`.
  Expression get min => Aggregate('MIN', [this]);

  /// `MAX("table"."name")`.
  Expression get max => Aggregate('MAX', [this]);
}

enum CompareOp {
  eq('='),
  neq('<>'),
  gt('>'),
  gte('>='),
  lt('<'),
  lte('<='),
  like('LIKE'),
  between('BETWEEN'),
  notBetween('NOT BETWEEN');

  const CompareOp(this.sql);

  final String sql;
}

sealed class Expression {
  const Expression();

  void writeTo(SqlFragment fragment);
}

/// An [Expression] operand compares as a reference and binds nothing.
///
/// A bare [Column] is a column like any other expression now, so `eq` takes it
/// and renders a reference comparison rather than binding the name.
Expression _comparison(Expression left, CompareOp op, Object? value) =>
    value is Expression
    ? RefComparison(left, op, value)
    : Comparison(left, op, value);

extension ExpressionOps on Expression {
  Expression get parenthesized => Parenthesized(this);

  Expression alias(String alias) => Aliased(this, alias);

  /// Column-to-column equality. Renders `left = right` binding nothing.
  Expression sameAs(Expression other) =>
      RefComparison(this, CompareOp.eq, other);

  Expression eq(Object? value) => _comparison(this, CompareOp.eq, value);

  Expression neq(Object? value) => _comparison(this, CompareOp.neq, value);

  Expression gt(Object? value) => _comparison(this, CompareOp.gt, value);

  Expression gte(Object? value) => _comparison(this, CompareOp.gte, value);

  Expression lt(Object? value) => _comparison(this, CompareOp.lt, value);

  Expression lte(Object? value) => _comparison(this, CompareOp.lte, value);
}

/// [name] is emitted unquoted, so only use fixed names.
class FunctionCall extends Expression {
  final String name;
  final List<Expression> arguments;
  final bool distinct;

  FunctionCall(this.name, this.arguments, {this.distinct = false});

  @override
  void writeTo(SqlFragment fragment) {
    fragment.write('$name(');
    if (distinct) fragment.write('DISTINCT ');
    for (var i = 0; i < arguments.length; i++) {
      if (i > 0) fragment.write(', ');
      arguments[i].writeTo(fragment);
    }
    fragment.write(')');
  }
}

/// `json_object('key', value, ...)`. Renders each key as a string literal and
/// each value as the expression it is, binding nothing.
///
/// The map is keyed by label, so a duplicate key collapses to one field.
final class JsonObject extends Expression {
  final Map<String, Expression> fields;

  const JsonObject(this.fields);

  @override
  void writeTo(SqlFragment fragment) {
    fragment.write('json_object(');
    var first = true;
    fields.forEach((label, value) {
      if (!first) fragment.write(', ');
      first = false;
      fragment.writeLiteral(label);
      fragment.write(', ');
      value.writeTo(fragment);
    });
    fragment.write(')');
  }
}

final class Aggregate extends FunctionCall {
  Aggregate(super.name, super.arguments);

  Aggregate.distinct(super.name, super.arguments) : super(distinct: true);
}

/// `left operator ?` with the value bound.
final class Comparison extends Expression {
  final Expression left;
  final CompareOp operator;
  final Object? value;

  const Comparison(this.left, this.operator, this.value);

  @override
  void writeTo(SqlFragment fragment) {
    left.writeTo(fragment);
    fragment.write(' ${operator.sql} ');
    fragment.bind(value);
  }
}

/// `left operator right` where both sides are expressions. Nothing is bound.
final class RefComparison extends Expression {
  final Expression left;
  final CompareOp operator;
  final Expression right;

  const RefComparison(this.left, this.operator, this.right);

  @override
  void writeTo(SqlFragment fragment) {
    left.writeTo(fragment);
    fragment.write(' ${operator.sql} ');
    right.writeTo(fragment);
  }
}

/// `= NULL` is never true in SQL.
final class NullCheck extends Expression {
  final Expression left;
  final bool negated;

  const NullCheck(this.left, {required this.negated});

  @override
  void writeTo(SqlFragment fragment) {
    left.writeTo(fragment);
    fragment.write(negated ? ' IS NOT NULL' : ' IS NULL');
  }
}

final class Between extends Expression {
  final Expression left;
  final CompareOp operator;
  final Object? lower;
  final Object? upper;

  const Between(this.left, this.operator, this.lower, this.upper);

  @override
  void writeTo(SqlFragment fragment) {
    left.writeTo(fragment);
    fragment.write(' ${operator.sql} ');
    fragment.bind(lower);
    fragment.write(' AND ');
    fragment.bind(upper);
  }
}

final class InList extends Expression {
  final Expression left;
  final List<Object?> values;
  final bool negated;

  InList(this.left, this.values, {this.negated = false});

  @override
  void writeTo(SqlFragment fragment) {
    // The whole predicate is constant, so the left operand is not rendered at
    // all. Emitting it first would produce `"id" 0`, which is a syntax error.
    if (values.isEmpty) {
      fragment.write(negated ? '1' : '0');
      return;
    }

    left.writeTo(fragment);
    fragment.write(negated ? ' NOT IN (' : ' IN (');
    fragment.bindAll(values);
    fragment.write(')');
  }
}

/// Emitted verbatim. Only safe for trusted, static SQL.
final class RawSql extends Expression {
  final String sql;

  const RawSql(this.sql);

  @override
  void writeTo(SqlFragment fragment) => fragment.write(sql);
}

final class Aliased extends Expression {
  final Expression inner;
  final String aliasName;

  const Aliased(this.inner, this.aliasName);

  @override
  void writeTo(SqlFragment fragment) {
    inner.writeTo(fragment);
    fragment.write(' AS ');
    fragment.writeIdentifier(aliasName);
  }
}

final class Parenthesized extends Expression {
  final Expression inner;

  const Parenthesized(this.inner);

  @override
  void writeTo(SqlFragment fragment) {
    fragment.write('(');
    inner.writeTo(fragment);
    fragment.write(')');
  }
}

final class Conjunction extends Expression {
  final Expression left;
  final Expression right;

  const Conjunction(this.left, this.right);

  @override
  void writeTo(SqlFragment fragment) {
    left.writeTo(fragment);
    fragment.write(' AND ');
    right.writeTo(fragment);
  }
}

final class Disjunction extends Expression {
  final Expression left;
  final Expression right;

  const Disjunction(this.left, this.right);

  @override
  void writeTo(SqlFragment fragment) {
    left.writeTo(fragment);
    fragment.write(' OR ');
    right.writeTo(fragment);
  }
}

final class Negation extends Expression {
  final Expression inner;

  const Negation(this.inner);

  @override
  void writeTo(SqlFragment fragment) {
    fragment.write('NOT (');
    inner.writeTo(fragment);
    fragment.write(')');
  }
}

final class Collated extends Expression {
  final Expression inner;
  final String collation;

  const Collated(this.inner, this.collation);

  @override
  void writeTo(SqlFragment fragment) {
    inner.writeTo(fragment);
    fragment.write(' COLLATE $collation');
  }
}
