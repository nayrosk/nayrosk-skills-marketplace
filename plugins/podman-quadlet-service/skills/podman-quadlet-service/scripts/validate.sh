#!/usr/bin/env bash
# Conformance linter for podman-quadlet-service units.
# Usage: validate.sh <path-to-.container-file>
# Exit 0 when conformant ("conformant" is printed).
# Exit 1 otherwise, with one diagnostic line per problem, on two possible
# prefixes:
#   "R<n>: <message>"  - a convention violation (R1..R14, references/conventions.md)
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

# R1 - pinned image: tag AND digest (last [Container] Image= wins; tag
# matched exactly, case-insensitively). Digest-only and tag-only both fail.
image="$(get_last Image Container)"
if [ -z "$image" ]; then
  fail R1 "no Image= directive"
else
  digest_ok=0
  printf '%s' "$image" | grep -qE '@sha256:[0-9a-f]{64}$' && digest_ok=1
  ref="${image%@*}"
  after_slash="${ref##*/}"
  case "$after_slash" in
    *:*) tag="${after_slash##*:}" ;;
    *)   tag="" ;;
  esac
  if [ -z "$tag" ]; then
    fail R1 "image has no readable tag (want <image>:<tag>@sha256:<digest>): $image"
  elif [ "$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]')" = "latest" ]; then
    fail R1 "image uses the latest tag: $image"
  fi
  [ "$digest_ok" -eq 1 ] || fail R1 "image is not pinned to a sha256 digest (tags are mutable): $image"
fi

# Lifecycle profile (references/lifecycle.md), declared on a comment line.
# Read from the raw file like the NO-HEALTHCHECK marker. Used by R5 and R7.
profiles="$(tr -d '\r' < "$unit" | sed -nE 's/^#[[:space:]]*LIFECYCLE:[[:space:]]*([a-z-]+)[[:space:]]*$/\1/p')"
profile=""
case "$(printf '%s\n' "$profiles" | grep -c .)" in
  0) fail R7 "missing '# LIFECYCLE: daemon|on-demand|socket|job' declaration" ;;
  1) profile="$profiles"
     case "$profile" in
       daemon|on-demand|socket|job) : ;;
       *) fail R7 "unknown LIFECYCLE profile: $profile"; profile="" ;;
     esac ;;
  *) fail R7 "more than one LIFECYCLE declaration" ;;
esac

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

# R5 (continued) - profile-dependent healthcheck wiring
if [ -n "$(get_last HealthCmd Container)" ]; then
  case "$profile" in
    daemon)
      [ "$(get_last HealthOnFailure Container)" = "kill" ] \
        || fail R5 "daemon profile needs HealthOnFailure=kill, or the healthcheck triggers nothing" ;;
    on-demand|socket)
      [ "$(get_last Notify Container)" = "healthy" ] \
        || fail R5 "$profile profile needs Notify=healthy so consumers never hit a cold port" ;;
  esac
fi

# R6 - explicit pull policy, no auto-update
[ "$(get_last Pull Container)" = "missing" ] || fail R6 "missing explicit Pull=missing"
[ -z "$(get_all AutoUpdate Container)" ] || fail R6 "AutoUpdate= contradicts a pinned image"

