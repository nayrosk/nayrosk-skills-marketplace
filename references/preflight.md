# Preflight Checks

This is step 0 of the workflow: **preflight runs before anything is written
to disk.** Run every check below, in order, before creating any directory,
template, or unit file. A failed **ABORT** check stops the workflow
immediately — report the check by name and do not proceed to later checks
or to installation.

All checks are read-only except the two explicitly marked as making a
change (unit directory creation, and linger enablement, which only runs
after the operator says yes).

The Quadlet unit directory is `${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd`.
Always resolve it this way — never assume `$HOME/.config` directly — so the
check honours a user's `XDG_CONFIG_HOME` override.

The Quadlet generator is never referenced by a literal path (it lives in
different locations across distributions). It is located by running the
skill's `scripts/find-quadlet.sh`, which prints the generator's absolute
path on stdout and exits 0, or writes a diagnostic to stderr and exits 1
if it cannot be found, or if `QUADLET_BIN` is set to a non-executable
value.

| Check | Command | Expected | On failure |
|---|---|---|---|
| Podman version | `podman --version` | version `>= 5.0` | **ABORT** — name the found version and the required minimum (5.0) |
| Rootless id mappings | `podman info --format '{{.Host.IDMappings.UIDMap}}'` | a non-empty mapping | **ABORT** — subuid/subgid are not configured for this user |
| Linger | `loginctl show-user "$USER" -p Linger` | `Linger=yes` | **ASK** before running `loginctl enable-linger "$USER"`; without linger the service stops when the user logs out |
| Quadlet unit dir | see "Unit directory writability" below | directory (or its parent, if not yet created) is writable | not an abort — **CREATE** with `mkdir -p` when missing; **ABORT** if the writability probe fails |
| Quadlet generator | `scripts/find-quadlet.sh` (from the skill directory) | prints an absolute path on stdout, exit 0 | **ABORT** — exit 1 means neither `.container` generation nor linting is possible; report the script's stderr diagnostic |
| systemd user manager | see "systemd user manager" below | stdout is exactly `running` or `degraded` | **ABORT** — stdout is anything else, including empty (a connection failure to the user bus) |
| Free space | `df -h --output=avail "$HOME" \| tail -1` | enough free space for the image and its data | **WARN** and ask the operator whether to continue if space looks insufficient for the service being installed |

## Unit directory writability

`ls -d` only proves the directory exists; it says nothing about whether it
can be written to, and the workflow needs to write `.container` files into
it. Probe writability directly, checking the parent directory instead when
the unit directory itself does not exist yet (it will be created there):

```bash
dir="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
if [ -d "$dir" ]; then
  test -w "$dir" && echo "writable: $dir" || echo "ABORT: not writable: $dir"
else
  parent="$(dirname "$dir")"
  test -w "$parent" && echo "CREATE: $dir (parent writable)" || echo "ABORT: parent not writable: $parent"
fi
```

If the directory exists, `test -w "$dir"` must succeed. If it does not
exist yet, `test -w` on its parent must succeed before `mkdir -p` is run;
a read-only parent is a real failure worth catching here rather than
during installation.

## systemd user manager

`systemctl --user is-system-running` exits 1 for both `degraded` (harmless
— some unrelated user unit has failed) and for a genuinely unreachable
user bus, so the exit status alone cannot distinguish an acceptable system
from a broken one. Make the decision on stdout content instead:

```bash
state="$(systemctl --user is-system-running 2>/dev/null)"
case "$state" in
  running|degraded) : ;;  # PASS
  *) : ;;                 # ABORT — includes a connection failure, where $state is empty
esac
```

- `state` is `running` or `degraded` → pass, continue preflight.
- `state` is anything else, including empty (which happens when the user
  bus cannot be reached — `systemctl` then prints nothing to stdout and a
  diagnostic such as `Failed to connect to user scope bus...` to stderr) →
  **ABORT**, naming the unexpected state (or "user bus unreachable" when
  `state` is empty) and, if available, the stderr diagnostic.

## Notes on interpreting results

- **ABORT** means: stop the workflow now, state which check failed and why,
  and do not create or modify any files. The operator must fix the
  underlying condition (upgrade Podman, configure subuid/subgid, install
  the Quadlet generator package, fix the systemd user session) and re-run
  preflight from the top.
- **ASK** means: stop and get an explicit yes/no from the operator before
  taking the associated action. Do not run `loginctl enable-linger`
  without confirmation.
- **CREATE** means: this is expected on a first run and is not a failure.
  Most systems will not have `containers/systemd` under the config
  directory until the first Quadlet unit is installed; create it with
  `mkdir -p` and continue.
- **WARN** means: surface the concern to the operator and ask whether to
  continue; it does not stop the workflow on its own.

## Minimum Podman version

The skill requires Podman **5.0** or newer (Quadlet's `.container`/`.volume`
unit support and the `[Container]` keys used by the generated templates
depend on it). Preflight enforces this by parsing the output of
`podman --version` and comparing against `5.0` — never assume or state
which version is installed on any particular machine; only compare against
the declared minimum at run time.
