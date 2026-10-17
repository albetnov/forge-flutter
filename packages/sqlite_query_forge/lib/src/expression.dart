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

  /// An FTS5 query; the pattern stays bound.
  Expression match(String query) => Comparison(this, CompareOp.match, query);

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

  /// An FTS5 query; the pattern stays bound.
  Expression match(String query) => Comparison(this, CompareOp.match, query);

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

/// A SQL comparison operator paired with the text it renders.
enum CompareOp {
  /// `=`.
  eq('='),

  /// `<>`.
  neq('<>'),

  /// `>`.
  gt('>'),

  /// `>=`.
  gte('>='),

  /// `<`.
  lt('<'),

  /// `<=`.
  lte('<='),

  /// `LIKE`.
  like('LIKE'),

  /// `MATCH`, for FTS5 full-text queries.
  match('MATCH'),

  /// `BETWEEN`.
  between('BETWEEN'),

  /// `NOT BETWEEN`.
  notBetween('NOT BETWEEN');

  /// Binds this operator to its [sql] text.
  const CompareOp(this.sql);

  /// The SQL keyword or symbol this operator renders.
  final String sql;
}

/// A node that renders SQL and binds its parameters through a [SqlFragment].
sealed class Expression {
  /// A const constructor for subclasses.
  const Expression();

  /// Writes this expression's SQL to [fragment].
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

/// Chainable comparison helpers for any [Expression].
extension ExpressionOps on Expression {
  /// Wraps this expression in parentheses.
  Expression get parenthesized => Parenthesized(this);

  /// Renders this expression as `AS "alias"`.
  Expression alias(String alias) => Aliased(this, alias);

  /// Column-to-column equality. Renders `left = right` binding nothing.
  Expression sameAs(Expression other) =>
      RefComparison(this, CompareOp.eq, other);

  /// `left = ?`, or a reference comparison when [value] is an [Expression].
  Expression eq(Object? value) => _comparison(this, CompareOp.eq, value);

  /// `left <> ?`, or a reference comparison when [value] is an [Expression].
  Expression neq(Object? value) => _comparison(this, CompareOp.neq, value);

  /// `left > ?`, or a reference comparison when [value] is an [Expression].
  Expression gt(Object? value) => _comparison(this, CompareOp.gt, value);

  /// `left >= ?`, or a reference comparison when [value] is an [Expression].
  Expression gte(Object? value) => _comparison(this, CompareOp.gte, value);

  /// `left < ?`, or a reference comparison when [value] is an [Expression].
  Expression lt(Object? value) => _comparison(this, CompareOp.lt, value);

  /// `left <= ?`, or a reference comparison when [value] is an [Expression].
  Expression lte(Object? value) => _comparison(this, CompareOp.lte, value);

  /// An FTS5 query; the pattern stays bound.
  Expression match(String query) => Comparison(this, CompareOp.match, query);
}

/// [name] is emitted unquoted, so only use fixed names.
class FunctionCall extends Expression {
  /// The function name, emitted unquoted.
  final String name;

  /// The argument expressions, rendered in order.
  final List<Expression> arguments;

  /// Whether `DISTINCT` is emitted before the arguments.
  final bool distinct;

  /// Builds a call to [name] over [arguments].
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
  /// The labels and their value expressions, in insertion order.
  final Map<String, Expression> fields;

  /// Builds a `json_object` over [fields].
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

/// A [FunctionCall] to an aggregate such as `COUNT` or `SUM`.
final class Aggregate extends FunctionCall {
  /// Builds an aggregate call over [arguments].
  Aggregate(super.name, super.arguments);

  /// Builds a `DISTINCT` aggregate over [arguments].
  Aggregate.distinct(super.name, super.arguments) : super(distinct: true);
}

/// `left operator ?` with the value bound.
final class Comparison extends Expression {
  /// The left operand, rendered as an expression.
  final Expression left;

  /// The comparison operator.
  final CompareOp operator;

  /// The value bound as the right operand.
  final Object? value;

  /// Compares [left] to [value] with [operator].
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
  /// The left operand.
  final Expression left;

  /// The comparison operator.
  final CompareOp operator;

  /// The right operand.
  final Expression right;

  /// Compares [left] to [right] with [operator], binding nothing.
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
  /// The expression tested for null.
  final Expression left;

  /// Whether the check renders `IS NOT NULL`.
  final bool negated;

  /// Checks [left] for null, negating the test when [negated].
  const NullCheck(this.left, {required this.negated});

  @override
  void writeTo(SqlFragment fragment) {
    left.writeTo(fragment);
    fragment.write(negated ? ' IS NOT NULL' : ' IS NULL');
  }
}

/// `left BETWEEN lower AND upper`, with both bounds bound.
final class Between extends Expression {
  /// The expression tested against the bounds.
  final Expression left;

  /// `BETWEEN` or `NOT BETWEEN`.
  final CompareOp operator;

  /// The inclusive lower bound, bound as a parameter.
  final Object? lower;

  /// The inclusive upper bound, bound as a parameter.
  final Object? upper;

  /// Matches [left] between [lower] and [upper] using [operator].
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

/// `left IN (...)`, with each value bound. An empty list folds to a constant.
final class InList extends Expression {
  /// The expression tested for membership.
  final Expression left;