# R7 - restart policy and unit shape must match the declared profile.
# Restart=/RestartSec= only take effect in [Service], StopWhenUnneeded= in
# [Unit]; the same key in another section is inert, so lookups are scoped.
restart="$(get_last Restart Service)"
stop_unneeded="$(get_last StopWhenUnneeded Unit)"
has_install=0
printf '%s\n' "$norm" | awk -F'\t' '$1=="Install"{f=1} END{exit !f}' && has_install=1
wanted_default=0
get_all WantedBy Install | tr ' ' '\n' | grep -qx 'default.target' && wanted_default=1
is_yes() { case "$1" in yes|true|on|1) return 0 ;; *) return 1 ;; esac; }
case "$profile" in
  daemon)
    [ "$restart" = "always" ] || fail R7 "daemon profile needs [Service] Restart=always"
    [ -n "$(get_last RestartSec Service)" ] || fail R7 "missing RestartSec="
    is_yes "$stop_unneeded" && fail R7 "daemon profile must not set StopWhenUnneeded=yes"
    [ "$wanted_default" -eq 1 ] || fail R7 "daemon profile needs [Install] WantedBy=default.target"
    ;;
  on-demand|socket)
    [ "$restart" = "on-failure" ] || fail R7 "$profile profile needs [Service] Restart=on-failure (always respawns after every out-of-band stop)"
    [ -n "$(get_last RestartSec Service)" ] || fail R7 "missing RestartSec="
    is_yes "$stop_unneeded" || fail R7 "$profile profile needs [Unit] StopWhenUnneeded=yes"
    [ "$has_install" -eq 0 ] || fail R7 "$profile profile must not have an [Install] section (it would start at login)"
    ;;
  job)
    case "$restart" in
      ""|no) : ;;
      on-failure) [ -n "$(get_last RestartSec Service)" ] || fail R7 "missing RestartSec=" ;;
      *) fail R7 "job profile needs Restart=no or on-failure, got: $restart" ;;
    esac
    is_yes "$stop_unneeded" && fail R7 "job profile must not set StopWhenUnneeded=yes"
    [ "$has_install" -eq 0 ] || fail R7 "job profile must not have an [Install] section (enable its .timer instead)"
    ;;
esac

# R8 - bind mounts inside this service's tree only. Each host path is
# canonicalized with `realpath -m` (no existence required) before the
# prefix test, so a `..` segment cannot walk the mount out of the tree.
canon_tree="$(realpath -m -- "$tree")"
# External mounts: a host path outside the service tree is allowed only when
# a marker names that exact path (compared canonically), it stays inside
# $HOME but is not $HOME itself nor a credential/config store, and - when it
# is another service's tree - it is mounted read-only.
#   # EXTERNAL-MOUNT: <absolute host path> - <why this service needs it>
canon_home="$(realpath -m -- "$HOME")"
external_marked() { # external_marked <canonical path>
  tr -d '\r' < "$unit" \
    | sed -nE 's/^#[[:space:]]*EXTERNAL-MOUNT:[[:space:]]*(\/[^[:space:]]*)[[:space:]]+-[[:space:]]+[^[:space:]].*/\1/p' \
    | while IFS= read -r m; do [ "$(realpath -m -- "$m")" = "$1" ] && echo yes && break; done | grep -q yes
}
check_host_path() { # check_host_path <host> <description-for-error> <is-readonly 0|1>
  local host="$1" what="$2" ro="${3:-0}" canon_host
  case "$host" in
    /*)
      canon_host="$(realpath -m -- "$host")"
      case "$canon_host" in
        "$canon_tree"/*) return ;;
      esac
      if ! external_marked "$canon_host"; then
        fail R8 "$what outside $tree without '# EXTERNAL-MOUNT: $canon_host - <reason>': $host"
        return
      fi
      case "$canon_host" in
        "$canon_home") fail R8 "$what mounts the whole home directory: $host"; return ;;
        "$canon_home"/*) : ;;
        *) fail R8 "$what outside \$HOME, even with a marker: $host"; return ;;
      esac
      case "${canon_host#"$canon_home"/}" in
        .ssh|.ssh/*|.gnupg|.gnupg/*|.config|.config/*|.local|.local/*|.password-store|.password-store/*|.kube|.kube/*|.aws|.aws/*|.docker|.docker/*|.claude|.claude/*)
          fail R8 "$what exposes a credential/config store, never allowed: $host"; return ;;
        .*/*|.*)
          [ "$ro" -eq 1 ] || fail R8 "$what is another service's tree and must be mounted read-only (:ro): $host" ;;
      esac
      ;;
    *) fail R8 "$what is a named volume or non-absolute path: $host" ;;
  esac
}
while IFS= read -r val; do
  [ -z "$val" ] && continue
  vopts=""
  case "$val" in *:*:*) vopts="${val##*:}" ;; esac
  vro=0; printf '%s' ",$vopts," | grep -q ',ro,' && vro=1
  check_host_path "${val%%:*}" "bind mount" "$vro"
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
  mro=0; printf '%s' ",$val," | grep -qE ',(ro|readonly)(=true)?,' && mro=1
  check_host_path "$src" "Mount= source" "$mro"
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
  printf '%s' "$dq" | grep -qE -- '(^|[[:space:]])(-v([[:space:]=]|[^[:space:]]|$)|--volume([[:space:]=]|$)|--mount([[:space:]=]|$)|--volumes-from([[:space:]=]|$))' \
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

