---
version: 1
slug: "src-pages-index-astro"
primary_target: "src/pages/index.astro"
related_targets: []
---

# Surface brief: Forge docs landing

Primary target: `src/pages/index.astro`. Mode: Persuade. Scope: single landing route only; package pages, pub.dev, GitHub, and READMEs stay untouched.

Audience: Dart/Flutter builders arriving cold. Job: grasp the Forge philosophy and fit within one screen. Primary action: pick the right package line and start (install snippet, README/pub.dev link).

Proof carried (all real, from repo): one-line philosophy, 4-line departure board (`fetch_forge` standalone; `sqlite_schema_forge` → `sqlite_query_forge` → `sqlite3_driver_forge`), four tabbed code excerpts (fetch `Query` bind; schema `Schema`/`Table`; query `SelectBuilder` filter; driver `Forge` wiring), build-time highlighted with system colors, connection map, `dart pub add` + melos commands. No testimonials, benchmarks, pricing, or invented claims.

Chosen direction: Swiss railway timetable / departure board (locked shape brief; roll key withheld, no seed reference printed). Memorable moment: a dark departure band listing four package lines with times-as-versions and a line selector that highlights the matching code platform and map edge.

Unresolved (builder must not invent): IA beyond landing, API-reference generation, versioning strategy, search, i18n.

## Direction contract

THESIS: The ecosystem reads as an exact timetable, not a marketing hero. Four package lines with termini, connections, and honest times replace centered headline-plus-cards; precision is the persuasion, and the category-default card row is refused.

OWN-WORLD: Near-white paper ground with hairline rules and grid order; one dark ink departure band; a single signal-red reserved for times and status. Tabular numerals everywhere data appears. Line selector, platform numbers, and a connection map drawn as rail edges carry the system with content removed.

STORY: Visitor understands in seconds that Forge is small typed packages with no hidden policy, believes it because code and dependency edges are shown, and acts by choosing a line: copy the install, open the README or pub.dev entry.

FIRST VIEWPORT: Dark departure band across the top with wordmark, four departures, and the primary action beside the board; paper section below opens with philosophy one-liner and the tabbed code excerpts. Primary action sits with the board, never below the fold.

FORM: Assigned timetable direction from the locked shape hand, position 5 of 7 grounded candidates; raised by charged emptiness, instruction traceability, staged pipeline legibility, and pocketable spec strips. seed: none (unavailable)

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
