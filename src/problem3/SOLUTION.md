# Problem 3: Debugging issues within system

**Reported symptom:** "The API is unreliable and sometimes inaccessible."

The stack is NGINX → Node.js API → Postgres and Redis, run with Docker Compose.

> Note: the supplied README is titled "Problem 4" because the upstream repo was renumbered; this is the Problem 3 task.

## Summary

There was no single bug. Two problems make the API fail:

- **always fail:** NGINX sends traffic to the wrong port;
- **sometimes fail:** the API leaks DB connections and crashes when Postgres restarts.

On top of that, nothing in the setup recovers on its own: no healthchecks, no restart policy, and no timeouts. Any small failure turns into an outage that lasts until someone notices.

## Problems found

All of these were **found by reading the code and config**. The last column shows which `verify.sh` check reproduces each one at runtime.

| # | Problem | Where | Symptom | Reproduced by |
|---|---|---|---|---|
| 1 | NGINX proxies to `api:3001`, but the API listens on `3000` | `nginx/conf.d/default.conf` | Every `/api/*` request returns **502 Bad Gateway** | check 1 |
| 2 | DB client is not released when the query fails (`db.release()` is skipped by the `catch`) | `api/src/index.js` | Each failed query leaks one of the 10 pool connections. Once they are gone, requests **hang** | check 3 |
| 3 | No `pool.on('error')` handler | `api/src/index.js` | If Postgres restarts or drops connections, the error on an idle client is unhandled and **the Node process crashes** | check 4 |
| 4 | No restart policy in Compose | `docker-compose.yml` | After the crash in #3 the API **stays down** and NGINX returns 502 until someone restarts it | check 4 |
| 5 | No timeouts: pool waits forever, Redis queues commands while disconnected | `api/src/index.js` | When the DB or Redis is slow or down, requests **hang** instead of failing fast | checks 3, 5 |
| 6 | A Redis failure fails the whole request, even though Redis is only used to store `last_call` | `api/src/index.js` | A Redis outage takes the API down too | checks 5, 6 |
| 7 | `depends_on` only waits for containers to *start*, not to be *ready*; no healthchecks | `docker-compose.yml` | Flaky startup: the API can come up before Postgres accepts connections | config review only (timing-dependent) |
| 8 | NGINX resolves `api` once at startup and caches the IP | `nginx/conf.d/default.conf` | If the API container gets a new IP, NGINX keeps calling the old one → 502 until NGINX restarts | check 7 |
| 9 | `init.sql` lowers `max_connections` to 20 (the default is 100) | `postgres/init.sql` | Not mounted today, but if mounted it makes connection exhaustion much easier to hit | config review only |

Smaller issues:

- DB credentials hardcoded in code and Compose;
- the container runs as root;
- no liveness/readiness endpoint reachable through NGINX;
- Postgres data has no volume;
- the empty `nginx/nginx.conf` is not used and would break NGINX if mounted.

## How I diagnosed them

I followed the request path from the outside in: NGINX config → API code → dependencies. For "sometimes inaccessible", I look for anything that can make a working system stop working: crashes, leaks, hangs, and lack of recovery. Then I wrote `scripts/verify.sh` to turn each finding into a runtime check.

