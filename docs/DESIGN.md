---
name: The Forge Ecosystem Docs
description: A railway-timetable world for small, typed packages with no hidden policy.
colors:
  signal-red: "#b3271e"
  board-red: "#ff8a7a"
  ink: "#16202c"
  ink-soft: "#43536a"
  board: "#141c28"
  board-rule: "#2a3547"
  board-ink: "#f2efe6"
  board-soft: "#b9c2d0"
  paper: "#fbfaf6"
  paper-deep: "#f3efe4"
  rule: "#e0d9c6"
  white: "#ffffff"
  oxide: "#8f1f18"
typography:
  display:
    fontFamily: "-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica Neue, Arial, sans-serif"
    fontSize: "clamp(2rem, 5vw, 3.25rem)"
    fontWeight: 800
    lineHeight: 1.08
    letterSpacing: "-0.025em"
  headline:
    fontFamily: "-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica Neue, Arial, sans-serif"
    fontSize: "clamp(1.5rem, 3vw, 2rem)"
    fontWeight: 800
    lineHeight: 1.2
    letterSpacing: "-0.02em"
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica Neue, Arial, sans-serif"
    fontSize: "1.0625rem"
    fontWeight: 400
    lineHeight: 1.6
  label:
    fontFamily: "ui-monospace, SF Mono, Menlo, Consolas, monospace"
    fontSize: "0.75rem"
    fontWeight: 400
    letterSpacing: "0.08em"
  title:
    fontFamily: "-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica Neue, Arial, sans-serif"
    fontSize: "1rem"
    fontWeight: 700
  small:
    fontFamily: "-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica Neue, Arial, sans-serif"
    fontSize: "0.9375rem"
  caption:
    fontFamily: "ui-monospace, SF Mono, Menlo, Consolas, monospace"
    fontSize: "0.875rem"
  map:
    fontFamily: "ui-monospace, SF Mono, Menlo, Consolas, monospace"
    fontSize: "11px"
  code:
    fontFamily: "ui-monospace, SF Mono, Menlo, Consolas, monospace"
    fontSize: "0.8125rem"
    lineHeight: 1.65
rounded:
  board: "14px"
  card: "12px"
  chip: "6px"
  focus: "4px"
  well: "8px"
  pill: "999px"
spacing:
  gutter: "1.5rem"
  container: "72rem"
  section-top: "3.5rem"
components:
  button-primary:
    backgroundColor: "{colors.signal-red}"
    textColor: "#ffffff"
    rounded: "{rounded.pill}"
    padding: "0.7rem 1.4rem"
  button-primary-hover:
    backgroundColor: "#8f1f18"
    textColor: "#ffffff"
    rounded: "{rounded.pill}"
    padding: "0.7rem 1.4rem"
  button-ghost:
    backgroundColor: "{colors.board}"
    textColor: "{colors.board-ink}"
    rounded: "{rounded.pill}"
    padding: "0.7rem 1.4rem"
---

# Design System: The Forge Ecosystem Docs

## Overview

**Creative North Star: "The Departure Board"**

Every surface reads as an exact railway timetable, not a marketing hero. Packages are lines with termini, connections, and honest times; precision is the persuasion. The page opens on a dark ink departure band and continues on near-white paper ruled with hairlines, so density lives in the board and air lives everywhere else. Type is a grotesk-first system voice with tabular numerals wherever data appears; the single signal red is spent only on times and status, never on decoration.

Motion is one authored moment: selecting a departure sweeps the highlight across board row, spec strip, and map stops together. Everything else is instant and legible by default.

**Key Characteristics:**
- Timetable grammar: platforms, lines, termini, connections, exact versions as times.
- One dark band, one red, paper everywhere else.
- Tabular numerals on all data; mono for code, times, and spec labels.
- Precision over warmth; copy stays technical and minimal.

## Colors

Paper ground with a single ink band and one red reserved for times and status.

