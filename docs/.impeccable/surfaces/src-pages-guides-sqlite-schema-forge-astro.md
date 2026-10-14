---
version: 1
slug: "src-pages-guides-sqlite-schema-forge-astro"
primary_target: "src/pages/guides/sqlite-schema-forge.astro"
related_targets: []
---

# Surface brief: sqlite_schema_forge quick-start guide

Primary target: `src/pages/guides/sqlite-schema-forge.astro`. Mode: Read. Scope: single guide route in the established guide frame; chained between fetch-forge and sqlite-query-forge guides.

Audience: Dart/Flutter builders adding local SQLite schema. Job: declare desired state, migrate with auto-diffing, preview and control plans, relate keys/FTS/triggers. Stops: install, declare, migrate/preview/control, keys/search/triggers.

Proof (from sqlite_schema_forge README): pub add command, Schema/Table quick start, migrate call with user_version output, onUpgrade destructive flow, plan dry run, applyPlan versionless apply, FK declaration, FTS5 binding, ftsSync/custom triggers. No invented behavior. No reference to internal predecessors anywhere on this route.

Structure: band + stops TOC + calm column + code wells + note boxes; onward prev/next along the chain. Unresolved: API reference still open.
