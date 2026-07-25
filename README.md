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

Clone the repository anywhere, then symlink or copy it into a skills
directory:

```bash
git clone https://github.com/<owner>/podman-quadlet-service.git
ln -s "$PWD/podman-quadlet-service" "$HOME/.claude/skills/podman-quadlet-service"
```

## Usage

Ask Claude Code to install a service with Podman; the skill triggers on its
own based on the request. The workflow stops at an approval gate, presenting
the proposed image, version, network placement, volumes and resource limits,
before writing anything to disk.

## What it enforces

| Rule | Requirement |
|---|---|
| R1 | `Image=` carries an explicit version tag or digest; `latest` and untagged are rejected |
| R2 | `UserNS=keep-id` (or `keep-id:uid=N,gid=N`) present |
| R3 | Zero `Environment=` lines; non-secret variables come from `EnvironmentFile=` |
| R4 | Secrets only via `Secret=<name>,type=env,target=VAR` or `type=mount,target=/path` |
| R5 | `HealthCmd=` present with interval/timeout/retries/start-period, unless justified with a `# NO-HEALTHCHECK:` comment |
| R6 | `Pull=missing` stated explicitly; `AutoUpdate=` absent |
| R7 | `[Service] Restart=always` with `RestartSec=` |
| R8 | Every `Volume=` host path is absolute and under `$HOME/.<SERVICE_NAME>/`; no named volumes, no `.volume` units |
| R9 | Resource limits present: `Memory=`, `PidsLimit=`, `PodmanArgs=--cpus=` |
| R10 | JSON logging preferred via the application's own option; otherwise `LogDriver=` set explicitly |
| R11 | All paths absolute and canonical - no `~`, no `%h`, no relative paths |

See `references/conventions.md` for the full rationale and examples behind
each rule.

## Standalone linter

`scripts/validate.sh path/to/unit.container` checks a Quadlet unit against
the rules above and works without Claude:

```bash
scripts/validate.sh path/to/unit.container
```

Exit 0 means conformant; exit 1 prints one `R<n>: <message>` line per
violation.

## License

MIT. See `LICENSE`.
