// Builds src/ into dist/:
//  - assets get a content hash in their file name (cache them forever),
//  - index.html references the hashed names and is never cached,
//  - the build version (git SHA) is stamped into index.html.
import { createHash } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const src = path.join(root, "src");
const dist = path.join(root, "dist");
const version = process.env.APP_VERSION || "dev";
const assets = ["app.js", "styles.css"];

await rm(dist, { recursive: true, force: true });
await mkdir(path.join(dist, "assets"), { recursive: true });

let html = await readFile(path.join(src, "index.html"), "utf8");

for (const name of assets) {
  const content = await readFile(path.join(src, name));
  const hash = createHash("sha256").update(content).digest("hex").slice(0, 10);
  const { name: base, ext } = path.parse(name);
  const hashed = `assets/${base}.${hash}${ext}`;
  await writeFile(path.join(dist, hashed), content);
  html = html.replaceAll(`"/${name}"`, `"/${hashed}"`);
}

html = html.replace("__APP_VERSION__", version);
await writeFile(path.join(dist, "index.html"), html);

console.log(`built version ${version} into ${path.relative(process.cwd(), dist)}`);
