#!/usr/bin/env bash
# Test suite for podman-quadlet-service scripts.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fails=0
check() { # check <description> <expected-exit> <command...>
  local desc="$1" want="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ]; then echo "PASS $desc"
  else echo "FAIL $desc: exit $rc, expected $want"; echo "$out" | sed 's/^/    /'; fails=$((fails+1)); fi
}

check "find-quadlet locates the generator" 0 "$HERE/../scripts/find-quadlet.sh"

[ "$fails" -eq 0 ] && echo "ALL TESTS PASSED" || echo "$fails FAILING CASE(S)"
exit $((fails > 0))
