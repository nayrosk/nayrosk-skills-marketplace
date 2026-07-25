#!/usr/bin/env bash
# Conformance linter for podman-quadlet-service units.
# Usage: validate.sh <path-to-.container-file>
# Exit 0 when conformant ("conformant" is printed).
# Exit 1 otherwise, with one diagnostic line per problem, on two possible
# prefixes:
#   "R<n>: <message>"  - a convention violation (R1..R11, references/conventions.md)
#   "LINT: <message>"  - the Quadlet generator itself rejected the unit
# A consumer that only greps "^R[0-9]+:" will miss LINT failures; match
# "^(R[0-9]+|LINT):" to see every reason for a non-zero exit.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
unit="${1:-}"
[ -n "$unit" ] && [ -f "$unit" ] || { echo "usage: validate.sh <unit-file>" >&2; exit 2; }

# The service name is the unit's basename: it defines the expected data tree.
service="$(basename "$unit" .container)"
tree="$HOME/.$service"

violations=0
fail() { echo "$1: $2"; violations=$((violations + 1)); }

# --- Normalize the unit into a canonical form, ONCE, and check rules only
# against that. systemd/Quadlet accept things a naive per-line grep does
# not: `\`-continued lines, whitespace around `=`, CRLF line endings, and
# "last value wins" for single-valued keys. Checking the raw text
# line-by-line lets a unit that systemd honours slip past the linter
# unseen, so every rule below reads from this normalized table instead of
# grepping "$unit" directly.
#
# Pass 1: strip trailing \r (CRLF safety) and join `\`-continued physical
# lines into one logical line each, mirroring systemd's own continuation
# handling (trailing backslash means "concatenate with the next line").
joined="$(awk '
  {
    seg = $0
    sub(/[ \t\r]+$/, "", seg)
    if (cont) { buf = buf seg } else { buf = seg }
    if (buf ~ /\\$/) { sub(/\\$/, "", buf); cont = 1 }
    else { print buf; cont = 0; buf = "" }
  }
  END { if (cont) print buf }
' "$unit")"

# Pass 2: track [Section] state, drop comments/blank lines, and split each
# directive on the FIRST `=` after trimming whitespace on both sides of it
# (systemd accepts `Key = value` and `Key= value` alike). Output is a TSV
# of section\tkey\tvalue, one row per directive, in file order. A bare
# `Key=` (empty value) is recorded too, since it means something below.
norm="$(printf '%s\n' "$joined" | awk '
  BEGIN { section = "" }
  {
    line = $0
    gsub(/^[ \t]+|[ \t\r]+$/, "", line)
    if (line == "" || line ~ /^#/) next
    if (line ~ /^\[.*\]$/) { section = line; gsub(/^\[|\]$/, "", section); next }
    if (line ~ /=/) {
      key = line; sub(/=.*/, "", key); gsub(/[ \t\r]+$/, "", key)
      val = line; sub(/^[^=]*=/, "", val); gsub(/^[ \t]+|[ \t\r]+$/, "", val)
      printf "%s\t%s\t%s\n", section, key, val
    }
  }
')"

# get_all <key> [section] -> every value for <key>, in file order, one per
# line (optionally restricted to a section). Honours systemd's list-reset
# semantics: for a list-valued directive, a bare `Key=` (empty value)
# discards every value accumulated for that key so far, and only what
# follows counts. This matters even for keys we otherwise treat as
# effectively single-valued (get_last is built on this), since Quadlet
# itself only ever sees the post-reset tail.
#
# The reset is tracked per (section, key), never per key alone: in systemd a
# list lives inside its section, so a bare `Key=` planted in one section must
# not cancel values accumulated in another. That distinction is invisible in
# a section-scoped lookup but load-bearing for the unscoped one (R3 scans
# Environment= file-wide), where a bare `Environment=` dropped into an inert
# [Install] block would otherwise erase the real, live [Service] values from
# the linter's view while Quadlet still emits them.
get_all() {
  local key="$1" want_section="${2:-}"
  printf '%s\n' "$norm" | awk -F'\t' -v k="$key" -v s="$want_section" '
    $2==k && (s=="" || $1==s) { n++; sec[n]=$1; v[n]=$3 }
    END {
      for (i = 1; i <= n; i++) if (v[i] == "") reset[sec[i]] = i
      for (i = 1; i <= n; i++) {
        last = (sec[i] in reset) ? reset[sec[i]] : 0
        if (v[i] != "" && i > last) print v[i]
      }
    }'
}

# get_last <key> [section] -> the LAST value for <key> (systemd's own
# override rule for single-valued directives), optionally section-scoped.
get_last() { get_all "$1" "${2:-}" | tail -1; }

# Every Quadlet [Container] directive is looked up scoped to that section:
# the same key name in another section (e.g. [Service] or a decoy
# [Install]) is inert to Quadlet, so a unit could plant a harmless-looking
# duplicate elsewhere to defeat or satisfy a rule if lookups were global.
# R7 already scoped Restart=/RestartSec= to [Service] for the same reason;
# every Container-level key below now does the equivalent.
#
# The one deliberate exception is R3's "no inline Environment=" check and
# R11's `~`/`%h` scan: Environment= is ALSO a native systemd [Service]
# directive that Quadlet passes through verbatim, so a value hidden there
# is not a decoy - it really lands in the generated unit. Those two checks
# stay file-wide on purpose; do not scope them to [Container].

# R1 - pinned image (last [Container] Image= wins; tag matched exactly,
# case-insensitively)
image="$(get_last Image Container)"
if [ -z "$image" ]; then
  fail R1 "no Image= directive"
elif printf '%s' "$image" | grep -qE '@sha256:[0-9a-f]{64}$'; then
  : # pinned by digest - any trailing tag text is irrelevant
else
  after_slash="${image##*/}"
  case "$after_slash" in
    *:*) tag="${after_slash##*:}" ;;
    *)   tag="" ;;
  esac
  if [ -z "$tag" ]; then
    fail R1 "image is not pinned to a tag or digest: $image"
  elif [ "$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]')" = "latest" ]; then
    fail R1 "image uses the latest tag: $image"
  fi
