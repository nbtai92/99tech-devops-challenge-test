#!/usr/bin/env bash
# Reproduces each failure mode from SOLUTION.md against the running stack and
# prints PASS / FAIL / INCONCLUSIVE per check.
#
# Usage (from src/problem3):
#   ./scripts/verify.sh 2>&1 | tee verify-$(git branch --show-current).txt
# Run it on the original code (main) and on the fixed branch to compare.
#
# Two access paths, so one bug cannot hide another:
#   - via NGINX (http://localhost:8080): checks 1, 2 and 7 (routing, end-to-end, DNS)
#   - direct to the API inside its container (127.0.0.1:3000): checks 3-6, so the
#     API's own behaviour is tested even when NGINX routing is broken (as on main).
# Scenarios are isolated: the api container is restarted between them.
set -u

BASE="${BASE:-http://localhost:8080}"
pass=0; fail=0; inconclusive=0

result() { # result <PASS|FAIL|INCONCLUSIVE> <message>
  echo "$1  $2"
  case "$1" in PASS) pass=$((pass+1));; FAIL) fail=$((fail+1));; *) inconclusive=$((inconclusive+1));; esac
}
check() { if [ "$2" -eq 0 ]; then result PASS "$1"; else result FAIL "$1"; fi; }

# --- access paths ------------------------------------------------------------

# Through NGINX: prints the HTTP status (000 = no response / timeout).
code() { curl -s -o /dev/null -m "${2:-15}" -w '%{http_code}' "$BASE$1"; }

# Directly to the API, from inside its container (Node 20 has fetch).
# Prints "<status> <seconds>"; status 000 = no response, timeout, or container down.
api() { # api <path> [timeout-s]
  docker compose exec -T api node -e '
    const t0 = Date.now();
    fetch("http://127.0.0.1:3000" + process.argv[1], { signal: AbortSignal.timeout(process.argv[2] * 1000) })
      .then((r) => console.log(r.status, (Date.now() - t0) / 1000))
      .catch(() => console.log("000", (Date.now() - t0) / 1000));
  ' "$1" "${2:-5}" 2>/dev/null || echo "000 0"
}
api_code() { api "$@" | awk '{print $1}'; }

wait_nginx() { for _ in $(seq 1 "$2"); do [ "$(code "$1" 3)" = "200" ] && return 0; sleep 1; done; return 1; }
wait_api()   { for _ in $(seq 1 "$2"); do [ "$(api_code "$1" 3)" = "200" ] && return 0; sleep 1; done; return 1; }

api_id() { docker compose ps -aq api; }
api_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(api_id)"; }

reset_api() { # fresh API process (and DB pool) for each scenario
  docker compose up -d redis postgres >/dev/null 2>&1
  docker compose restart api >/dev/null 2>&1
  wait_api /api/users 30 || echo "      (api did not serve /api/users after restart)"
}

# --- Postgres access (credentials read from the running container, i.e. from .env) ---

pg_env() { docker compose exec -T postgres printenv "$1" 2>/dev/null | tr -d '\r'; }
PGUSER=""; PGDB=""
load_pg_credentials() {
  PGUSER="$(pg_env POSTGRES_USER)"; PGUSER="${PGUSER:-postgres}"
  PGDB="$(pg_env POSTGRES_DB)";     PGDB="${PGDB:-$PGUSER}"
  echo "      postgres user=$PGUSER db=$PGDB (from the postgres container)"
}
psql_exec() { docker compose exec -T postgres psql -q -X -U "$PGUSER" -d "$PGDB" -v ON_ERROR_STOP=1 >/dev/null 2>&1; }

# Fault injection for the leak test: shadow now() with a function that raises,
# for *new* DB sessions only (role-level search_path). Returns non-zero if setup failed.
inject_query_failure() {
  psql_exec <<SQL || return 1
CREATE OR REPLACE FUNCTION public.now() RETURNS timestamptz LANGUAGE plpgsql
  AS \$\$ BEGIN RAISE EXCEPTION 'injected failure (verify.sh)'; END \$\$;
ALTER ROLE "$PGUSER" SET search_path = public, pg_catalog;
SQL
  # Prove it works: a new session's SELECT NOW() must now fail.
  if echo "SELECT NOW();" | psql_exec; then return 1; fi
  return 0
}
heal_query_failure() {
  psql_exec <<SQL || true
DROP FUNCTION IF EXISTS public.now();
ALTER ROLE "$PGUSER" RESET search_path;
SQL
}

cleanup() {
  [ -n "$PGUSER" ] && heal_query_failure
  docker rm -f verify-ip-placeholder >/dev/null 2>&1 || true
  docker compose up -d redis >/dev/null 2>&1 || true
}
trap cleanup EXIT

