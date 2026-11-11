# podman-quadlet-service

A Claude Code skill that installs a containerized service as a rootless
Podman Quadlet systemd unit, enforcing a fixed set of conventions (pinned
image versions, podman secrets, healthchecks, bind mounts, resource limits,
reverse proxy routing), and generates runbooks for install, update, secret
rotation, and uninstall.

## What it does

The skill drives an end-to-end workflow for self-hosting a service with
rootless Podman: it researches a suitable image, proposes a plan at an
approval gate, generates a Quadlet unit that conforms to a fixed rule set,
installs and starts it under a user systemd session, verifies it is healthy,
and writes runbooks documenting exactly what was installed and how to
maintain it.

## Requirements

- Podman >= 5.0
- A rootless Podman setup with subuid/subgid configured for the user
- A systemd user session with linger enabled
- `bash`

## Install

### As a plugin (recommended)

Claude Code clones the marketplace repository, caches it, and handles updates:

```
/plugin marketplace add nayrosk/nayrosk-skills-marketplace
/plugin install podman-quadlet-service@nayrosk-skills-marketplace
```

### As a personal skill

Clone the marketplace repository anywhere, then symlink or copy the skill
directory into a skills directory:

```bash
git clone https://github.com/nayrosk/nayrosk-skills-marketplace.git
ln -s "$PWD/nayrosk-skills-marketplace/plugins/podman-quadlet-service/skills/podman-quadlet-service" \
      "$HOME/.claude/skills/podman-quadlet-service"
```

## Usage

Ask Claude Code to install a service with Podman; the skill triggers on its
own based on the request. The workflow stops at an approval gate, presenting
the proposed image, version, network placement, volumes and resource limits,
before writing anything to disk.

## Lifecycle profiles

Every unit declares when its container should exist (see
`skills/podman-quadlet-service/references/lifecycle.md`):

| Profile | For | Shape |
|---|---|---|
| `daemon` | always-up services (web apps, databases, proxies) | `Restart=always`, `WantedBy=default.target`, `HealthOnFailure=kill` |
| `on-demand` | backends of local client processes (MCP servers, IDE helpers) | `StopWhenUnneeded=yes`, clients launched through a `systemd-run --scope` wrapper that refcounts the container |
| `socket` | sporadically used network services | systemd `.socket` + `systemd-socket-proxyd --exit-idle-time`, container stops when idle |
| `job` | run-to-completion work | `Type=oneshot` + `.timer` |

## What it enforces

| Rule | Requirement |
|---|---|
| R1 | `Image=<image>:<tag>@sha256:<digest>`: readable tag **and** immutable digest; `latest`, tag-only and digest-only are rejected |
| R2 | `UserNS=keep-id` (or `keep-id:uid=N,gid=N`) present |
| R3 | Zero `Environment=` lines; non-secret variables come from `EnvironmentFile=` |
| R4 | Secrets only via `Secret=<name>,type=env,target=VAR` or `type=mount,target=/path` |
| R5 | `HealthCmd=` with interval/timeout/retries/start-period (or a `# NO-HEALTHCHECK:` justification); `daemon` adds `HealthOnFailure=kill`, `on-demand`/`socket` add `Notify=healthy` |
| R6 | `Pull=missing` stated explicitly; `AutoUpdate=` absent |
| R7 | A `# LIFECYCLE: daemon\|on-demand\|socket\|job` declaration, with matching `Restart=`, `StopWhenUnneeded=` and `[Install]` |
| R8 | Every `Volume=`/`Mount=` host path is absolute and under `$HOME/.<SERVICE_NAME>/`, or named by an `# EXTERNAL-MOUNT:` marker (inside `$HOME`, never a credential store, other services' trees read-only); no named volumes, no `--volumes-from` |
| R9 | Resource limits present: `Memory=`, `PidsLimit=`, `PodmanArgs=--cpus=` |
| R10 | JSON logging preferred via the application's own option; otherwise `LogDriver=` set explicitly |
| R11 | All paths absolute and canonical - no `~`, no `%h`, no relative paths |
| R12 | Graceful stop: `StopTimeout=`, `TimeoutStopSec=` greater than it, `RunInit=true` (or a `# PID1:` justification); `SuccessExitStatus=` never accepts SIGKILL/137 |
| R13 | Hardening baseline (`NoNewPrivileges`, `DropCapability=ALL`, `ReadOnly`, default seccomp/labels); each relaxation needs a keyed `# HARDENING-EXCEPTION: <Key> - <evidence>` marker; no `--privileged`/`--cap-add`/`--security-opt` |

See `skills/podman-quadlet-service/references/conventions.md` for the full rationale and examples behind
each rule.

## Standalone linter

`skills/podman-quadlet-service/scripts/validate.sh path/to/unit.container` checks a Quadlet unit against
the rules above and works without Claude:

```bash
skills/podman-quadlet-service/scripts/validate.sh path/to/unit.container
```

Exit codes:

| Exit | Meaning |
|---|---|
| 0 | Conformant; prints `conformant` |
| 1 | At least one problem; one diagnostic line per problem, then a count |
| 2 | Usage error (missing or unreadable unit path), not a conformance result |

Exit 1 uses two line prefixes, and both are real failures:

- `R<n>: <message>` - a convention violation (R1..R13)
- `LINT: <message>` - the Quadlet generator itself rejected the unit

Grepping only for `^R[0-9]` silently misses every `LINT:` failure. Match both:

```bash
skills/podman-quadlet-service/scripts/validate.sh unit.container | grep -E '^(R[0-9]+|LINT):'
```

## License

MIT. See `LICENSE`.
