#!/usr/bin/env bash
# Conformance linter for podman-quadlet-service units.
# Usage: validate.sh <path-to-.container-file>
# Exit 0 when conformant; exit 1 with one "R<n>: <message>" line per violation.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
unit="${1:-}"
[ -n "$unit" ] && [ -f "$unit" ] || { echo "usage: validate.sh <unit-file>" >&2; exit 2; }

# The service name is the unit's basename: it defines the expected data tree.
service="$(basename "$unit" .container)"
tree="$HOME/.$service"

violations=0
fail() { echo "$1: $2"; violations=$((violations + 1)); }

# Strip comments and blank lines for directive checks; keep the raw file for
# comment-based exemptions.
body="$(grep -vE '^[[:space:]]*(#|$)' "$unit")"
get() { echo "$body" | grep -E "^[[:space:]]*$1=" || true; }

# R1 - pinned image
image="$(get Image | head -1 | cut -d= -f2-)"
if [ -z "$image" ]; then
  fail R1 "no Image= directive"
elif echo "$image" | grep -q ':latest\b'; then
  fail R1 "image uses the latest tag: $image"
elif ! echo "$image" | grep -qE '(:[^/@]+|@sha256:[0-9a-f]{64})$'; then
  fail R1 "image is not pinned to a tag or digest: $image"
fi

# R2 - userns mapping
get UserNS | grep -q 'keep-id' || fail R2 "missing UserNS=keep-id"

# R3 - no inline environment
[ -z "$(get Environment)" ] || fail R3 "inline Environment= is forbidden, use EnvironmentFile="
[ -n "$(get EnvironmentFile)" ] || fail R3 "missing EnvironmentFile="

# R4 - secrets shape
while IFS= read -r line; do
  [ -z "$line" ] && continue
  echo "$line" | grep -qE 'type=(env|mount)' || fail R4 "Secret= without type=env|mount: $line"
done <<< "$(get Secret)"

# R5 - healthcheck, unless justified distroless
if [ -z "$(get HealthCmd)" ]; then
  grep -q '^# NO-HEALTHCHECK:' "$unit" \
    || fail R5 "no HealthCmd= and no '# NO-HEALTHCHECK:' justification comment"
else
  for k in HealthInterval HealthTimeout HealthRetries HealthStartPeriod; do
    [ -n "$(get "$k")" ] || fail R5 "HealthCmd= present but $k= missing"
  done
fi

# R6 - explicit pull policy, no auto-update
get Pull | grep -q 'Pull=missing' || fail R6 "missing explicit Pull=missing"
[ -z "$(get AutoUpdate)" ] || fail R6 "AutoUpdate= contradicts a pinned image"

# R7 - restart policy
get Restart | grep -q 'Restart=always' || fail R7 "missing [Service] Restart=always"
[ -n "$(get RestartSec)" ] || fail R7 "missing RestartSec="

# R8 - bind mounts inside this service's tree only
while IFS= read -r line; do
  [ -z "$line" ] && continue
  host="$(echo "$line" | cut -d= -f2- | cut -d: -f1)"
  case "$host" in
    "$tree"/*) : ;;
    /*) fail R8 "bind mount outside $tree: $host" ;;
    *)  fail R8 "named volume or non-absolute path: $host" ;;
  esac
done <<< "$(get Volume)"

# R9 - resource limits
[ -n "$(get Memory)" ]    || fail R9 "missing Memory="
[ -n "$(get PidsLimit)" ] || fail R9 "missing PidsLimit="
get PodmanArgs | grep -q -- '--cpus=' || fail R9 "missing PodmanArgs=--cpus="

# R10 - explicit log driver
[ -n "$(get LogDriver)" ] || fail R10 "missing explicit LogDriver="

# R11 - absolute canonical paths
if echo "$body" | grep -qE '=(~|\.\.?/)|%h'; then
  fail R11 "non-absolute or non-canonical path (~, relative, or %h)"
fi

# The Quadlet generator must accept the unit.
# -user is a boolean flag: a positional directory argument is silently ignored
# and the generator reads its default search paths instead, validating nothing.
# QUADLET_UNIT_DIRS is the only way to point it at a specific directory.
if quadlet_bin="$("$HERE/find-quadlet.sh" 2>/dev/null)"; then
  tmp="$(mktemp -d)"; cp "$unit" "$tmp/"
  lint_out="$(QUADLET_UNIT_DIRS="$tmp" "$quadlet_bin" -dryrun -user 2>&1)"
  if ! echo "$lint_out" | grep -q 'Loading source unit file'; then
    fail LINT "quadlet -dryrun parsed no unit file - the lint did not run"
  elif echo "$lint_out" | grep -qiE 'unsupported key|error'; then
    fail LINT "quadlet -dryrun reported errors"
    echo "$lint_out" | grep -iE 'unsupported key|error' | sed 's/^/    /'
  fi
  rm -rf "$tmp"
else
  echo "warning: quadlet generator not found, skipping -dryrun lint" >&2
fi

[ "$violations" -eq 0 ] && { echo "conformant"; exit 0; }
echo "$violations violation(s)"
exit 1
