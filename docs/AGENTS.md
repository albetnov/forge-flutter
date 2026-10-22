## Development

When starting the dev server, use background mode:

```
astro dev --background
```

Manage the background server with `astro dev stop`, `astro dev status`, and `astro dev logs`.

## Before publishing a package

Publishing is the last step, not the only one. a package whose docs, skills
and version constraints are stale ships a lie to everyone who installs it.

when a package's version or api changes, update all of these before
`dart pub publish`:

- `src/pages/index.astro` — the package card: the `version:` field in the
  `lines` array and the static fallback heading (`<span class="v">`).
- `src/pages/guides/<package>.astro` — the version badge
  (`<span class="ver">`) and the install snippet's constraint. on a 0.x
  package `^0.1.0` means `>=0.1.0 <0.2.0`, so a stale constraint silently
  keeps readers on the old release.
- `packages/<package>/README.md` — the install snippet, plus every
  dependency constraint, which must match the pubspec.
- `packages/<package>/skills/` and the mirrored `skills/` at the repo root —
  the api the skills describe must be the api that ships. the two copies are
  kept identical: edit the package copy, then copy it over.
- `packages/<package>/CHANGELOG.md` — the entry for the version.

then verify, from the repo root:

```sh
cd docs && bun run build
(cd packages/<package> && dart pub publish --dry-run)
python3 tool/release_status.py
```

`tool/release_status.py` compares the local pubspec, pub.dev and the git
tags. it does not read the docs — that check is on you.

## Documentation

Full documentation: https://docs.astro.build

Consult these guides before working on related tasks:

- [Adding pages, dynamic routes, or middleware](https://docs.astro.build/en/guides/routing/)
- [Working with Astro components](https://docs.astro.build/en/basics/astro-components/)
- [Using React, Vue, Svelte, or other framework components](https://docs.astro.build/en/guides/framework-components/)
- [Adding or managing content](https://docs.astro.build/en/guides/content-collections/)
- [Adding styles or using Tailwind](https://docs.astro.build/en/guides/styling/)
- [Supporting multiple languages](https://docs.astro.build/en/guides/internationalization/)
