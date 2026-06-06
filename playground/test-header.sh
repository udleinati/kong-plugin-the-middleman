#!/usr/bin/env sh
# Step-by-step test for the HEADER cache scenario (route /cache-header).
#
# The cache key is the `authorization` header value, so:
#   - same token  -> MISS then HIT
#   - other token -> MISS (different key, isolated in redis db 1)
. "$(dirname "$0")/lib.sh"
wait_for_kong || exit 1

URL="$KONG_PROXY/cache-header"

echo "=================================================="
echo "Cenario: cache por HEADER (authorization)  ($URL)"
echo "=================================================="
echo ""

echo "[1/3] Primeira requisicao com token-1 (espera MISS + headers injetados)"
echo "  \$ curl -s -H 'Authorization: token-1' $URL"
R=$(curl -s -H "Authorization: token-1" "$URL")
assert_contains "$R" "x-middleman-cache-status: MISS" "token-1 1a vez = MISS"
assert_contains "$R" "x-tenant-id: 123"               "header injetado x-tenant-id: 123"
assert_contains "$R" "x-role: admin"                  "header injetado x-role: admin"
assert_contains "$R" "x-account-id: 112233"           "header injetado x-account-id: 112233"
echo ""

echo "[2/3] Repete com token-1 (espera HIT)"
echo "  \$ curl -s -H 'Authorization: token-1' $URL"
R=$(curl -s -H "Authorization: token-1" "$URL")
assert_contains "$R" "x-middleman-cache-status: HIT" "token-1 2a vez = HIT"
echo ""

echo "[3/3] Requisicao com token-2 diferente (espera MISS — chave distinta)"
echo "  \$ curl -s -H 'Authorization: token-2' $URL"
R=$(curl -s -H "Authorization: token-2" "$URL")
assert_contains "$R" "x-middleman-cache-status: MISS" "token-2 = MISS"

assert_summary
