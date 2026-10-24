import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");

test("build hashes assets and stamps the version", () => {
  execFileSync("node", ["scripts/build.mjs"], {
    cwd: root,
    env: { ...process.env, APP_VERSION: "test-sha" },
  });

  const html = readFileSync(path.join(root, "dist", "index.html"), "utf8");
  assert.match(html, /<meta name="app-version" content="test-sha"/);

  const refs = [...html.matchAll(/"\/(assets\/[^"]+)"/g)].map((m) => m[1]);
  assert.equal(refs.length, 2, "index.html should reference 2 hashed assets");
  for (const ref of refs) {
    assert.match(ref, /\.[0-9a-f]{10}\.(js|css)$/);
    assert.ok(existsSync(path.join(root, "dist", ref)), `${ref} should exist`);
  }
});