fi

# R2 - userns mapping
printf '%s' "$(get_last UserNS Container)" | grep -q 'keep-id' || fail R2 "missing UserNS=keep-id"

# R3 - no inline environment. File-wide on purpose (see note above):
# Environment= under [Service] is real, not inert, to Quadlet.
[ -z "$(get_all Environment)" ] || fail R3 "inline Environment= is forbidden, use EnvironmentFile="
[ -n "$(get_all EnvironmentFile Container)" ] || fail R3 "missing EnvironmentFile="

# R4 - secrets shape: type=env|mount AND target= are both required
while IFS= read -r val; do
  [ -z "$val" ] && continue
  if ! printf '%s' "$val" | grep -qE 'type=(env|mount)'; then
    fail R4 "Secret= without type=env|mount: $val"
  elif ! printf '%s' "$val" | grep -qE 'target='; then
    fail R4 "Secret= without target=: $val"
  fi
done <<< "$(get_all Secret Container)"

# R5 - healthcheck, unless justified distroless. The exemption comment is a
# free-standing comment line, unaffected by directive normalization, so it
# is still matched against the raw file.
if [ -z "$(get_last HealthCmd Container)" ]; then
  grep -q '^# NO-HEALTHCHECK:' "$unit" \
    || fail R5 "no HealthCmd= and no '# NO-HEALTHCHECK:' justification comment"
else
  for k in HealthInterval HealthTimeout HealthRetries HealthStartPeriod; do
    [ -n "$(get_last "$k" Container)" ] || fail R5 "HealthCmd= present but $k= missing"
  done
fi

# R6 - explicit pull policy, no auto-update
[ "$(get_last Pull Container)" = "missing" ] || fail R6 "missing explicit Pull=missing"
[ -z "$(get_all AutoUpdate Container)" ] || fail R6 "AutoUpdate= contradicts a pinned image"

# R7 - restart policy. Restart=/RestartSec= only take effect in [Service];
# the same key name in another section is inert, so it must be checked
# section-scoped rather than anywhere in the file.
[ "$(get_last Restart Service)" = "always" ] || fail R7 "missing [Service] Restart=always"
[ -n "$(get_last RestartSec Service)" ] || fail R7 "missing RestartSec="

