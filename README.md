# The Forge Ecosystem

Monorepo workspace root for the Forge ecosystem — small, typed Dart/Flutter
packages that share one philosophy: value types, no hidden policy.

This root is **workspace-only** (`publish_to: none`). Nothing is imported
from here; every package lives under `packages/` and is published (or not)
on its own version.

## Packages

| Package | What | Stack |
| --- | --- | --- |
| [`fetch_forge`](packages/fetch_forge) | Cached, retryable, reactive remote data on top of `signals` (`Query`, `Mutation`, `QueryBuilder`, `QueryScope`) | Flutter (core is pure Dart) |
| [`sqlite_schema_forge`](packages/sqlite_schema_forge) | Declarative SQLite schema + auto-migration engine | Dart |
| [`sqlite_query_forge`](packages/sqlite_query_forge) | Zero-cost declarative SQLite query builder (sealed expressions, bound args) | Dart, depends on `sqlite_schema_forge` |
| [`sqlite3_driver_forge`](packages/sqlite3_driver_forge) | Background-isolate driver over `package:sqlite3`, implements both forge executor contracts, SQLCipher support | Dart, depends on query + schema |

Dependency graph: `schema <- query <- driver`. `fetch_forge` is standalone.

## Commands

```sh
dart pub global activate melos

melos bootstrap   # pub get everywhere
melos run analyze # dart analyze --fatal-infos, all packages
melos run test    # dart test (sqlite_*) + flutter test (fetch_forge)
melos run format  # dart format .
melos run publish:dry  # dry-run only, never publishes for real
```

Native Pub workspace also works: root `pubspec.yaml` lists `workspace:`,
each member sets `resolution: workspace`. Melos sits on top because
`fetch_forge` needs Flutter while the sqlite trio is pure Dart.

## Skills (AI)

Authored skills live with their package (`packages/<pkg>/skills/<pkg>-<skill>/SKILL.md`,
prefixed per the [package-skills convention](https://dart.dev/tools/pub/package-skills))
so they ship to pub.dev and install via `dart run skills@ get`, and are mirrored
at root `skills/<pkg>-<skill>/SKILL.md` so `npx skills` can discover them in one
place. Edit the package copy, then re-mirror (copy the skill dir to root `skills/`).

```sh
ls skills/  # 14 mirrored skills, one dir per SKILL.md
```

Third-party `.agents/skills` (e.g. `fetch_forge/.agents/skills/signals-*`)
stay where they are and are never published (see `fetch_forge/.pubignore`).

## Release

Each package versions independently, starting at `0.1.0` for the fresh
monorepo. `CHANGELOG.md` per package, `LICENSE` (MIT) copied into every
publishable package (pub.dev requires it per package, not just at root).
