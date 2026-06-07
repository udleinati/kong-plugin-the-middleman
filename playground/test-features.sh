#!/usr/bin/env sh
# Step-by-step demo + assertions for the cache/forwarding features layered on top
# of the host/header scenarios (those live in test.sh). Asserts fail loud.
. "$(dirname "$0")/lib.sh"
wait_for_kong || exit 1

DIR="$(dirname "$0")"
COMPOSE="docker compose -f $DIR/docker-compose.yml"
P="$KONG_PROXY"

echo "=================================================="
echo "Feature demos"
echo "=================================================="

echo ""
echo "[1/5] forward_response_headers — the middle's X-Auth-Source reaches the upstream"
echo "  \$ curl -s $P/feat-respheader"
R=$(curl -s "$P/feat-respheader")
assert_contains "$R" "x-auth-source: middle-service" "x-auth-source forwarded from the middle response"

echo ""
echo "[2/5] X-Cache-Key — a SHA-256 cache key is exposed"
echo "  \$ curl -s $P/feat-codes"
R=$(curl -s "$P/feat-codes")
assert_contains "$R" "x-middleman-cache-key:" "x-middleman-cache-key header present"

echo ""
echo "[3/5] cache_response_codes — middle replies 200 but only 201 is cacheable -> always MISS"
echo "  \$ curl -s $P/feat-codes   (x2)"
R1=$(curl -s "$P/feat-codes"); R2=$(curl -s "$P/feat-codes")
assert_contains "$R1" "x-middleman-cache-status: MISS" "1st request MISS"
assert_contains "$R2" "x-middleman-cache-status: MISS" "2nd request still MISS (200 not in cache_response_codes)"

echo ""
echo "[4/5] cache_control — client Cache-Control: no-store -> BYPASS"
echo "  \$ curl -s -H 'Cache-Control: no-store' $P/feat-bypass"
R=$(curl -s -H "Cache-Control: no-store" "$P/feat-bypass")
assert_contains "$R" "x-middleman-cache-status: BYPASS" "no-store bypasses the cache"

echo ""
echo "[5/5] serve-stale — the middle goes down, a stale cached copy is still served"
echo "  populate cache, stop the middle, wait for the entry to go stale (cache_ttl=2)"
curl -s -o /dev/null "$P/feat-stale"            # MISS -> cached, fresh for 2s
$COMPOSE stop playground-middle-service >/dev/null 2>&1
sleep 3                                          # let the entry pass its freshness window
R=$(curl -s "$P/feat-stale")
assert_contains "$R" "x-middleman-cache-status: STALE" "stale copy served while the middle is down"
echo "  restarting the middle-service..."
$COMPOSE start playground-middle-service >/dev/null 2>&1
# wait for the middle to be reachable again so the stack is left healthy
curl --retry-connrefused --retry 20 --retry-delay 1 --retry-all-errors -fs -o /dev/null "$P/feat-respheader" >/dev/null 2>&1 || true

assert_summary
