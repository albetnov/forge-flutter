---
name: sqlite-query-forge-expressions
description: Column Expression shortcuts qualify RawSql SqlFragment, bound-args safety, AND-OR precedence.
---

# Expressions

`Column<T>` is a `const` expression node with a phantom `T`, so
`Column<int>.eq` demands `int`. `QualifiedColumn<T>` keeps the type after
`qualify`. Import from `package:sqlite_query_forge/sqlite_query_forge.dart`;
`qualifyAs` needs the opt-in `package:sqlite_query_forge/qualify.dart`.

```dart
users.isActive.eq(true)                    // "is_active" = ?  args [1]
users.name.like('%ada%')                   // pattern stays bound
users.id.inList([1, 2, 3])                 // IN (?, ?, ?)
users.qualify(users.id, 'u').sameAs(tx.qualify(tx.userId, 't'))
users.id.count.gt(1)                       // HAVING COUNT("id") > ?
JsonObject({'id': users.id}).alias('user')
```

## Configuration

| Node | Use |
| --- | --- |
| `Column.id/.integer/.text/.dateTime/.real/.blob` (+ plain `Column(name)`) | Reference + DDL flags. Plain constructor has `type: null` → un-migratable (see schema-bridge). `dateTime` is `TEXT`; `RawSql` default verbatim, `String` default quoted. |
| Comparisons `eq/neq/gt/gte/lt/lte/like/match/between/notBetween/inList/notIn/isNull/isNotNull` | On `Column`, `QualifiedColumn`, and (widened `Object?`) `ExpressionOps`. `like` callers add `%` themselves. `match` takes a `String` FTS5 query and binds it (`<left> MATCH ?`). |
| `sameAs(other)` / passing an `Expression` as the value to `eq/...` | Column-to-column: renders reference, binds nothing (`RefComparison`). Bare `Column` works, no bridge needed. |
| Aggregates `count/countDistinct/sum/avg/min/max`, `FunctionCall`, `JsonObject`, `Collated`, `Negation`, `parenthesized`, `alias` | `JsonObject` keys are string literals, values are expressions; duplicate map keys collapse. `FunctionCall.name` is unquoted — fixed names only. |
| `CaseWhen(branches, [orElse])` + `WhenBranch(condition, result)` | `CASE WHEN <cond> THEN <result> ... ELSE <else> END`. Conditions render as expressions; results/`orElse` render as references when `Expression`, else bind as `?`. Null `orElse` omits `ELSE`. Composes inside `SUM(...)` for conditional aggregates. |
| `Lit(value)` | Literal in an expression position: renders `?`, binds the value (`bool` → `1/0`). For static `FunctionCall` args — `COALESCE(x, const Lit(0))`, `substr(col, const Lit(1), const Lit(10))`. |
| `RawSql(sql)` | Verbatim escape hatch (`*`, `excluded."email"`, `CURRENT_TIMESTAMP`, `last_insert_rowid()`). |
| `qualify` | `table.qualify(col, [alias])` → `"alias"."col"`; `TableSource.reference` is `alias ?? name`. `qualifyAs(alias)` (opt-in import) is the same call on the column. |

## Instance management

All nodes are immutable/`const`. No `dispose`, no lifecycle. `Column.toString()`
is the bare name (debug-friendly); SQL rendering goes through
`writeTo(SqlFragment)`.

## Behavior contracts

- **Values bind, identifiers quote.** One quoting site (`quoteIdentifier`: `"` → `""`; `quoteStringLiteral`: `'` → `''`). `bool` binds as `1/0` (SQLite has no bool). `LIMIT`/`OFFSET` also bind.
- **Empty `IN ()` is constant false.** SQLite rejects `IN ()`, so `inList([])` emits `0` (and `notIn([])` emits `1`) *without rendering the left operand* — `SELECT * WHERE 0`.
- **`AND` binds tighter than `OR`.** `Conjunction`/`andWhere` parenthesize a `Disjunction` operand on either side. Build with `andWhere`/`orWhere`, or call `.parenthesized` by hand when composing `Conjunction`/`Disjunction` directly.
- **`NULL` uses `IS [NOT] NULL`.** Never `= NULL`. `eq(null)` binds `= ?` with null — prefer `isNull`.

## Caveats / workarounds

- `RawSql` is injection surface: only trusted, static SQL. Prefer bound comparisons + `Column` refs; reserve `RawSql` for `*`, `excluded.*`, functions the DSL lacks.
- `Column` carries no table. `users.id.sameAs(...)` renders `"id" = ...` unqualified — qualify in joins or the query is ambiguous. Nothing checks the alias string matches the joined source; compare against `sourceAs(alias).reference`.
- `alias()` quotes the alias as identifier; aliasing *inside* `JsonObject` nests (`json_object(..., "u"."name" AS "name")`) — usually alias the whole object instead.
