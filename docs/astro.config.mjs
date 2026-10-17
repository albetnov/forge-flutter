// @ts-check
import { defineConfig } from 'astro/config';

// https://astro.build/config
// Deployed as a GitHub Pages *project* site, so the site lives under the
// repository name: https://albetnov.github.io/the_forge_ecosystem/
// `base` must match the repository name for assets and routes to resolve.
export default defineConfig({
  site: 'https://albetnov.github.io',
  base: '/the_forge_ecosystem',
});
