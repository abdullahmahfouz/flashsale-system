#!/usr/bin/env bash
# Usage: loadtest/run.sh <naive|locked|idempotent> <spike|retry-storm|ramp>
# Resets the dedicated loadtest DB, starts Rails, runs k6, stops ONLY its own server,
# checks invariants, appends one row to loadtest/results.md.
set -euo pipefail

MODE="${1:?mode required}"; SCENARIO="${2:?scenario required (spike|retry-storm|ramp)}"
case "$SCENARIO" in spike|retry-storm|ramp) ;; *) echo "bad scenario $SCENARIO" >&2; exit 2;; esac

DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$DIR")"
STARTING_STOCK="${STARTING_STOCK:-1000}"   # << expected k6 request volume, so oversell is visible in naive
PORT="${PORT:-3000}"; BASE_URL="http://localhost:$PORT"; PRODUCT_ID=1
DB_URL="${LOADTEST_DATABASE_URL:-postgres://postgres:postgres@localhost:5433/flashsale_system_loadtest}"
RAILS_MAX_THREADS="${RAILS_MAX_THREADS:-16}"; DB_POOL="${DB_POOL:-100}"; WEB_CONCURRENCY="${WEB_CONCURRENCY:-0}"
STAMP="$(date +%Y%m%d-%H%M%S)"; TAG="$MODE-$SCENARIO-$STAMP"
mkdir -p "$DIR/out" "$DIR/logs"
SUMMARY="$DIR/out/$TAG.summary.json"; K6OUT="$DIR/out/$TAG.k6.txt"
INV="$DIR/out/$TAG.invariants.txt"; SRVLOG="$DIR/logs/$TAG.server.log"
RESULTS="$DIR/results.md"
SERVER_PID=""

stop_server() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.5; done
    kill -9 "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
}
trap stop_server EXIT

init_results() {
  [ -f "$RESULTS" ] && return
  cat > "$RESULTS" <<'HDR'
# Load test results

Setup: laptop, single Puma process (WEB_CONCURRENCY=0, RAILS_MAX_THREADS=16, DB_POOL=100), Rails in
`production` env (logs at warn level to a file), Postgres 16 and Redis in Docker, k6 on the same machine.
Puma on one laptop is the bottleneck, so absolute numbers are only comparable across modes in this setup.
Dedicated DB `flashsale_system_loadtest`; every run deletes all orders and resets product 1 stock to the
starting stock (default 1000). Latencies are http_req_duration in ms. Error rate is http_req_failed
(5xx, 422, network failures; 201/200/409 are treated as expected). "oversold" = max(0, paid - starting stock).

| date | mode | scenario | start stock | p50 ms | p95 ms | p99 ms | req/s | error rate | 201 | 200 | 409 | other | orders in DB | stock left | oversold | invariants |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
HDR
}

fail_row() {  # $1 = reason
  init_results
  echo "| $(date '+%Y-%m-%d %H:%M:%S') | $MODE | $SCENARIO | $STARTING_STOCK | FAILED: $1 | | | | | | | | | | | | |" >> "$RESULTS"
  echo "FAILED: $1" >&2
}

PSQL=(psql "$DB_URL" -X -q -v ON_ERROR_STOP=1)

# (a) reset state
"${PSQL[@]}" -c "DELETE FROM orders;" \
  -c "INSERT INTO products(id,name,stock) VALUES ($PRODUCT_ID,'Flash Sale Item',$STARTING_STOCK) ON CONFLICT (id) DO UPDATE SET stock=EXCLUDED.stock;" >/dev/null

# port must be free
if lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then fail_row "port $PORT already in use"; exit 1; fi

# (b) start Rails
( cd "$ROOT" && exec env SECRET_KEY_BASE=dummy RAILS_ENV=production RAILS_LOG_LEVEL=warn \
    CHECKOUT_MODE="$MODE" DATABASE_URL="$DB_URL" DB_POOL="$DB_POOL" RAILS_MAX_THREADS="$RAILS_MAX_THREADS" \
    WEB_CONCURRENCY="$WEB_CONCURRENCY" PORT="$PORT" bin/rails server ) > "$SRVLOG" 2>&1 &
SERVER_PID=$!
ready=0
for _ in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/products/$PRODUCT_ID" || true)" = "200" ] && { ready=1; break; }
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 1
done
if [ "$ready" != 1 ]; then fail_row "server did not become ready (see logs/$(basename "$SRVLOG"))"; exit 1; fi

# (c) k6
set +e
STORM_KEY="storm-$STAMP-$$" SUMMARY_FILE="$SUMMARY" BASE_URL="$BASE_URL" PRODUCT_ID="$PRODUCT_ID" k6 run --quiet "$DIR/$SCENARIO.js" 2>&1 | tee "$K6OUT"
K6_RC=${PIPESTATUS[0]}
set -e

# (d) stop our own server only
stop_server
sleep 1
if lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then echo "WARNING: port $PORT still in use after stop" >&2; fi

if [ ! -s "$SUMMARY" ]; then fail_row "k6 produced no summary (exit $K6_RC)"; exit 1; fi

# (e) invariants
"${PSQL[@]}" -A -t -v starting_stock="$STARTING_STOCK" -v product_id="$PRODUCT_ID" -f "$DIR/check_invariants.sql" | tee "$INV"
ORDERS=$("${PSQL[@]}" -A -t -c "SELECT count(*) FROM orders;")
LEFT=$("${PSQL[@]}" -A -t -c "SELECT stock FROM products WHERE id=$PRODUCT_ID;")
OVER=$(grep -o 'oversold units=[0-9]*' "$INV" | cut -d= -f2)
INVRES=$(grep -E '^[1-4] (PASS|FAIL)' "$INV" | awk '{printf "%s%s %s", (NR>1?", ":""), $1, $2}')

# (f) results row (numbers come straight from the k6 summary JSON)
f() { jq -r "$1 | if . == null then \"n/a\" else . end" "$SUMMARY"; }
r2() { jq -r "$1 | if . == null then \"n/a\" else (. * 100 | round / 100) end" "$SUMMARY"; }
init_results
NOTE=""; [ "$K6_RC" != 0 ] && NOTE=" (k6 exit $K6_RC)"
echo "| $(date '+%Y-%m-%d %H:%M:%S') | $MODE | $SCENARIO | $STARTING_STOCK | $(r2 .p50_ms) | $(r2 .p95_ms) | $(r2 .p99_ms) | $(r2 .req_per_sec) | $(f .error_rate) | $(f .status_201) | $(f .status_200) | $(f .status_409) | $(f .status_other) | $ORDERS | $LEFT | $OVER | $INVRES$NOTE |" >> "$RESULTS"
echo "appended row to $RESULTS"
