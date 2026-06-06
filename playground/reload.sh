#!/usr/bin/env sh
# Re-apply the declarative config to a running db-less Kong WITHOUT restarting,
# by POSTing kong.yml to the Admin API /config endpoint (this replaces the whole
# config). Handy after editing kong.yml.
#
# Usage: ./reload.sh [path-to-kong.yml]
. "$(dirname "$0")/lib.sh"

CONFIG="${1:-$(dirname "$0")/kong.yml}"

wait_for_kong || exit 1

echo "Aplicando $CONFIG em $KONG_ADMIN/config ..."
curl -fs -o /dev/null -X POST "$KONG_ADMIN/config" -F "config=@$CONFIG"
echo "OK"
