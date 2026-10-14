---
name: sqlite-query-forge-select
description: Typed SELECTs with Forge.selectFrom, SelectBuilder chain, terminals getMany/getSingle/getFirst/count, compile-only usage.
---

# `SelectBuilder<T>`

Immutable, chainable read. Build through `Forge.selectFrom(table)` so the
table mapper and executor are attached. Import from
`package:sqlite_query_forge/sqlite_query_forge.dart`.

```dart
final forge = Forge(executor);
final users = await forge.selectFrom(usersTable)
  .where(usersTable.isActive.eq(true))
  .orderBy([OrderBy(usersTable.name)])
  .limit(10)
  .getMany();
```

## Configuration

| Chain | Meaning |
| --- | --- |
| `select([cols])` | Replaces projection. Empty (default) means `*`. List is copied. |
| `distinct({value=true})` | Toggles `DISTINCT`. |
| `where(e)` | Replaces filter. `andWhere`/`orWhere` accumulate; with no prior `where` they behave as `where`. |
| `groupBy([...])` / `having(e)` | Grouping. `groupBy([])` throws; `having` without `groupBy` throws. |
| `orderBy(keys)` / `thenBy(expr, [order])` | `orderBy` replaces, `thenBy` appends. |
| `limit(n)` / `offset(n)` | Bound as `?` args, in textual order. |
| `join/leftJoin/crossJoin` | `join(src, on:)` inner, `leftJoin(src, on:)` left, `crossJoin(src)` no `ON`. |
| `map(fn)` | Re-types `T` around a raw-row fn. Only `map` changes `T`. |
| `compile()` / `toSql()` + `getRawArgs()` | SQL preview, no executor needed (`shortcuts.dart`). |

`Table` side: `source`, `sourceAs(alias)`, `qualify(col, [alias])`, `mapRows`.

## Terminals

- `getMany()` — `List<T>` through table mapper.
- `getSingle()` — exactly 1 row; throws `ForgeCardinalityError(actual)` on 0 or >1. Adds `LIMIT 2` unless caller set one.
- `getFirst()` — first row or `null`. Adds `LIMIT 1` unless caller set one.
- `count()` — row count without transferring rows. Preserves joins + `where` + `HAVING`; drops `ORDER BY`/`LIMIT`/`OFFSET`. Grouped or `DISTINCT` query is wrapped as `SELECT COUNT(*) AS "count" FROM (inner)`.
- `Forge.query(stmt)` — raw `Statement` returning `List<Map>` (bypasses mapper).

## Instance management

There is none. Builders are immutable values — each call returns a new
builder, the old one is untouched. No `dispose`, no timers, no cache.
The executor stays owned by the caller; `Forge` never closes it.
A builder built without executor (`SelectBuilder(SelectStatement())`
by hand) throws `StateError` on terminals — build via `Forge`.

## Behavior contracts

- **Bound, never inlined.** Every runtime value is a `?` arg (`bool` → `1/0`).
- **`AND` paren rule.** `andWhere` parenthesizes either side when it is a `Disjunction`, so `a OR b AND c` compiles as `(a OR b) AND c`. `orWhere` needs no parens (`OR` is associative).
- **`count` reads by position.** Takes `rows.first.values.first`, accepts `int`/`num` (float `3.0` → `3`), throws on non-numeric, returns `0` on empty. The `AS "count"` alias exists because some drivers key bare `COUNT(*)` by expression text.
- **Missing mapper fails loudly.** `getMany`/`getFirst` without mapper throw `StateError`; `getSingle` with `!` on null mapper. Use `selectFromSource(src, mapper)` or `.map(fn)` for joins/projections.

## Caveats

- `where` replaces — chaining two `where` keeps only the last. Use `andWhere`/`orWhere` to accumulate.
- `count()` requires `FROM`; `SelectBuilder(SelectStatement()).count()` throws.
- Bare `Column.sameAs` renders unqualified (`"id" = ...`); in joins qualify both sides (`table.qualify(col, alias)`) and match the alias to `sourceAs(alias).reference` or the SQL references a table never bound.
- `SubquerySource(inner)` needs an explicit alias-free wrap; it renders `(inner)` with no `AS`.
