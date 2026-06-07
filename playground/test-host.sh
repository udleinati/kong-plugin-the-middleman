#!/usr/bin/env sh
# Step-by-step test for the HOST cache scenario (route /cache-host).
#
# Expected flow: first request MISS, repeat HIT, hit the invalidation path,
# then MISS again. Also asserts the injected identity headers are present.
. "$(dirname "$0")/lib.sh"
wait_for_kong || exit 1

URL="$KONG_PROXY/cache-host"
INVALIDATE="$KONG_PROXY/cache-host/invalidate"

# Per-run host so each run starts from a COLD cache key (cache_based_on=host),
# making the suite re-runnable within the cache_ttl window. The invalidation
# request must use the SAME host to clear the right entry.
HOST="host-$$-$(date +%s 2>/dev/null || echo 0).test"

echo "=================================================="
echo "Cenario: cache por HOST   ($URL)"
echo "=================================================="
echo ""

echo "[1/4] Primeira requisicao (espera MISS + headers injetados)"
echo "  \$ curl -s $URL"
R=$(curl -s -H "Host: $HOST" "$URL")
assert_contains "$R" "x-middleman-cache-status: MISS" "1a requisicao = MISS"
assert_contains "$R" "x-tenant-id: 123"               "header injetado x-tenant-id: 123"
assert_contains "$R" "x-role: admin"                  "header injetado x-role: admin"
assert_contains "$R" "x-account-id: 112233"           "header injetado x-account-id: 112233"
echo ""

echo "[2/4] Repete a mesma requisicao (espera HIT)"
echo "  \$ curl -s $URL"
R=$(curl -s -H "Host: $HOST" "$URL")
assert_contains "$R" "x-middleman-cache-status: HIT" "2a requisicao = HIT"
echo ""

echo "[3/4] Acessa o path de invalidacao (limpa a chave no redis db 0)"
echo "  \$ curl -s $INVALIDATE"
curl -s -o /dev/null -H "Host: $HOST" "$INVALIDATE"
echo "  (cache invalidado)"
echo ""

echo "[4/4] Nova requisicao apos invalidar (espera MISS de novo)"
echo "  \$ curl -s $URL"
R=$(curl -s -H "Host: $HOST" "$URL")
assert_contains "$R" "x-middleman-cache-status: MISS" "apos invalidacao = MISS"

assert_summary