# R12 - graceful, observable stop
to_usec() { # to_usec <systemd timespan> -> microseconds, or empty if unparsable
  local v="$1"
  case "$v" in ''|*[!0-9a-z\ .]*) return ;; esac
  case "$v" in *[!0-9]*) : ;; *) v="${v}s" ;; esac  # bare number = seconds
  # Line 2 of `systemd-analyze timespan` is the microsecond count ("μs: N").
  systemd-analyze timespan "$v" 2>/dev/null | sed -n 2p | grep -oE '[0-9]+$'
}
stop_timeout="$(get_last StopTimeout Container)"
stop_sec="$(get_last TimeoutStopSec Service)"
if [ -z "$stop_timeout" ]; then
  fail R12 "missing StopTimeout= (grace period before SIGKILL)"
elif ! printf '%s' "$stop_timeout" | grep -qE '^[0-9]+$'; then
  fail R12 "StopTimeout= must be a whole number of seconds: $stop_timeout"
fi
if [ -z "$stop_sec" ]; then
  fail R12 "missing [Service] TimeoutStopSec= (must exceed StopTimeout=)"
elif [ -n "$stop_timeout" ] && printf '%s' "$stop_timeout" | grep -qE '^[0-9]+$'; then
  a="$(to_usec "$stop_sec")"
  if [ -z "$a" ]; then
    fail R12 "TimeoutStopSec= is not a parsable timespan: $stop_sec"
  elif [ "$a" -le $((stop_timeout * 1000000)) ]; then
    fail R12 "TimeoutStopSec=$stop_sec must be greater than StopTimeout=$stop_timeout"
  fi
fi
if [ "$(get_last RunInit Container)" != "true" ] && ! grep -qE '^#[[:space:]]*PID1:[[:space:]]*[^[:space:]].* - [^[:space:]]' "$unit"; then
  fail R12 "no RunInit=true and no '# PID1: <entrypoint> - <reason>' justification"
fi
while IFS= read -r val; do
  [ -z "$val" ] && continue
  for tok in $val; do
    case "$(printf '%s' "$tok" | tr '[:lower:]' '[:upper:]')" in
      137|SIGKILL|KILL) fail R12 "SuccessExitStatus= must never accept SIGKILL (137): $val" ;;
    esac
  done
done <<< "$(get_all SuccessExitStatus Service)"

# R13 - hardening baseline; each relaxation needs a marker naming its key:
#   # HARDENING-EXCEPTION: <Key> - <tested reason>
exceptions="$(tr -d '\r' < "$unit" | sed -nE 's/^#[[:space:]]*HARDENING-EXCEPTION:[[:space:]]*([A-Za-z]+)[[:space:]]+-[[:space:]]+[^[:space:]].*/\1/p')"
excepted() { printf '%s\n' "$exceptions" | grep -qx "$1"; }
need_exc() { excepted "$1" || fail R13 "$2 without '# HARDENING-EXCEPTION: $1 - <reason>'"; }
[ "$(get_last NoNewPrivileges Container)" = "true" ] || need_exc NoNewPrivileges "NoNewPrivileges=true missing"
get_all DropCapability Container | tr ' ' '\n' | grep -qix 'all' || need_exc DropCapability "DropCapability=ALL missing"
[ -n "$(get_all AddCapability Container)" ] && need_exc AddCapability "AddCapability= present"
[ "$(get_last ReadOnly Container)" = "true" ] || need_exc ReadOnly "ReadOnly=true missing"
[ "$(get_last SeccompProfile Container)" = "unconfined" ] && need_exc SeccompProfile "SeccompProfile=unconfined"
[ "$(get_last SecurityLabelDisable Container)" = "true" ] && need_exc SecurityLabelDisable "SecurityLabelDisable=true"
while IFS= read -r val; do
  [ -z "$val" ] && continue
  dq="$(dequote "$val")"
  printf '%s' "$dq" | grep -qE -- '(^|[[:space:]])--(privileged|cap-add|security-opt)([[:space:]=]|$)' \
    && fail R13 "PodmanArgs= must not carry --privileged/--cap-add/--security-opt, use native keys: $val"
