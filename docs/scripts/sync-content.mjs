// Auto-generates content pages from repository sources so the docs site stays
// in sync without manual copy/paste. Run automatically before `dev`/`build`
// via the npm `presync` hook.
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..", "..");
const contentDir = resolve(here, "..", "src", "content", "docs");

async function syncChangelog() {
  const source = resolve(repoRoot, "CHANGELOG.md");
  const target = resolve(contentDir, "changelog.md");

  let body = await readFile(source, "utf8");
  // Drop the leading "# Changelog" heading; Starlight renders the title from
  // frontmatter and a duplicate H1 looks wrong.
  body = body.replace(/^#\s+Changelog\s*\n+/i, "");

  const frontmatter = [
    "---",
    "title: Changelog",
    "description: Release history for SSH Tunnel, generated from Conventional Commits by Release Please.",
    "tableOfContents: false",
    "editUrl: false",
    "---",
    "",
    "<!-- This file is generated from /CHANGELOG.md by scripts/sync-content.mjs. Do not edit by hand. -->",
    "",
  ].join("\n");

  await writeFile(target, frontmatter + body, "utf8");
  console.log("synced changelog.md from CHANGELOG.md");
}

await syncChangelog();
