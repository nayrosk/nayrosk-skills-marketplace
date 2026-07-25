#!/usr/bin/env bash
# Test suite for podman-quadlet-service scripts.
# Fixtures use the @HOME@ token so they stay portable across machines.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VALIDATE="$HERE/../scripts/validate.sh"
RENDERED="$(mktemp -d)"
trap 'rm -rf "$RENDERED"' EXIT
fails=0

render() { # render <fixture> -> prints rendered path
  # Every fixture is rendered as "fixture.container" in its own directory:
  # validate.sh derives the expected data tree from the unit's basename, so the
  # unit must be named after the service the fixture's paths refer to (.fixture).
  local src="$1" dir="$RENDERED/$(basename "$1" .container)"
  mkdir -p "$dir"
  sed "s|@HOME@|$HOME|g" "$src" > "$dir/fixture.container"
  echo "$dir/fixture.container"
}

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

check_rule() { # check_rule <fixture> <rule-id>
  local rendered rule="$2" out rc
  rendered="$(render "$1")"
  out="$("$VALIDATE" "$rendered" 2>&1)"; rc=$?
  if [ "$rc" -ne 1 ]; then
    echo "FAIL $(basename "$1"): exit $rc, expected 1"; echo "$out" | sed 's/^/    /'
    fails=$((fails+1)); return
  fi
  if ! echo "$out" | grep -q "^$rule:"; then
    echo "FAIL $(basename "$1"): expected a $rule violation, got:"; echo "$out" | sed 's/^/    /'
    fails=$((fails+1)); return
  fi
  echo "PASS $(basename "$1") -> $rule"
}

check "find-quadlet locates the generator (unset QUADLET_BIN)" 0 "$HERE/../scripts/find-quadlet.sh"
check_path "find-quadlet respects QUADLET_BIN override" 0 "/bin/true" env QUADLET_BIN=/bin/true "$HERE/../scripts/find-quadlet.sh"
check "find-quadlet fails on invalid QUADLET_BIN" 1 env QUADLET_BIN=/nonexistent-xyz "$HERE/../scripts/find-quadlet.sh"

check "conformant fixture validates" 0 "$VALIDATE" "$(render "$HERE/fixtures/conformant.container")"

# Positive regressions: these fixtures are deliberately named outside the
# violation-r<n>-* convention (they are not one), so the glob loop below
# does not sweep them in; each is asserted explicitly instead.
check "latest-slim tag is not falsely rejected (R1)" 0 "$VALIDATE" "$(render "$HERE/fixtures/pass-latest-slim.container")"
check "NO-HEALTHCHECK exemption is honoured (R5)" 0 "$VALIDATE" "$(render "$HERE/fixtures/pass-no-healthcheck.container")"
check "CRLF line endings are not falsely rejected" 0 "$VALIDATE" "$(render "$HERE/fixtures/pass-crlf.container")"

for f in "$HERE"/fixtures/violation-*.container; do
  rule="$(basename "$f" | sed -E 's/^violation-(r[0-9]+)-.*/\1/' | tr 'a-z' 'A-Z')"
  check_rule "$f" "$rule"
done

# The LINT guard is a distinct failure channel (the Quadlet generator itself
# rejecting the unit, not a convention violation) and is reported as
# "LINT: ..." rather than "R<n>: ...", so it cannot be named violation-r<n>-*
# and is checked explicitly rather than through the rule-mapped loop above.
lint_rendered="$(render "$HERE/fixtures/lint-bogus-key.container")"
lint_out="$("$VALIDATE" "$lint_rendered" 2>&1)"; lint_rc=$?
if [ "$lint_rc" -eq 1 ] && echo "$lint_out" | grep -q '^LINT:'; then
  echo "PASS lint-bogus-key.container -> LINT"
else
  echo "FAIL lint-bogus-key.container: exit $lint_rc, expected 1 with a LINT: line"
  echo "$lint_out" | sed 's/^/    /'
  fails=$((fails+1))
fi

[ "$fails" -eq 0 ] && echo "ALL TESTS PASSED" || echo "$fails FAILING CASE(S)"
exit $((fails > 0))