done <<< "$(get_all PodmanArgs Container)"

# R14 - no outbound network unless justified. Egress is all-or-nothing:
# a unit has none only when EVERY Network= it joins is `none` or a sibling
# <x>.network Quadlet unit whose last [Network] Internal= is a systemd true
# value. No Network= at all means the rootless default network, which has
# egress; so do host, pasta, slirp4netns, podman, bridge, container:, ns:,
# a bare network name, and a <x>.network that is not a sibling file (its
# Internal= cannot be checked, e.g. an existing proxy network). Any of
# those needs `# EGRESS: <what the app reaches outside, and the evidence>` (non-empty).
# Sibling units are read with their drop-ins (<x>.network.d/*.conf), and
# Pod=<x>.pod is judged by the pod's own [Pod] Network= values. `:options`
# after the network name (Network=x.network:ip=...) are ignored.
# The network must never be set through PodmanArgs= (invisible to this
# check and to a reader), marker or not.
egress_marker=0
tr -d '\r' < "$unit" | grep -qE '^#[[:space:]]*EGRESS:[[:space:]]*[^[:space:]]' && egress_marker=1
# unit_values <unit file> <Section> <Key> -> every value of Key in [Section],
# reading the file then its drop-ins (<file>.d/*.conf, in name order) like
# systemd does; a bare `Key=` resets the list. Last line = effective value.
unit_values() {
  local f="$1" files=("$1") d
  for d in "$f".d/*.conf; do [ -f "$d" ] && files+=("$d"); done
  awk -v want="[$2]" -v k="$3" '
    FNR == 1 { section = "" }
    { line = $0; gsub(/^[ \t]+|[ \t\r]+$/, "", line) }
    line == "" || line ~ /^[#;]/ { next }
    line ~ /^\[.*\]$/ { section = line; next }
    section == want {
      key = line; sub(/[ \t]*=.*/, "", key)
      if (key != k || line !~ /=/) next
      v = line; sub(/^[^=]*=[ \t]*/, "", v)
      if (v == "") n = 0; else vals[++n] = v
    }
    END { for (i = 1; i <= n; i++) print vals[i] }
  ' "${files[@]}"
}
is_true() { case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in 1|yes|true|on) return 0 ;; esac; return 1; }
egress_via=()
# judge_network <Network= value> <label> -> appends to egress_via when it
# gives outbound access.
judge_network() {
  local name="${1%%:*}" label="$2" sib
  case "$name" in
    none) ;;
    *.network)
      sib="$(dirname "$unit")/$name"
      if [ ! -f "$sib" ]; then egress_via+=("$label$name (not a sibling unit, Internal= unknown)")
      elif ! is_true "$(unit_values "$sib" Network Internal | tail -1)"; then
        egress_via+=("$label$name (not Internal=true)")
      # Quadlet creates the network with `podman network create --ignore`:
      # a NetworkName= that already exists is silently REUSED as is, so
      # Internal=true is not applied. `podman` (the default network) always
      # exists and is never internal. Other clashes are runtime state and
      # are caught by the SKILL.md step 9 `podman network inspect` check.
      elif [ "$(unit_values "$sib" Network NetworkName | tail -1)" = "podman" ]; then
        egress_via+=("$label$name (NetworkName=podman reuses the default network)")
      fi ;;
    *) egress_via+=("$label$name") ;;
  esac
}
# Pod= puts the container in the pod's network namespace: judge the pod's
# own [Pod] Network= values (from a sibling <x>.pod unit) as well.
pod="$(get_last Pod Container)"
if [ -n "$pod" ]; then
  podfile="$(dirname "$unit")/$pod"
  if [ ! -f "$podfile" ]; then
    egress_via+=("Pod=$pod (not a sibling unit, its network is unknown)")
  else
    podnets="$(unit_values "$podfile" Pod Network)"
    if [ -z "$podnets" ]; then egress_via+=("Pod=$pod (no Network=, rootless default network)")
    else while IFS= read -r net; do judge_network "$net" "Pod=$pod Network="; done <<< "$podnets"
    fi
  fi
fi
networks="$(get_all Network Container)"
if [ -z "$networks" ]; then
  [ -z "$pod" ] && egress_via+=("no Network= (rootless default network)")
