import { readFile } from "node:fs/promises";

const lockfile = JSON.parse(await readFile(new URL("../package-lock.json", import.meta.url), "utf8"));
const allowedTarballHost = "registry.npmjs.org";
const failures = [];

for (const [name, entry] of Object.entries(lockfile.packages ?? {})) {
  if (!entry || typeof entry.resolved !== "string") {
    continue;
  }

  let url;
  try {
    url = new URL(entry.resolved);
  } catch {
    failures.push(`${name}: invalid resolved URL`);
    continue;
  }

  if (url.hostname !== allowedTarballHost) {
    failures.push(`${name}: unexpected registry host ${url.hostname}`);
  }
}

if (failures.length > 0) {
  console.error("package-lock.json contains dependencies outside registry.npmjs.org:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}
