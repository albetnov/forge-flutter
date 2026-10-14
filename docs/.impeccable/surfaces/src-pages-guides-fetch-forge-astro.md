---
version: 1
slug: "src-pages-guides-fetch-forge-astro"
primary_target: "src/pages/guides/fetch-forge.astro"
related_targets: []
---

# Surface brief: fetch_forge quick-start guide

Primary target: `src/pages/guides/fetch-forge.astro`. Mode: Read. Scope: single guide route plus a Guides entry in the landing masthead; no guides index yet, no sqlite guides yet.

Audience: Dart/Flutter builders who chose fetch_forge on the landing page. Job: go from install to working reads, writes, and widgets in one sitting. Primary task: follow six stops — install, Query + QueryClient, Mutation, Flutter widgets, two recipes, scope table.

Proof carried (all derived from packages/fetch_forge/README.md): pubspec blocks, CLI walkthrough, hello-world Query, bind/computed signals, record variables, cacheKey mapping, shared client, mutate/mutateAsync, write-then-refetch loop, QueryBuilder/QueryScope, demo command, optimistic update, invalidate-after-write, full not-included table.

Chosen structure: timetable frame (dark band with title + version/pub.dev/README pills, stops TOC) around a calm 70ch reading column; code wells and scope table at full width; one signature move (stops TOC + platform-coded captions). No new visual world: inherits Departure Board tokens.

Unresolved: guides index design, sqlite guide order, API-reference generation. Builder must not invent behavior beyond the README.
