# Preflight Checks

Step 0 of workflow: **preflight runs before any service artifact written to disk.** Run every check below, in order, before creating any service tree, template, or unit file. Failed **ABORT** check stops workflow immediately - report check by name, do not proceed to later checks or install.

Two changes marked below (create Quadlet unit dir, enable linger after explicit yes) are host preconditions, not service artifacts - only exceptions to that rule. `SKILL.md` "write nothing before approval gate" is about service being installed. Creating unit dir may also defer to workflow step 6, which need it anyway; probing writability here is what matter.

All checks read-only except two marked as making change (unit dir creation, linger enablement - latter only runs after operator say yes).

Quadlet unit dir is `${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd`. Always resolve this way - never assume `$HOME/.config` - so check honour user `XDG_CONFIG_HOME` override.

Quadlet generator never referenced by literal path (lives in different places across distros). Locate by running skill `scripts/find-quadlet.sh`, which print generator absolute path on stdout and exit 0, or write diagnostic to stderr and exit 1 if not found, or if `QUADLET_BIN` set to non-executable value.

| Check | Command | Expected | On failure |
|---|---|---|---|
| Podman version | `podman --version` | version `>= 5.0` | **ABORT** - name found version and required minimum (5.0) |
| Rootless id mappings | `podman info --format '{{.Host.IDMappings.UIDMap}}'` | non-empty mapping | **ABORT** - subuid/subgid not configured for this user |
| Linger | `loginctl show-user "$USER" -p Linger` | `Linger=yes` | `daemon` profile only (decided in step 1, see "Profile-gated checks"): **ASK** before running `loginctl enable-linger "$USER"`; without linger, service stops when user logs out. Other profiles: **INFO** only |
| Quadlet unit dir | see "Unit directory writability" below | dir (or parent, if not yet created) writable | not abort - **CREATE** with `mkdir -p` when missing; **ABORT** if writability probe fail |
| Quadlet generator | `scripts/find-quadlet.sh` (from skill dir) | print absolute path on stdout, exit 0 | **ABORT** - exit 1 mean neither `.container` generation nor linting possible; report script stderr diagnostic |
| systemd user manager | see "systemd user manager" below | stdout exactly `running` or `degraded` | **ABORT** - stdout anything else, including empty (connection failure to user bus) |
| Cgroups version | `podman info --format '{{.Host.CgroupsVersion}}'` | `v2` | **WARN** - see "Cgroups v1 and resource limits" below; R9 limits not enforced |
| Free space | `df -h --output=avail "$HOME" \| tail -1` | enough free space for image and its data | **WARN** and ask operator whether to continue if space look insufficient for service being installed |

## Profile-gated checks

Some checks depend on the lifecycle profile (`references/lifecycle.md`),
which is only known after workflow step 1. Run them right after
classification, **before** the approval gate. They change nothing
persistent (the scope probe is a transient unit, gone when it exits).

| Profile | Check | Command | Expected | On failure |
|---|---|---|---|---|
| `daemon` | Linger | see table above | `Linger=yes` | **ASK** |
| `on-demand` | Transient scopes | `systemd-run --user --scope --quiet -p Wants=preflight-probe.service true` | exit 0 | **ABORT** - the wrapper cannot refcount the container; propose `socket` or `daemon` instead |
| `socket` | systemd version | `systemctl --version \| head -1` | `>= 246` (`--exit-idle-time=`) | **ABORT** for `socket`; propose `on-demand` or `daemon` |
| `socket` | Socket proxy | `for p in /usr/lib/systemd/systemd-socket-proxyd /lib/systemd/systemd-socket-proxyd; do [ -x "$p" ] && echo "$p" && break; done` | absolute path printed | **ABORT** for `socket`; the printed path fills `<SOCKET_PROXYD>` |
| `socket` | Port free | `ss -Hltn "sport = :<PUBLIC_PORT>"` and same for `<BACKEND_PORT>` | empty output | **ABORT** - name the listener (`ss -Hltnp`) |
| any | Supply-chain tools | `command -v cosign trivy grype` | any subset | **INFO** - list what exists; workflow step 1 uses them when present, never installs them |

## Unit directory writability

`ls -d` only prove dir exist; say nothing about whether writable, and workflow need write `.container` files into it. Probe writability direct, check parent dir instead when unit dir not exist yet (will be created there):

```bash
dir="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
if [ -d "$dir" ]; then
  test -w "$dir" && echo "writable: $dir" || echo "ABORT: not writable: $dir"
else
  parent="$(dirname "$dir")"
  test -w "$parent" && echo "CREATE: $dir (parent writable)" || echo "ABORT: parent not writable: $parent"
fi
```

If dir exist, `test -w "$dir"` must succeed. If not exist yet, `test -w` on parent must succeed before `mkdir -p` run; read-only parent is real failure worth catching here, not during install.

## systemd user manager

`systemctl --user is-system-running` exit 1 for both `degraded` (harmless - some unrelated user unit failed) and genuinely unreachable user bus, so exit status alone cannot distinguish acceptable system from broken one. Decide on stdout content instead:

```bash
state="$(systemctl --user is-system-running 2>/dev/null)"
case "$state" in
  running|degraded) : ;;  # PASS
  *) : ;;                 # ABORT - includes a connection failure, where $state is empty
esac
```

- `state` is `running` or `degraded` → pass, continue preflight.
- `state` anything else, including empty (happens when user bus unreachable - `systemctl` then print nothing to stdout and diagnostic like `Failed to connect to user scope bus...` to stderr) → **ABORT**, naming unexpected state (or "user bus unreachable" when `state` empty) and, if available, stderr diagnostic.

## Cgroups v1 and resource limits

```bash
podman info --format '{{.Host.CgroupsVersion}}'
```

Expect `v2`. Anything else (`v1`) is **WARN**, not ABORT: service install and run normal. What it not do is enforce limits.

Rootless Podman cannot delegate cgroup controllers on cgroups v1, so `Memory=`, `PidsLimit=` and `PodmanArgs=--cpus=` are **accepted, warned about, then ignored**. Podman print note like "Resource limits are not supported and ignored on cgroups V1 rootless systems" and start container unrestricted. Nothing downstream catch this: Quadlet generator convert those keys happily, so `scripts/validate.sh` report R9 satisfied and unit pass lint while enforcing no limit at all.

Say this to operator plain, not report R9 as met: on this host memory, PID and CPU limits in unit are documentation, not enforcement, and one misbehaving container can exhaust host memory or PID table. Fix is host with cgroups v2 (unified hierarchy) or rootful install; neither is something this skill change on its own. Keep R9 keys in unit regardless - cost nothing, correct, and take effect as written moment host move to v2.

## Notes on interpreting results

- **ABORT** mean: stop workflow now, state which check failed and why, create or modify no files. Operator must fix underlying condition (upgrade Podman, configure subuid/subgid, install Quadlet generator package, fix systemd user session) and re-run preflight from top.
- **ASK** mean: stop and get explicit yes/no from operator before taking associated action. Do not run `loginctl enable-linger` without confirmation.
- **CREATE** mean: expected on first run, not failure. Most systems not have `containers/systemd` under config dir until first Quadlet unit installed; create with `mkdir -p` and continue.
- **WARN** mean: surface concern to operator and ask whether to continue; does not stop workflow on its own.

## Minimum Podman version

Skill require Podman **5.0** or newer (Quadlet `.container`/`.volume` unit support and `[Container]` keys used by generated templates depend on it). Preflight enforce by parsing `podman --version` output and comparing against `5.0` - never assume or state which version installed on any particular machine; only compare against declared minimum at run time.