# R8 - bind mounts inside this service's tree only. Each host path is
# canonicalized with `realpath -m` (no existence required) before the
# prefix test, so a `..` segment cannot walk the mount out of the tree.
canon_tree="$(realpath -m -- "$tree")"
check_host_path() { # check_host_path <host> <description-for-error>
  local host="$1" what="$2" canon_host
  case "$host" in
    /*)
      canon_host="$(realpath -m -- "$host")"
      case "$canon_host" in
        "$canon_tree"/*) : ;;
        *) fail R8 "$what outside $tree: $host (resolves to $canon_host)" ;;
      esac
      ;;
    *) fail R8 "$what is a named volume or non-absolute path: $host" ;;
  esac
}

while IFS= read -r val; do
  [ -z "$val" ] && continue
  check_host_path "${val%%:*}" "bind mount"
done <<< "$(get_all Volume Container)"

# R8 (continued) - Mount= is the long-form spelling of a bind mount
# (`Mount=type=bind,source=/etc,destination=/host-etc,ro`) and gets the
# same host-path treatment: parse its source=/src= field (the src= alias
# is accepted the same as source=) and require it under the tree. Entries
# with no source=/src= (e.g. type=tmpfs) have no host path to check.
while IFS= read -r val; do
  [ -z "$val" ] && continue
  src="$(printf '%s\n' "$val" | tr ',' '\n' | sed -nE 's/^(source|src)=//p' | tail -1)"
  [ -z "$src" ] && continue
  check_host_path "$src" "Mount= source"
done <<< "$(get_all Mount Container)"

# PodmanArgs= is the one directive Quadlet actually tokenizes/unquotes
# before building ExecStart (confirmed against `quadlet -dryrun`:
# `PodmanArgs=--cpus=1.0 "-v" /etc:/host-etc:ro` produces a real, unquoted
# `-v` argument). Volume= is NOT unquoted the same way - a quoted Volume=
# value keeps its literal quote characters and is correctly rejected by
# the absolute-path check above, so quoting is deliberately stripped only
# here, for PodmanArgs=, not anywhere else in the file.
dequote() { printf '%s' "$1" | tr -d "\"'"; }

# R8 (continued) - PodmanArgs= must not smuggle a bind mount around Volume=.
# The flag-match tolerates every real Quadlet form: `\`-continuation
# (already joined above), quoting (stripped above), a space or `=`
# separator, and a short option's value attached directly with no
# separator at all (`-v/etc:/host-etc:ro` is valid podman CLI syntax).
while IFS= read -r val; do
  [ -z "$val" ] && continue
  dq="$(dequote "$val")"
  printf '%s' "$dq" | grep -qE -- '(^|[[:space:]])(-v([[:space:]=]|[^[:space:]]|$)|--volume([[:space:]=]|$)|--mount([[:space:]=]|$))' \
    && fail R8 "PodmanArgs= smuggles a bind mount, use Volume= instead: $val"
done <<< "$(get_all PodmanArgs Container)"

# R9 - resource limits
[ -n "$(get_last Memory Container)" ]    || fail R9 "missing Memory="
[ -n "$(get_last PidsLimit Container)" ] || fail R9 "missing PidsLimit="
cpus_found=0
while IFS= read -r val; do
  [ -z "$val" ] && continue
  dq="$(dequote "$val")"
  printf '%s' "$dq" | grep -q -- '--cpus=' && cpus_found=1
done <<< "$(get_all PodmanArgs Container)"
[ "$cpus_found" -eq 1 ] || fail R9 "missing PodmanArgs=--cpus="

# R9 (continued) - PodmanArgs= must not smuggle a resource limit around
# Memory=/PidsLimit=, for the same reasons (quoting, attachment) as R8.
while IFS= read -r val; do
  [ -z "$val" ] && continue
  dq="$(dequote "$val")"
  printf '%s' "$dq" | grep -qE -- '(^|[[:space:]])(-m([[:space:]=]|[^[:space:]]|$)|--memory([[:space:]=]|$)|--pids-limit([[:space:]=]|$))' \
    && fail R9 "PodmanArgs= smuggles a resource limit, use Memory=/PidsLimit= instead: $val"
done <<< "$(get_all PodmanArgs Container)"

# R10 - explicit log driver
[ -n "$(get_last LogDriver Container)" ] || fail R10 "missing explicit LogDriver="

# R11 - absolute, canonical paths only. The scan stays section-wide on
# purpose (see note above): a real path directive outside [Container] -
# EnvironmentFile=, WorkingDirectory=, an Exec* line under [Service] - can
# carry a live ~ or %h just as easily, so restricting it to [Container]
# would blind the rule to those.
#
# It is narrowed by KEY instead, because R11 is a rule about paths: a tilde
# inside a prose value (`Description=fixture ~ a great service`) is not a
# path and must not fail.
#
# That narrowing is a DENY-list, deliberately, and must stay one. An
# allow-list of path-bearing keys fails OPEN: every Quadlet key it does not
# enumerate is silently unscanned, so the rule quietly rots as Podman adds
# keys, and a single typo in the list (`Entrypoint` has a lowercase p;
# `Unmask` has a sibling `Mask`) is an invisible hole. `man
# podman-systemd.unit` already defines ~147 keys and many carry a real host
# path - SeccompProfile=, LogOpt=path=, Entrypoint=, Mask=, Unmask=,
# HealthStartupCmd=, ReloadCmd=, DecryptionKey=, AuthFile=, CertDir=,
# Yaml=, ConfigMap=, Device=, AddDevice=, Rootfs=, File=, IgnoreFile=,
# SetWorkingDirectory=, WorkingDir=, ContainersConfModule=, GlobalArgs=,
# Artifact=, HealthLogDestination= ... enumerating them is a losing game.
#
# So: scan EVERY key, and exempt only keys whose value is prose or free
# text, where a tilde is punctuation rather than a path.
#   Description   - free-form text (man systemd.unit)
#   Documentation - space-separated URIs; a URL may legitimately contain
#                   `~` (http://example.com/~user/docs) and is not a
#                   filesystem path (man systemd.unit)
#   Annotation    - arbitrary user key=value metadata (man podman-systemd.unit)
#   Label         - arbitrary user key=value metadata (man podman-systemd.unit)
# A new Quadlet key is therefore scanned until someone deliberately decides
# it is prose, which is the safe direction for a linter to fail.
if printf '%s\n' "$norm" | awk -F'\t' '
    $2 !~ /^(Description|Documentation|Annotation|Label)$/ { print $3 }
  ' | grep -qE '(~|%h)'; then
  fail R11 "path uses ~ or the %h specifier instead of an absolute path"
fi
while IFS= read -r val; do
  [ -z "$val" ] && continue
  case "$val" in
    /*) : ;;
    *) fail R11 "EnvironmentFile= is not an absolute path: $val" ;;
  esac
done <<< "$(get_all EnvironmentFile Container)"

# The Quadlet generator must accept the unit.
# -user is a boolean flag: a positional directory argument is silently ignored
# and the generator reads its default search paths instead, validating nothing.
# QUADLET_UNIT_DIRS is the only way to point it at a specific directory.
if quadlet_bin="$("$HERE/find-quadlet.sh" 2>/dev/null)"; then
  tmp="$(mktemp -d)"; cp "$unit" "$tmp/"
  # A unit may reference sibling Quadlet units by filename - most commonly
  # `Network=<name>.network`, which is exactly what this skill's `internal`
  # placement generates. The generator resolves those references against
  # QUADLET_UNIT_DIRS, so linting the .container alone makes it abort with
  # `requested Quadlet unit <x>.network was not found` - a false LINT
  # failure on a perfectly conformant pair. Copy in only the siblings this
  # unit actually names (never the whole directory, which would drag
  # unrelated units' errors into this unit's result).
  unit_dir="$(cd "$(dirname "$unit")" && pwd)"
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    [ "$ref" = "$(basename "$unit")" ] && continue
    [ -f "$unit_dir/$ref" ] && cp "$unit_dir/$ref" "$tmp/"
  done <<< "$(printf '%s\n' "$norm" | awk -F'\t' '{print $3}' \
    | grep -oE '[A-Za-z0-9_.@-]+\.(network|volume|pod|image|build|kube)\b' | sort -u)"
  lint_out="$(QUADLET_UNIT_DIRS="$tmp" "$quadlet_bin" -dryrun -user 2>&1)"
  if ! echo "$lint_out" | grep -q 'Loading source unit file'; then
    fail LINT "quadlet -dryrun parsed no unit file - the lint did not run"
  elif echo "$lint_out" | grep -qiE 'unsupported key|error'; then
    fail LINT "quadlet -dryrun reported errors"
    # Report the generator's own per-unit diagnostics too, not just its
    # final "processing encountered some errors" summary: the summary names
    # no cause, and grepping for `error` alone misses lines like
    # `converting "x.container": requested Quadlet unit ... was not found`.
    echo "$lint_out" | grep -iE 'unsupported key|error|^[^ ]*: converting |converting "' | sed 's/^/    /'
  fi
  rm -rf "$tmp"
else
  echo "warning: quadlet generator not found, skipping -dryrun lint" >&2
fi

[ "$violations" -eq 0 ] && { echo "conformant"; exit 0; }
echo "$violations violation(s)"
exit 1
