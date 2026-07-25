#!/usr/bin/env bash
# Locate the Podman Quadlet generator.
# Distributions disagree on its path, so probe the known locations and fall
# back to a search under the usual prefixes.
# Prints the absolute path on stdout (exit 0), or a diagnostic on stderr (exit 1).
set -uo pipefail

candidates=(
  /usr/lib/podman/quadlet
  /usr/libexec/podman/quadlet
  /usr/local/lib/podman/quadlet
  /usr/local/libexec/podman/quadlet
)

# Honour an explicit override first: some users install podman in a prefix.
if [ -n "${QUADLET_BIN:-}" ] && [ -x "${QUADLET_BIN}" ]; then
  echo "$QUADLET_BIN"; exit 0
fi

for c in "${candidates[@]}"; do
  [ -x "$c" ] && { echo "$c"; exit 0; }
done

found="$(find /usr/lib /usr/libexec /usr/local -maxdepth 4 -type f -name quadlet \
         -perm -u+x 2>/dev/null | head -1)"
[ -n "$found" ] && { echo "$found"; exit 0; }

cat >&2 <<'EOF'
Quadlet generator not found.
Looked in /usr/lib/podman, /usr/libexec/podman, /usr/local/{lib,libexec}/podman.
Install the podman package that ships the Quadlet generator, or set QUADLET_BIN
to its absolute path.
EOF
exit 1
