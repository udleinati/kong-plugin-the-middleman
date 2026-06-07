#!/usr/bin/env sh
# Extended demos + assertions for the behaviours not covered by test.sh /
# test-features.sh: the local cache policy, host-path-query keying, the
# deny/redirect gates, REFRESH, streamdown and host-offloading. Fails loud.
#
# Unlike test-features.sh this never stops a container, so it is safe to run as
# part of the main suite (test.sh). It does sleep ~3s for the REFRESH window.
. "$(dirname "$0")/lib.sh"
wait_for_kong || exit 1

P="$KONG_PROXY"

# Per-run nonce so the MISS-expecting tests start from a COLD cache key every
# time (the local policy keeps entries in Kong's memory across runs, and Redis
# keeps them for cache_ttl). Varying the host / query makes each run independent.
NONCE="$$-$(date +%s 2>/dev/null || echo 0)"

echo "=================================================="
echo "Extended demos"
echo "=================================================="

echo ""
echo "[1/8] cache_policy=local — in-memory cache, MISS then HIT (no Redis)"
echo "  \$ curl -s -H 'Host: local-$NONCE.test' $P/cache-local   (x2)"
HOST_LOCAL="local-$NONCE.test"
R1=$(curl -s -H "Host: $HOST_LOCAL" "$P/cache-local")
R2=$(curl -s -H "Host: $HOST_LOCAL" "$P/cache-local")
assert_contains "$R1" "x-middleman-cache-status: MISS" "local 1st request = MISS"
assert_contains "$R2" "x-middleman-cache-status: HIT"  "local 2nd request = HIT"
assert_contains "$R1" "x-tenant-id: 123"               "local injects the identity headers"

echo ""
echo "[2/8] cache_based_on=host-path-query — the query is part of the key"
echo "  \$ curl -s '$P/cache-path?run=$NONCE&a=1' (x2) then a=2"
A1=$(curl -s "$P/cache-path?run=$NONCE&a=1")
A1b=$(curl -s "$P/cache-path?run=$NONCE&a=1")
A2=$(curl -s "$P/cache-path?run=$NONCE&a=2")
assert_contains "$A1"  "x-middleman-cache-status: MISS" "?a=1 1st = MISS"
assert_contains "$A1b" "x-middleman-cache-status: HIT"  "?a=1 2nd = HIT"
assert_contains "$A2"  "x-middleman-cache-status: MISS" "?a=2 = MISS (different key)"

echo ""
echo "[3/8] Gate / deny — the middle answers 403, replayed to the client"
echo "  \$ curl -s $P/gate-deny"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$P/gate-deny")
BODY=$(curl -s "$P/gate-deny")
assert_contains "$CODE" "403"       "deny -> HTTP 403"
assert_contains "$BODY" "forbidden" "deny replays the middle-service body"

echo ""
echo "[4/8] Redirect — the middle answers 302, status + Location replayed"
echo "  \$ curl -s -D - $P/gate-redirect"
H=$(curl -s -D - -o /dev/null "$P/gate-redirect")
assert_contains "$H" "302"               "redirect -> HTTP 302"
assert_contains "$H" "location: /login"  "Location header preserved"

echo ""
echo "[5/8] REFRESH — a stale entry is re-validated while the middle is up"
echo "  populate (MISS), wait past cache_ttl=2, request again -> REFRESH"
HOST_REFRESH="refresh-$NONCE.test"
curl -s -o /dev/null -H "Host: $HOST_REFRESH" "$P/refresh"   # MISS -> fresh 2s, retained 600s
sleep 3                                                        # entry is now stale, still stored
R=$(curl -s -H "Host: $HOST_REFRESH" "$P/refresh")
assert_contains "$R" "x-middleman-cache-status: REFRESH" "stale entry re-validated -> REFRESH"

echo ""
echo "[6/8] streamdown_injected_headers — identity on the CLIENT response headers"
echo "  \$ curl -s -D - $P/streamdown   (headers only)"
SD=$(curl -s -D - -o /dev/null "$P/streamdown")
assert_contains "$SD" "x-tenant-id: 123"          "injected header mirrored onto the response"
assert_contains "$SD" "x-middleman-cache-status:" "cache-status mirrored onto the response"

echo ""
echo "[7/8] Host-offloading — identity is offloaded from the forwarded X-Tenant"
echo "  \$ curl -s -H 'X-Tenant: acme' $P/offload"
R=$(curl -s -H "X-Tenant: acme" "$P/offload")
assert_contains "$R" "x-tenant-id: acme" "tenant offloaded from the X-Tenant header"
# default (no header) falls back to the static identity
R=$(curl -s "$P/offload")
assert_contains "$R" "x-tenant-id: 123"  "falls back to the static tenant without the header"

echo ""
echo "[8/8] forward_path/query + injected_header_prefix — echoed as x-echo-* headers"
echo "  \$ curl -s '$P/forward?foo=bar'"
R=$(curl -s "$P/forward?foo=bar")
assert_contains "$R" "x-echo-fwd-path: /forward" "forward_path echoed with the X-Echo- prefix"
assert_contains "$R" "x-echo-fwd-query"          "forward_query echoed with the X-Echo- prefix"
assert_contains "$R" "x-echo-tenant-id: 123"     "identity injected with the custom prefix"

assert_summary