On the original code, NGINX never reaches the API (#1), so any test that goes through NGINX would only show that one bug. That is why the API behaviour checks (3–6) call the API **directly inside its container**, and only routing, load and DNS (1, 2, 7) go through NGINX.

1. **Port mismatch (#1):** `proxy_pass http://api:3001` vs `app.listen(3000)`. Expected in the NGINX error log: `connect() failed (111: Connection refused) while connecting to upstream`.
2. **Connection leak (#2):** `db.release()` sits inside the `try` after the query, so any exception skips it. The pool has a default size of 10, so after 10 failed queries every request waits for a connection that never comes back. With no `connectionTimeoutMillis`, it waits forever.
   - **To reproduce it:** a healthy `SELECT NOW()` never fails, so check 3 injects a failure. It shadows `now()` with a function that raises, for new DB sessions only, sends 15 requests, then removes the injection.
   - **The original code should** answer the first 10 with 500, hang on the rest, and never recover.
   - **I verified the injection itself on PostgreSQL**, including with a non-default user/database:
     - `SELECT NOW()` fails while `SELECT 1` still works;
     - cleanup restores normal behaviour;
     - wrong credentials are detected as a setup failure.
3. **Crash on Postgres restart (#3, #4):** node-postgres emits `error` on the pool when an idle client loses its connection. Without a listener, Node treats it as unhandled and exits. With no restart policy, the API stays down. Check 4 restarts Postgres right after a request.
4. **Hangs (#5, #6):** With default settings, ioredis keeps retrying a command while Redis is down, and the handler awaits it. Checks 5 and 6 stop Redis at runtime and start the API without Redis.
5. **Startup and DNS (#7, #8):** Neither Compose nor NGINX waits for readiness, and NGINX has no `resolver`, so the upstream IP is fixed at startup. Check 7 moves the API to a new IP. Recreating a container does not guarantee a new IP, so the script compares the IP before and after and reports INCONCLUSIVE if it did not change.

## Fixes applied

**NGINX (`nginx/conf.d/default.conf`)**

- Point to the correct port: `api:3000`.
- Use Docker's DNS (`resolver 127.0.0.11 valid=10s`) with a variable in `proxy_pass`, so the API container is re-resolved after it is recreated.
- Add connect/read timeouts, forwarding headers, and an access log with upstream timings.
- Expose `/status` for external uptime checks.

**API (`api/src/index.js`)**

- Use `pool.query()`, which always releases the client, even on errors (fixes the leak).
- Add `pool.on('error')` and `redis.on('error')` handlers so connection errors are logged, not fatal.
- Add timeouts:
  - `connectionTimeoutMillis: 2000` and `statement_timeout: 5000` for the pool;
  - `commandTimeout: 500` and offline queue disabled for Redis, so commands fail fast instead of queueing.
- Make the Redis write **best-effort**: it is only tracking `last_call`, so a Redis outage no longer fails the request. *Assumption: `last_call` is not business-critical.*
- Return **503** (not 500) when the DB is unavailable, which is more accurate for clients and alerts.
- Add `/ready` (checks the DB) next to the existing `/status` (process alive).
- Move config to env vars and add graceful shutdown on SIGTERM.

**Compose (`docker-compose.yml`)**

- Healthchecks for Postgres (`pg_isready`), Redis (`redis-cli ping`) and the API (`/ready`).
- `depends_on`: the API waits for Postgres to be **healthy** (it cannot work without it) but only for Redis to be **started**. Redis is optional, so an unhealthy Redis must not block startup.
- `restart: unless-stopped` on every service, so a process that crashes (exits) is restarted automatically. An `unhealthy` container is not restarted by Compose (see "Prevent").
- Credentials from `.env` (see `.env.example`), a named volume for Postgres data, and `init: true` so signals reach Node.
- Removed the obsolete `version:` key.

**Other**

- `postgres/init.sql`: removed `max_connections = 20` and documented why.
- `api/Dockerfile`: `NODE_ENV=production`, production-only deps, run as the non-root `node` user, plus `.dockerignore`.

## Verification

```bash
cd src/problem3
cp .env.example .env
./scripts/verify.sh
```

The script starts the stack and runs 7 isolated checks (the API is restarted between them). Checks 1, 2 and 7 go through NGINX; checks 3–6 call the API directly, so a routing bug cannot hide an API bug. Postgres credentials are read from the running container, so they follow `.env`.

1. **Routing:** `/`, `/api/users` and `/status` return 200.
2. **Load:** 300 requests at 20 concurrent, all 200. This only shows the happy path is stable; it does **not** exercise the leak.
3. **Connection leak:** the script first confirms the injected failure works (a new session's `SELECT NOW()` must fail); if not, the check is INCONCLUSIVE, never PASS. It also requires all 15 responses to be errors. Then those 15 failing queries (more than the pool size) must return errors instead of hanging, and the API must recover once queries succeed again.
4. **Postgres restart:** the API process must not crash (container state and restart count are compared), and must serve again.
5. **Redis outage at runtime:** `/api/users` still returns 200, in under 1 s.
6. **API starts while Redis is down:** it becomes ready and serves.
7. **API on a new IP:** NGINX must follow it. INCONCLUSIVE if Docker gave back the same IP.

If routing through NGINX is broken (check 1 fails), checks 2 and 7 are reported INCONCLUSIVE instead of failing for the wrong reason.

Expected on `main` (original code): check 1 fails (port), check 3 fails (leak + hang), check 4 fails (crash), and checks 5–6 fail or are slow (Redis). Expected on this branch: all PASS, with check 7 possibly INCONCLUSIVE.

**Status:** these results are pending a run on a machine with Docker; the environment I wrote this in could not pull images. Until then, the findings above come from code review, and the checks are how to confirm them.

Results: _[paste `verify-main.txt` and `verify-fix.txt`]_

## Monitoring & alerts I would add

| Signal | Alert |
|---|---|
| NGINX 5xx rate (especially 502/503/504) | > 1% for 5 min |
| p95/p99 latency on `/api/*` (from `rt` / `urt` in the access log) | p99 above the SLO for 5 min |
| API container restarts / unhealthy healthcheck | Any restart loop, or unhealthy > 1 min |
| External uptime check on `/status` (process alive) | 2 consecutive failures |
| Synthetic check on `/api/users` (exercises the DB path, like a user) | Any 5xx or > 1 s, 2 consecutive times |
| Postgres connections used vs `max_connections`; pool waiting clients | > 80% |
| Redis availability and command errors | Down > 1 min (warning only, since the API degrades gracefully) |
| Log patterns: `connect() failed`, `idle client error`, `ECONNREFUSED` | Spike above baseline |

## How I would prevent this in production

- **Health and recovery built in.** In Compose, the restart policy restarts a container when its process **exits**. The healthcheck only gates startup order and marks the container `unhealthy`; Compose does **not** restart a container just for being unhealthy. In production, an orchestrator closes that gap: a Kubernetes liveness probe, or an ECS/ALB health check, replaces unhealthy instances.
- **Every network call has a timeout,** and non-critical dependencies degrade instead of failing the request.
- **CI checks:**
  - lint the code (e.g. an ESLint rule for unreleased clients, or simply always use `pool.query`);
  - run `nginx -t` and `docker compose config`;
  - add a smoke test like `verify.sh` that runs the stack and calls the API before merge.
- **Config from one source.** Today the API port is an env var (`PORT`), but `nginx/conf.d/default.conf` still hardcodes `3000`, so they can still drift. In production I would render the NGINX config from the same variable, e.g. the official image's `/etc/nginx/templates` + `envsubst`, and add a CI smoke test that calls `/api/users` through NGINX.
- **Chaos-style checks before release:** restart the DB, stop Redis, recreate containers. These are the failures that happen in real life.
- **Secrets** come from a secret manager, not from code or Compose files.

## What I deliberately left out

- No lockfile: I couldn't generate `package-lock.json` in my environment. In production I would commit it and use `npm ci` for reproducible builds.
- No resource limits, multiple API replicas, or metrics exporters. They are useful, but beyond "investigate and stabilize".