else
  while IFS= read -r net; do [ -n "$net" ] && judge_network "$net" "Network="; done <<< "$networks"
fi
if [ "$egress_marker" -eq 0 ]; then
  for via in "${egress_via[@]+"${egress_via[@]}"}"; do
    fail R14 "$via gives outbound access without '# EGRESS: <what the app reaches outside, and the evidence>'"
  done
fi
while IFS= read -r val; do
  [ -z "$val" ] && continue
  # --pod joins a pod's network namespace, bypassing Network= entirely.
  printf '%s' "$(dequote "$val")" | grep -qE -- '(^|[[:space:]])--(net|network|pod)([[:space:]=]|$)' \
    && fail R14 "PodmanArgs= must not set the network or pod, use Network=: $val"
done <<< "$(get_all PodmanArgs Container)"

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
    [ -d "$unit_dir/$ref.d" ] && cp -r "$unit_dir/$ref.d" "$tmp/"
    # A .pod unit names its own networks: copy those too.
    case "$ref" in *.pod)
      while IFS= read -r sub; do
        [ -n "$sub" ] && [ -f "$unit_dir/$sub" ] && cp "$unit_dir/$sub" "$tmp/"
      done <<< "$(grep -oE '[A-Za-z0-9_.@-]+\.network\b' "$unit_dir/$ref" | sort -u)" ;;
    esac
  done <<< "$(printf '%s\n' "$norm" | awk -F'\t' '{print $3}' \
    | grep -oE '[A-Za-z0-9_.@-]+\.(network|volume|pod|image|build|kube)\b' | sort -u)"
  # `quadlet -dryrun` writes the GENERATED UNIT BODY to stdout and its own
  # diagnostics to stderr, one line each, prefixed `quadlet-generator[<pid>]: `.
  # Matching /error/ against the COMBINED stream therefore rejected any unit
  # whose own text merely contained that substring - `Image=ghcr.io/example/
  # errortracker:1.2.3`, `Description=... error-tracking ...`, a HealthCmd=
  # that greps for "error" - with a LINT failure that names nothing wrong,
  # while every R-rule passed. That is unrecoverable for the workflow, since
  # SKILL.md forbids force-installing past a validate.sh failure. So: discard
  # stdout, and match only what the generator itself said on stderr.
  lint_err="$(QUADLET_UNIT_DIRS="$tmp" "$quadlet_bin" -dryrun -user 2>&1 1>/dev/null)"
  lint_rc=$?
  # Narrow further to the generator's own log lines by stripping its
  # `quadlet-generator[<pid>]: ` prefix, so only lines it actually emitted are
  # matched. If a build logs with some other prefix, nothing matches and we
  # fall back to the raw stderr - still generator-only, never the unit body.
  diags="$(printf '%s\n' "$lint_err" | sed -nE 's/^quadlet-generator(\[[0-9]+\])?: //p')"
  [ -n "$diags" ] || diags="$lint_err"
  # A run that read the unit at all logs one `Loading source unit file <path>`
  # line per unit; its absence means the lint never ran (e.g. the generator
  # searched the wrong directory) and must not be mistaken for a clean pass.
  if ! printf '%s\n' "$lint_err" | grep -q 'Loading source unit file'; then
    fail LINT "quadlet -dryrun parsed no unit file - the lint did not run"
  # The generator exits non-zero when it rejects a unit; the pattern match is
  # a second, independent signal so a build that reports an error but still
  # exits 0 is not silently accepted.
  elif [ "$lint_rc" -ne 0 ] \
    || printf '%s\n' "$diags" | grep -qE 'unsupported key|^converting |encountered some errors'; then
    fail LINT "quadlet -dryrun reported errors"
    # Report the generator's own per-unit diagnostics, not just its final
    # "processing encountered some errors" summary, which names no cause.
    printf '%s\n' "$diags" | grep -v '^Loading source unit file' | sed 's/^/    /'
  fi
  rm -rf "$tmp"
else
  echo "warning: quadlet generator not found, skipping -dryrun lint" >&2
fi

[ "$violations" -eq 0 ] && { echo "conformant"; exit 0; }
echo "$violations violation(s)"
exit 1