  /// The candidate values, bound in order.
  final List<Object?> values;

  /// Whether the test renders `NOT IN`.
  final bool negated;

  /// Tests [left] for membership in [values], negating when [negated].
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

/// One `WHEN <condition> THEN <result>` arm of a [CaseWhen].
///
/// The [condition] renders as SQL; the [result] follows the existing rule —
/// an [Expression] renders as a reference, anything else binds as `?`.
final class WhenBranch {
  /// The `WHEN` predicate.
  final Expression condition;

  /// The `THEN` value: a reference when an [Expression], a bound `?` otherwise.
  final Object? result;

  /// Builds one `WHEN` arm from [condition] and [result].
  const WhenBranch(this.condition, this.result);
}

/// `CASE WHEN <cond> THEN <result> ... ELSE <else> END`.
///
/// Conditions render as expressions. Each result (and [orElse]) renders as a
/// reference when it is an [Expression] and binds as `?` otherwise, so
/// `SUM(CASE WHEN ... THEN "amount" ELSE 0 END)` binds only the `0`. A `null`
/// [orElse] omits the `ELSE` clause, which SQLite treats as `ELSE NULL`.
final class CaseWhen extends Expression {
  /// The ordered `WHEN` arms.
  final List<WhenBranch> branches;

  /// The `ELSE` value, omitted when `null`.
  final Object? orElse;

  /// Builds a `CASE` over [branches] with an optional [orElse].
  CaseWhen(this.branches, [this.orElse]) {
    if (branches.isEmpty) {
      throw ArgumentError.value(
        branches,
        'branches',
        'CaseWhen needs at least one WHEN branch.',
      );
    }
  }

  @override
  void writeTo(SqlFragment fragment) {
    fragment.write('CASE');
    for (var i = 0; i < branches.length; i++) {
      final branch = branches[i];
      fragment.write(' WHEN ');
      branch.condition.writeTo(fragment);
      fragment.write(' THEN ');
      final result = branch.result;
      if (result is Expression) {
        result.writeTo(fragment);
      } else {
        fragment.bind(result);
      }
    }
    final fallback = orElse;
    if (fallback != null) {
      fragment.write(' ELSE ');
      if (fallback is Expression) {
        fallback.writeTo(fragment);
      } else {
        fragment.bind(fallback);
      }
    }
    fragment.write(' END');
  }
}

/// Emitted verbatim. Only safe for trusted, static SQL.
final class RawSql extends Expression {
  /// The SQL text emitted verbatim.
  final String sql;

  /// Wraps [sql] for verbatim emission.
  const RawSql(this.sql);

  @override
  void writeTo(SqlFragment fragment) => fragment.write(sql);
}

/// `inner AS "alias"`.
final class Aliased extends Expression {
  /// The expression being aliased.
  final Expression inner;

  /// The alias, quoted as an identifier.
  final String aliasName;

  /// Aliases [inner] as [aliasName].
  const Aliased(this.inner, this.aliasName);

  @override
  void writeTo(SqlFragment fragment) {
    inner.writeTo(fragment);
    fragment.write(' AS ');
    fragment.writeIdentifier(aliasName);
  }
}

/// `(inner)`.
final class Parenthesized extends Expression {
  /// The wrapped expression.
  final Expression inner;

  /// Wraps [inner] in parentheses.
  const Parenthesized(this.inner);

  @override
  void writeTo(SqlFragment fragment) {
    fragment.write('(');
    inner.writeTo(fragment);
    fragment.write(')');
  }
}

/// `left AND right`.
final class Conjunction extends Expression {
  /// The left operand.
  final Expression left;

  /// The right operand.
  final Expression right;

  /// Joins [left] and [right] with `AND`.
  const Conjunction(this.left, this.right);

  @override
  void writeTo(SqlFragment fragment) {
    left.writeTo(fragment);
    fragment.write(' AND ');
    right.writeTo(fragment);
  }
}

/// `left OR right`.
final class Disjunction extends Expression {
  /// The left operand.
  final Expression left;

  /// The right operand.
  final Expression right;

  /// Joins [left] and [right] with `OR`.
  const Disjunction(this.left, this.right);

  @override
  void writeTo(SqlFragment fragment) {
    left.writeTo(fragment);
    fragment.write(' OR ');
    right.writeTo(fragment);
  }
}

/// `NOT (inner)`.
final class Negation extends Expression {
  /// The expression being negated.
  final Expression inner;

  /// Renders `NOT (...)` around [inner].
  const Negation(this.inner);

  @override
  void writeTo(SqlFragment fragment) {
    fragment.write('NOT (');
    inner.writeTo(fragment);
    fragment.write(')');
  }
}

/// `inner COLLATE collation`.
final class Collated extends Expression {
  /// The expression being collated.
  final Expression inner;

  /// The collation name, emitted verbatim.
  final String collation;

  /// Applies [collation] to [inner].
  const Collated(this.inner, this.collation);

  @override
  void writeTo(SqlFragment fragment) {
    inner.writeTo(fragment);
    fragment.write(' COLLATE $collation');
  }
}
