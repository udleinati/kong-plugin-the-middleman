#!/usr/bin/env sh
# Runs the full playground test suite (host + header scenarios) and fails loud:
# exits non-zero if either scenario has a failing assertion.
DIR="$(dirname "$0")"
fail=0

sh "$DIR/test-host.sh"     || fail=1
echo ""
sh "$DIR/test-header.sh"   || fail=1
echo ""
sh "$DIR/test-extended.sh" || fail=1
echo ""

echo "=================================================="
if [ "$fail" -eq 0 ]; then
  echo "==> TODOS OS TESTES PASSARAM"
else
  echo "==> ALGUM TESTE FALHOU" >&2
fi
echo "=================================================="
exit "$fail"
