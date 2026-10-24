const { test, before, after } = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");
const { createHandler, parseOrigins } = require("../src/app");

const FRONTEND = "https://app.example.com";
let server;
let base;

before(async () => {
  server = http.createServer(createHandler({ allowedOrigins: parseOrigins(FRONTEND), version: "test" }));
  await new Promise((resolve) => server.listen(0, resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

test("GET /health returns ok and the version", async () => {
  const res = await fetch(`${base}/health`);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { status: "ok", version: "test" });
});

test("GET /api/hello returns a message", async () => {
  const res = await fetch(`${base}/api/hello`);
  assert.equal(res.status, 200);
  assert.match((await res.json()).message, /Hello/);
});

test("unknown routes return 404", async () => {
  const res = await fetch(`${base}/nope`);
  assert.equal(res.status, 404);
});

test("CORS: allowed origin is echoed back", async () => {
  const res = await fetch(`${base}/api/hello`, { headers: { Origin: FRONTEND } });
  assert.equal(res.headers.get("access-control-allow-origin"), FRONTEND);
  assert.equal(res.headers.get("vary"), "Origin");
});

test("CORS: other origins get no allow header", async () => {
  const res = await fetch(`${base}/api/hello`, { headers: { Origin: "https://evil.example" } });
  assert.equal(res.headers.get("access-control-allow-origin"), null);
});

test("CORS: preflight from allowed origin succeeds", async () => {
  const res = await fetch(`${base}/api/hello`, {
    method: "OPTIONS",
    headers: { Origin: FRONTEND, "Access-Control-Request-Method": "GET" },
  });
  assert.equal(res.status, 204);
  assert.equal(res.headers.get("access-control-allow-origin"), FRONTEND);
  assert.match(res.headers.get("access-control-allow-methods"), /GET/);
});

test("CORS: preflight from unknown origin is rejected", async () => {
  const res = await fetch(`${base}/api/hello`, {
    method: "OPTIONS",
    headers: { Origin: "https://evil.example", "Access-Control-Request-Method": "GET" },
  });
  assert.equal(res.status, 403);
});
