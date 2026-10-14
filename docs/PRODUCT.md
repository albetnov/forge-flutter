# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Primary: Dart/Flutter builders — app developers choosing, evaluating, and integrating Forge packages into Dart/Flutter projects.

Secondary (not primary): evaluators comparing against alternatives, and contributors/maintainers publishing the monorepo. Docs serve builders first.

## Product Purpose

Docs site in `docs/` (Astro) is the full ecosystem hub for The Forge Ecosystem monorepo. It makes it possible for a builder to understand the philosophy once, then learn, compare, and integrate all four packages with guides, API overview, and examples.

Success means a builder can go from “what is Forge?” to working integration without hunting across disconnected READMEs, pub.dev pages, and GitHub folders.

## Positioning

Central curated hub on top of pub.dev/GitHub, not a replacement for them. The position a neighboring docs site could not truthfully copy: one philosophy — small, typed Dart/Flutter packages built as value types with no hidden policy — applied consistently across remote data (`fetch_forge`) and local SQLite (`sqlite_schema_forge` → `sqlite_query_forge` → `sqlite3_driver_forge`).

## Operating Context

Builder workflow: discover philosophy → evaluate fit → install via pub → follow guides/examples → integrate `Query`/`Mutation` with `signals`, or declarative `Schema`/`Table`/`Column` plus query-builder expressions and background-isolate driver → ship.

Contributor workflow exists alongside (melos bootstrap/analyze/test, workspace resolution, per-package versioning) but is not the primary docs job.

Origin (author-confirmed): the packages began as internal project code, extracted and published open so every dependent shares the same code — no private forks.

Environment: desktop/mobile web reading, often alongside an IDE and a running Dart/Flutter project.

## Capabilities and Constraints

Confirmed scope: cover all four packages — `fetch_forge`, `sqlite_schema_forge`, `sqlite_query_forge`, `sqlite3_driver_forge` — with guides, API overview, and examples.

Constraint: package READMEs, CHANGELOGs, and Dart API docs stay authoritative. The site summarizes and links; it does not fork content.

Undecided: exact information architecture, API-reference generation approach, versioning/docs-per-release strategy, search, and i18n. Recorded as open, not to be invented.

Terminology to preserve: `Query`, `Mutation`, `QueryBuilder`, `QueryScope`, `Schema`, `Table`, `Column`, `DatabaseExecutor`, value types, no hidden policy, workspace-only root (`publish_to: none`), dependency graph `schema <- query <- driver` with standalone `fetch_forge`.

## Brand Commitments

Name: The Forge Ecosystem. Existing language from repo: “value types, no hidden policy”, “small, typed Dart/Flutter packages”. Voice stays technical and minimal.

No confirmed logo, palette, typography, or binding Forge-metaphor visual constraint. Do not invent one in product truth.

## Evidence on Hand

Real sources (paths relative to repo root):

- `README.md` — monorepo philosophy, package table, melos commands
- `pubspec.yaml` — workspace members, SDK `^3.13.4`, melos scripts
- `packages/fetch_forge/README.md` — signals-based remote-data model and hello-world
- `packages/sqlite_schema_forge/README.md` — declarative schema + auto-migration
- `packages/sqlite_query_forge/README.md` — declarative query builder
- `packages/sqlite3_driver_forge/README.md` — background-isolate driver, SQLCipher
- `LICENSE` (MIT) — copied per publishable package
- `docs/src/pages/index.astro` — Astro starter placeholder, no product content yet

Absences future work must not fabricate: testimonials, customers, benchmarks, pricing, licensing beyond MIT, deployment claims.

## Product Principles

1. Summarize, don’t supplant — READMEs and code stay canonical.
2. Builder task first — every page moves an integration forward.
3. Philosophy explicit — value types and no hidden policy explain each API choice.
4. Ecosystem coherence — schema, query, driver, and fetch read as one system.
5. No fabrication — only shipped code, real examples, and confirmed facts.