### Primary
- **Signal Red** (#b3271e): times, version numerals, status accents, the primary action. Its rarity is the point.

### Secondary
- **Board Ember** (#ff8a7a): the red translated onto the dark departure band for times, versions, and the selected-line marker.

### Neutral
- **Ink** (#16202c): body text, masthead rule, footer rule.
- **Ink Soft** (#43536a): secondary text on paper, tinted from the ink hue, never gray.
- **Departure Ink** (#141c28): the departure band ground.
- **Board Line** (#2a3547): hairlines and chips on the dark band.
- **Board Paper** (#f2efe6): primary text on the dark band.
- **Board Mist** (#b9c2d0): secondary text on the dark band.
- **Paper** (#fbfaf6): page ground, near-white rather than cream.
- **Paper Deep** (#f3efe4): scrollbar track and sunken wells.
- **Hairline** (#e0d9c6): rules and card borders on paper.

### Named Rules (optional, powerful)
**The One Red Rule.** Signal red appears on times, status, and one action per viewport. Anything else wanting emphasis uses weight or size.

## Typography

**Display Font:** system sans stack (with Helvetica Neue, Arial fallback)
**Body Font:** system sans stack (with Helvetica Neue, Arial fallback)
**Label/Mono Font:** ui-monospace stack (SF Mono, Menlo, Consolas fallback)

**Character:** grotesk-first, tabular, ledger-plain. Headlines carry tight tracking and heavy weight; data speaks in mono with tabular numerals; labels run small, tracked, uppercase.

### Hierarchy
- **Display** (800, clamp(2rem, 5vw, 3.25rem), 1.08, -0.025em): board headline only, balanced across two to three lines.
- **Headline** (800, clamp(1.5rem, 3vw, 2rem), 1.2, -0.02em): paper section titles.
- **Body** (400, 1.0625rem, 1.6): prose and standfirsts, 65–75ch measure on standfirsts.
- **Label** (400, 0.75rem, tracked 0.08em, uppercase): spec terms, platform chips, status.
- **Code** (400, 0.8125rem, 1.65): snippets and commands with horizontal scroll inside their wells, never the page.

### Named Rules (optional)
**The Tabular Data Rule.** Any numeral a visitor compares (versions, times, specs) sets tabular-nums. Proportional figures never appear in data.

## Layout

One centered column (72rem max, 1.5rem gutters). Sections stack vertically with generous separation: 3.5rem of air above each paper heading, 0.5rem below it. The board holds the departures list, spec strip, and actions in a single band; code platforms and command wells pair into two columns above 56rem and stack below it, with board rows linearizing to platform-plus-text stacks at the same breakpoint.

## Elevation & Depth

Depth comes from two offset shadows with soft blur, never from borders piled under shadows.

### Shadow Vocabulary (if applicable)
- **Board lift** (`box-shadow: 10px 14px 28px rgba(20, 28, 40, 0.28)`): the departure band floats over paper.
- **Card rest** (`box-shadow: 8px 12px 24px rgba(22, 32, 44, 0.1)`): code platforms, connection map, and paper cards sit one level up.

### Named Rules (optional)
**The Two Altitudes Rule.** A surface is either the board (lift) or a card (rest) or flat paper. No intermediate shadows exist.

## Shapes

Rectangular timetable plates with softly cut corners: 14px on the departure band, 12px on cards and wells, 6px on platform chips, full pills only for small controls (primary action, ghost link, copy buttons). Hairline borders define regions; radius never decorates alone.

## Components

### Buttons
- **Shape:** full pill (999px).
- **Primary:** Signal Red ground with white text, 0.7rem vertical and 1.4rem horizontal padding.
- **Hover / Focus:** deepens toward dark oxide (#8f1f18); keyboard focus takes a 2px Signal Red outline offset 3px.
- **Secondary / Ghost / Tertiary (if applicable):** ghost is a hairline pill on the dark band in Board Paper with mono sizing; hover brightens the border.

### Departure rows
- **Style:** full-width buttons gridded as platform chip, package name, version time, run description, status; hairline separators; 3px transparent left edge that ignites in Board Ember when selected.
- **State:** `aria-pressed` marks the selected line and drives the spec strip plus map highlight in one motion.

### Code platforms
- **Corner Style:** 12px white wells with hairline borders and card-rest shadow.
- **Header:** mono caption with red platform code (P1, P2) and a pill copy control that confirms with a "Copied" label.
- **Body:** mono excerpt with horizontal scroll contained inside the well.
- **Highlighting:** build-time token colors only — bold Ink keywords, Dark Oxide strings, Ink Soft italic comments. No new hues enter code.

### Excerpt tabs
- **Style:** mono pill buttons; unselected are hairline pills on paper with red platform codes, selected is an Ink pill with Ember code.
- **Behavior:** one visible panel at a time, `tablist` semantics with arrow-key roving tabindex and automatic activation; copy always takes the visible excerpt.

### Connection map
- **Style:** white card holding a crisp vector rail diagram: open-circle stops, solid edges for the SQLite chain, a dashed edge for the standalone fetch line; hot stops and edges fill in Signal Red on selection.

### Command wells
- **Style:** dark ink wells in mono with dimmed comments; install commands on one side, monorepo melos commands on the other.

### Guide frame (Read surfaces)
- **Band:** slimmer dark opener with title, lede, and pill meta (version, pub.dev, README source); same lift shadow as the departure board.
- **Stops TOC:** hairline-ruled anchor list with red mono stop codes; navigation stays standard, never decorative.
- **Notes and scope tables:** hairline boxes and tables in the world's type; note lead-ins run inline in mono red, never as kickers above headings.

## Do's and Don'ts

Concrete visual guardrails grounded in the shipped landing page.

### Do:
- **Do** spend Signal Red only on times, status, and one action per viewport.
- **Do** set every comparable numeral tabular (`font-variant-numeric: tabular-nums`).
- **Do** theme browser surfaces from the palette: red text selection, red focus rings, ink scrollbar, 4px underline offsets.
- **Do** quote code and commands verbatim from the package READMEs; abridge openly, never paraphrase APIs.
- **Do** keep the primary action inside the departure band, above the fold.

### Don't:
- **Don't** build centered headline-plus-card heroes or equal icon-plus-text card rows; the timetable is the composition.
- **Don't** put kickers or eyebrows above headings; headings carry their own weight.
- **Don't** use gradient text, glass blur, or hard offset block shadows anywhere in this world.
- **Don't** invent testimonials, benchmarks, pricing, or availability claims the READMEs do not make.
- **Don't** let code wells scroll the page; overflow scrolls inside the well.
