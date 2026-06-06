#!/usr/bin/env sh
# Shows how Kong is currently configured (services / routes / plugins) by
# reading the Admin API. Replaces the old Konga GUI.
#
# Uses jq for a readable summary when available; otherwise prints raw JSON.
. "$(dirname "$0")/lib.sh"

echo "Kong Admin: $KONG_ADMIN"
echo ""

if command -v jq >/dev/null 2>&1; then
  echo "== SERVICES =="
  curl -fs "$KONG_ADMIN/services" \
    | jq -r '.data[] | "- \(.name) -> \(.protocol)://\(.host):\(.port)\(.path // "")"'
  echo ""

  echo "== ROUTES =="
  curl -fs "$KONG_ADMIN/routes" \
    | jq -r '.data[] | "- \(.name)  paths=\(.paths)"'
  echo ""

  echo "== PLUGINS (the-middleman) =="
  curl -fs "$KONG_ADMIN/plugins" \
    | jq -r '.data[]
        | select(.name == "the-middleman")
        | "- route=\(.route.id)  cache_policy=\(.config.cache_policy)  based_on=\(.config.cache_based_on)  redis_db=\(.config.redis.database)  url=\(.config.url)"'
else
  echo "(jq nao encontrado — imprimindo JSON cru. Instale jq para um resumo legivel.)"
  echo ""
  echo "== SERVICES =="; curl -fs "$KONG_ADMIN/services"; echo ""; echo ""
  echo "== ROUTES =="; curl -fs "$KONG_ADMIN/routes"; echo ""; echo ""
  echo "== PLUGINS =="; curl -fs "$KONG_ADMIN/plugins"; echo ""
fi
