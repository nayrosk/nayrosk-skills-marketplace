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

check_path() { # check_path <description> <expected-exit> <expected-path> <command...>
  local desc="$1" want_exit="$2" want_path="$3"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want_exit" ] && [ "$out" = "$want_path" ]; then
    echo "PASS $desc"
  else
    if [ "$rc" -ne "$want_exit" ]; then
      echo "FAIL $desc: exit $rc, expected $want_exit"; echo "$out" | sed 's/^/    /'; fails=$((fails+1))
    elif [ "$out" != "$want_path" ]; then
      echo "FAIL $desc: got '$out', expected '$want_path'"; fails=$((fails+1))
    fi
  fi
}

check "find-quadlet locates the generator (unset QUADLET_BIN)" 0 "$HERE/../scripts/find-quadlet.sh"
check_path "find-quadlet respects QUADLET_BIN override" 0 "/bin/true" env QUADLET_BIN=/bin/true "$HERE/../scripts/find-quadlet.sh"
check "find-quadlet fails on invalid QUADLET_BIN" 1 env QUADLET_BIN=/nonexistent-xyz "$HERE/../scripts/find-quadlet.sh"

[ "$fails" -eq 0 ] && echo "ALL TESTS PASSED" || echo "$fails FAILING CASE(S)"
exit $((fails > 0))