# -----------------------------------------------------------------------------

echo "== Starting stack"
docker compose up -d --build --wait 2>/dev/null || docker compose up -d --build
wait_api /api/users 60 || echo "      (api not serving yet; continuing)"
load_pg_credentials

echo "== 1. Routing through NGINX"
[ "$(code /)" = "200" ];          check "GET / returns 200" $?
[ "$(code /api/users)" = "200" ]; routing_ok=$?
check "GET /api/users via nginx returns 200 (nginx -> api port)" "$routing_ok"
[ "$(code /status)" = "200" ];    check "GET /status via nginx returns 200 (health exposed)" $?

echo "== 2. Load through NGINX: 300 requests, 20 concurrent (healthy dependencies)"
if [ "$routing_ok" -ne 0 ]; then
  result INCONCLUSIVE "load test skipped: routing through nginx is broken (check 1)"
else
  errors=$(seq 1 300 | xargs -P 20 -I{} curl -s -o /dev/null -m 15 -w '%{http_code}\n' "$BASE/api/users" | grep -vc '^200$')
  [ "$errors" -eq 0 ]; check "no non-200 responses under load (got $errors)" $?
fi

echo "== 3. Connection leak (direct to API): 15 failing queries (> pool size 10), then recovery"
reset_api
if ! inject_query_failure; then
  result INCONCLUSIVE "fault injection could not be set up; leak test not run"
else
  docker compose restart api >/dev/null 2>&1   # new pool -> new sessions see the injected failure
  sleep 5
  codes=$(for _ in $(seq 1 15); do api_code /api/users 5; done | tr '\n' ' ')
  echo "      responses while queries fail: $codes"
  ok=$(echo "$codes" | tr ' ' '\n' | grep -c '^200$')
  hung=$(echo "$codes" | tr ' ' '\n' | grep -c '^000$')
  if [ "$ok" -gt 0 ]; then
    result INCONCLUSIVE "injection not effective ($ok of 15 requests succeeded); leak test not valid"
  else
    [ "$hung" -eq 0 ]; check "failing queries return an error instead of hanging ($hung of 15 got no response)" $?
    heal_query_failure
    wait_api /api/users 15; check "API serves again once queries succeed (no leaked connections)" $?
  fi
fi
heal_query_failure

echo "== 4. Postgres restart while clients are idle in the pool (direct to API)"
reset_api
before=$(docker inspect -f '{{.RestartCount}}' "$(api_id)")
api_code /api/users >/dev/null
docker compose restart postgres >/dev/null
sleep 3
state=$(docker inspect -f '{{.State.Status}}' "$(api_id)"); after=$(docker inspect -f '{{.RestartCount}}' "$(api_id)")
echo "      api state=$state restart_count before=$before after=$after"
[ "$state" = "running" ] && [ "$after" = "$before" ]; check "api process does not crash when Postgres restarts" $?
wait_api /api/users 30; check "api serves again after Postgres is back" $?

echo "== 5. Redis outage at runtime (direct to API)"
reset_api
docker compose stop redis >/dev/null
r=$(api /api/users 30)
echo "      with redis down: status=${r%% *} seconds=${r##* }"
[ "${r%% *}" = "200" ];                         check "/api/users succeeds while Redis is down" $?
awk -v s="${r##* }" 'BEGIN{exit !(s < 1.0)}';  check "/api/users answers in < 1s while Redis is down" $?

echo "== 6. API starts while Redis is down (direct to API)"
docker compose up -d --no-deps --force-recreate api >/dev/null 2>&1
wait_api /api/users 45; check "api starts and serves /api/users without Redis" $?
docker compose up -d redis >/dev/null

echo "== 7. API gets a new IP address (through NGINX)"
reset_api
if [ "$routing_ok" -ne 0 ]; then
  result INCONCLUSIVE "DNS test skipped: routing through nginx is broken (check 1)"
else
  net=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$(api_id)")
  ip_before=$(api_ip)
  docker network disconnect "$net" "$(api_id)"
  # Occupy an address so the api is unlikely to get its old one back.
  docker run -d --rm --name verify-ip-placeholder --network "$net" redis:7 >/dev/null
  docker network connect --alias api "$net" "$(api_id)"
  ip_after=$(api_ip)
  echo "      api ip before=$ip_before after=$ip_after"
  if [ "$ip_before" = "$ip_after" ]; then
    result INCONCLUSIVE "api kept the same IP; the stale-DNS scenario was not exercised"
  else
    wait_nginx /api/users 20; check "nginx follows the api to its new IP" $?
  fi
fi

echo
echo "Result: $pass passed, $fail failed, $inconclusive inconclusive"
[ "$fail" -eq 0 ]
