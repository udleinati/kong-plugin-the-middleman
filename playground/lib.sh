#!/usr/bin/env sh
# Shared helpers for the the-middleman playground scripts.
# Written in POSIX sh so the same files run on the host AND inside the
# curlimages/curl loader container (busybox sh).

# Admin API base URL. Defaults to the host-published port; the loader container
# overrides it with KONG_ADMIN=http://playground-kong:8001.
KONG_ADMIN="${KONG_ADMIN:-http://localhost:8001}"

# Proxy base URL used by the test scripts.
KONG_PROXY="${KONG_PROXY:-http://localhost:8000}"

# Block until the Kong Admin API answers, or give up after ~60s.
wait_for_kong() {
  i=0
  while [ "$i" -lt 60 ]; do
    if curl -fs -o /dev/null "$KONG_ADMIN/status"; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  echo "ERRO: Kong Admin API em $KONG_ADMIN nao ficou pronto a tempo" >&2
  return 1
}

# --- Assertion helpers for the test scripts --------------------------------
# Counters are per-process; the test.sh aggregator combines via exit codes.
ASSERT_PASS=0
ASSERT_FAIL=0

# assert_contains <haystack> <needle> <description>
assert_contains() {
  if printf '%s' "$1" | grep -qi -- "$2"; then
    printf '  PASS  %s\n' "$3"
    ASSERT_PASS=$((ASSERT_PASS + 1))
  else
    printf '  FAIL  %s\n' "$3"
    printf '        esperado conter: "%s"\n' "$2" >&2
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
  fi
}

# Print the pass/fail summary and return non-zero if anything failed.
assert_summary() {
  echo ""
  echo "RESULTADO: ${ASSERT_PASS} passou, ${ASSERT_FAIL} falhou"
  [ "$ASSERT_FAIL" -eq 0 ]
}
