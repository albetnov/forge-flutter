---
version: 1
slug: "src-pages-guides-sqlite-query-forge-astro"
primary_target: "src/pages/guides/sqlite-query-forge.astro"
related_targets: []
---

# Surface brief: sqlite_query_forge quick-start guide

Primary target: `src/pages/guides/sqlite-query-forge.astro`. Mode: Read. Scope: single guide route in the established guide frame; chained between sqlite-schema-forge and sqlite3-driver-forge guides.

Audience: Dart/Flutter builders querying SQLite without codegen. Job: grasp sealed/immutable/bound design, read with select/filter/join, write with insert/upsert/returning, transact and inspect compiled SQL, bridge tables back to schema migration. Stops: install, three design ideas, reads, writes, transactions + compiled SQL, schema bridge.

Proof (from sqlite_query_forge README): pub add command, const UsersTable, select with mapper, conditional filter chain, explicit left join with alias, insert/update/delete, onConflict upserts reaching excluded, returning reads, nested transaction joining, compile/toSql/getRawArgs, schemaOf migration, sqflite ForgeExecutor adapter. JSON projections intentionally left to the README.

Structure: band + stops TOC + calm column + code wells + note boxes; onward prev/next along the chain. Unresolved: API reference still open.
