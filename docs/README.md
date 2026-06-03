# SSH Tunnel docs site

The public documentation at <https://christestet.github.io/ssh-tunnel/>, built
with [Astro Starlight](https://starlight.astro.build/).

## Local development

```bash
cd docs
npm ci
npm run dev      # http://localhost:4321/ssh-tunnel/
```

```bash
npm run build    # static site into docs/dist/
npm run preview  # preview the production build
```

## How it stays in sync

`scripts/sync-content.mjs` runs automatically before `dev` and `build` (via the
npm `presync` hook) and generates `src/content/docs/changelog.md` from the
repository's root `CHANGELOG.md` (itself produced by Release Please). That file
is git-ignored — do not edit it by hand.

Everything else under `src/content/docs/` is hand-written Markdown. Add a page
by creating a Markdown file there and registering it in the `sidebar` in
`astro.config.mjs`.

## Deployment

`.github/workflows/docs.yml` builds and deploys to GitHub Pages on every push to
`main` that touches `docs/**` or `CHANGELOG.md`. Enable Pages once under
**Settings → Pages → Build and deployment → "GitHub Actions"**.

## Configuration notes

- The site is served from a sub-path, so `astro.config.mjs` sets
  `base: "/ssh-tunnel"`. Internal links in Markdown use that prefix
  (`/ssh-tunnel/...`). If you move to a custom domain, set `site` to it and
  change `base` to `"/"`.
- `.npmrc` pins installs to the public npm registry. Use `npm ci` for normal
  installs so `package-lock.json` remains the source of truth.
- Run npm installs from a shell without publishing or cloud credentials in the
  environment. Avoid `NPM_TOKEN`, write-scoped `GITHUB_TOKEN`, AWS, GCP, and
  Azure credentials during dependency installation.
