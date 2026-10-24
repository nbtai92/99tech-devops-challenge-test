const express = require("express");
const { Pool } = require("pg");
const Redis = require("ioredis");

const PORT = Number(process.env.PORT || 3000);

const app = express();

const pool = new Pool({
  host: process.env.DB_HOST,
  user: process.env.DB_USER || "postgres",
  password: process.env.DB_PASSWORD || "postgres",
  database: process.env.DB_NAME || "postgres",
  port: Number(process.env.DB_PORT || 5432),
  max: Number(process.env.DB_POOL_MAX || 10),
  // Fail fast instead of waiting forever when the pool is exhausted or the DB is down.
  connectionTimeoutMillis: 2000,
  idleTimeoutMillis: 30000,
  statement_timeout: 5000,
  query_timeout: 5000,
});

// Without this listener, an error on an idle client (e.g. Postgres restarts)
// is an unhandled 'error' event and crashes the whole Node process.
pool.on("error", (err) => {
  console.error("[pg] idle client error:", err.message);
});

const redis = new Redis({
  host: process.env.REDIS_HOST,
  port: Number(process.env.REDIS_PORT || 6379),
  connectTimeout: 2000,
  commandTimeout: 500,
  // Fail commands quickly while Redis is unavailable instead of queueing them.
  maxRetriesPerRequest: 1,
  enableOfflineQueue: false,
});

redis.on("error", (err) => {
  console.error("[redis] error:", err.message);
});

app.get("/api/users", async (req, res) => {
  try {
    // pool.query() checks out a client and always releases it, even on error.
    const result = await pool.query("SELECT NOW()");

    // "last_call" is best-effort tracking: a Redis outage must not fail the request.
    redis.set("last_call", Date.now()).catch((err) => {
      console.warn("[redis] failed to set last_call:", err.message);
    });

    res.json({ ok: true, time: result.rows[0] });
  } catch (err) {
    console.error("[api] /api/users failed:", err.message);
    res.status(503).json({ ok: false, error: "database unavailable" });
  }
});

// Liveness: the process is up and serving HTTP. No dependency checks.
app.get("/status", (req, res) => {
  res.json({ status: "ok" });
});

// Readiness: the API can actually serve traffic (database reachable).
app.get("/ready", async (req, res) => {
  try {
    await pool.query("SELECT 1");
    res.json({ status: "ready", redis: redis.status });
  } catch (err) {
    res.status(503).json({ status: "not ready", error: err.message });
  }
});

const server = app.listen(PORT, () => console.log(`API running on ${PORT}`));

// Graceful shutdown so `docker compose stop` / redeploys don't cut requests.
function shutdown(signal) {
  console.log(`${signal} received, shutting down`);
  server.close(async () => {
    await Promise.allSettled([pool.end(), redis.quit()]);
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 10000).unref();
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
