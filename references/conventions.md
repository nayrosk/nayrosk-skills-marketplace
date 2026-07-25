# Conventions

These are the eleven conventions every Quadlet unit produced by this skill
must follow. Each rule has a stable ID (`R1`..`R11`) that is also used by
`scripts/validate.sh` as the prefix of the violation it reports (e.g. `R1:
...`) and by the conformance checklist in `SKILL.md`. The IDs never get
renumbered, merged, or reused.

Examples below use `%HOME%` as a stand-in for the user's home directory:
`%HOME%` means the value of `$HOME`, resolved to an absolute path at
generation time. Quadlet's own `%h` specifier is deliberately **not** used
anywhere in generated units — R11 forbids it, along with `~` and any other
relative or unresolved path form.

### Home-directory notation: three spellings, one meaning

The repository uses a different token for the home directory in each kind
of file. They all denote the same thing — the absolute value of `$HOME` —
but only one of them is ever substituted:

| Spelling | Where it appears | What to do with it |
|---|---|---|
| `%HOME%` | this document's examples, only | **Documentation notation.** Never write it into a file. It exists so an example path reads as a path; it is not a placeholder to substitute, and it is not a systemd specifier. |
| `<HOME>` | `references/templates/` | **The real placeholder.** Substitute it with the resolved absolute home directory when generating a unit, `.env`, or runbook. |
| `$HOME` | `SKILL.md`, `references/preflight.md`, runbook shell snippets | **A shell variable**, in text meant to be run by a shell, where the shell expands it. |

The one mistake to avoid: writing `%HOME%` into a generated unit. It is not
a systemd specifier, so systemd would not expand it — Quadlet would pass the
literal string `%HOME%/...` through as a path and the mount would fail. The
`%`-delimited form resembles `%h`, which R11 forbids for its own reasons;
`%HOME%` is not that either. When generating from a template, the token to
look for and replace is `<HOME>`.

## R1 - Pinned image version

Always pin an explicit version. When upstream publishes no semver, pin the
digest.

✅ Correct
```ini
Image=docker.io/library/postgres:16.4
Image=ghcr.io/example/app@sha256:0f7a...c21
```

❌ Incorrect
```ini
Image=docker.io/library/postgres:latest
Image=docker.io/library/postgres
```

Why: `latest` turns a restart into an uncontrolled upgrade. The unit must state
exactly what will run.

## R2 - Rootless UID/GID mapping

`UserNS=keep-id` maps the container's user onto the invoking user's own
UID/GID, so files written by the container are owned by the host user
instead of a namespaced UID. Use the explicit form when the in-container
process needs a specific UID/GID.

✅ Correct
```ini
UserNS=keep-id
UserNS=keep-id:uid=1000,gid=1000
```

❌ Incorrect
```ini
UserNS=host
UserNS=auto
```

Why: `keep-id` is what makes bind-mounted host directories (R8) readable and
writable by the container without extra chown steps or root mapping tricks.

## R3 - No inline environment variables

The unit contains zero `Environment=` lines. Non-secret variables live in the
service's `.env` file.

✅ Correct
```ini
EnvironmentFile=%HOME%/.myservice/.env
```

❌ Incorrect
```ini
Environment=TZ=Etc/UTC
Environment=LOG_LEVEL=info
```

Why: keeps configuration in one greppable place outside the unit, and keeps the
unit diffable across versions.

## R4 - Secrets only via podman secrets

Credentials, tokens, and keys never appear as plain values in the unit or in
`.env`. They are created with `podman secret create` and referenced by name,
either injected as an environment variable or mounted as a file.

✅ Correct
```ini
Secret=myservice_db_password,type=env,target=DB_PASSWORD
Secret=myservice_tls_key,type=mount,target=/run/secrets/tls.key
```

❌ Incorrect
```ini
Environment=DB_PASSWORD=hunter2
```
```bash
# .env
DB_PASSWORD=hunter2
```

Why: `podman secret` keeps sensitive material out of process listings, unit
files, and `.env` files that might get copied or committed by accident.

## R5 - Healthcheck required

`HealthCmd=` is present together with `HealthInterval=`, `HealthTimeout=`,
`HealthRetries=`, and `HealthStartPeriod=`, so systemd and Podman can detect
a wedged container instead of leaving it silently broken.

✅ Correct
```ini
HealthCmd=curl -f http://localhost:8080/health || exit 1
HealthInterval=30s
HealthTimeout=5s
HealthRetries=3
HealthStartPeriod=30s
```

❌ Incorrect
```ini
# no HealthCmd at all
```

Why: without a healthcheck, a container that is running but not serving
requests looks identical to a healthy one from systemd's point of view.

The only exception is a distroless image with no shell and no suitable
binary to run a check with. In that case the healthcheck is omitted and the
omission is recorded in the unit in exactly this form, because
`scripts/validate.sh` greps for this literal prefix:

```ini
# NO-HEALTHCHECK: distroless image, no shell available - <reason>
```

`<reason>` is a short, specific justification (for example, which base image
was used and why no alternative check command exists), not a placeholder
left unfilled.

## R6 - Explicit pull policy, no auto-update

`Pull=missing` is stated explicitly, so a restart never re-pulls an image
that is already present locally. `AutoUpdate=` is absent: image upgrades are
a deliberate, reviewed action (re-pin the tag or digest per R1), not a
background process.

✅ Correct
```ini
Pull=missing
```

❌ Incorrect
```ini
Pull=always
AutoUpdate=registry
```

Why: an unattended image swap defeats the point of pinning a version in R1.

## R7 - Restart policy

The `[Service]` section sets `Restart=always` with an explicit `RestartSec=`,
so the unit comes back after a crash or host reboot without unbounded
restart-loop churn.

✅ Correct
```ini
[Service]
Restart=always
RestartSec=10
```

❌ Incorrect
```ini
[Service]
Restart=on-failure
```

Why: `always` also covers exit code 0 (a container that exits cleanly but
should still be running), and `RestartSec=` prevents a hot crash-loop from
hammering the host.

## R8 - Bind-mounted, absolute, per-service storage

Every `Volume=` host path is absolute and lives under
`%HOME%/.<SERVICE_NAME>/`. No named volumes and no separate `.volume` unit
files: the whole service tree stays visible with plain filesystem tools.

✅ Correct
```ini
Volume=%HOME%/.myservice/data:/data:Z
Volume=%HOME%/.myservice/config:/config:ro,Z
```

❌ Incorrect
```ini
Volume=myservice-data:/data
Volume=./data:/data
```

Why: named volumes and relative paths hide state inside Podman's storage
tree, making backup, inspection, and manual recovery harder than `ls` and
`cp` on a known directory.

`Volume=` is the only accepted spelling for a bind mount, and
`scripts/validate.sh` enforces that, not just the path rule:

- **`Mount=` is checked the same way, not exempt.** It is the long-form
  spelling of the same thing
  (`Mount=type=bind,source=%HOME%/.myservice/data,destination=/data`), so
  its `source=` (or `src=`) host path must be absolute and under
  `%HOME%/.<SERVICE_NAME>/` exactly as a `Volume=` source must. An entry
  with no host path at all (`type=tmpfs`) has nothing to check and passes.
- **`PodmanArgs=` must not smuggle a mount past that check.** `-v`,
  `--volume` and `--mount` in `PodmanArgs=` are rejected outright,
  whatever their value, because Quadlet tokenizes and unquotes
  `PodmanArgs=` into the real `podman run` command line. The rejection
  covers every form that reaches podman: quoted (`"-v" /etc:/host-etc`),
  `\`-continued across lines, `=`-separated, and a short option's value
  attached with no separator (`-v/etc:/host-etc:ro`).

❌ Also incorrect — same rule, different spelling
```ini
Mount=type=bind,source=/etc,destination=/host-etc,ro
PodmanArgs=-v /etc:/host-etc:ro
PodmanArgs=--mount type=bind,source=/etc,destination=/host-etc
```

Why: a rule that only inspected `Volume=` would be trivially bypassed by
writing the same bind mount another way; all three spellings end up as the
same `podman run` argument.

## R9 - Resource limits

`Memory=` and `PidsLimit=` are set natively. Quadlet has no native CPU-limit
key, so the CPU limit is passed through `PodmanArgs=--cpus=`.

✅ Correct
```ini
Memory=512m
PidsLimit=256
PodmanArgs=--cpus=1.0
```

❌ Incorrect
```ini
# no Memory=, no PidsLimit=, no PodmanArgs=--cpus=
```

Why: an unbounded container can starve the host of memory or exhaust its PID
table; explicit limits keep one service's misbehavior from taking down the
rest of the machine.

Memory and PID limits are set with the native keys only.
`scripts/validate.sh` rejects `-m`, `--memory` and `--pids-limit` in
`PodmanArgs=`, in every form Quadlet accepts (quoted, `\`-continued,
`=`-separated, or with the value attached directly to a short option, as in
`-m512m`), for the same reason R8 rejects `-v` there. `--cpus=` is the one
deliberate exception, because Quadlet has no native key for it.

❌ Also incorrect — native key bypassed through `PodmanArgs=`
```ini
PodmanArgs=--cpus=1.0 -m 512m
PodmanArgs=--cpus=1.0 --pids-limit 256
```

Why: `Memory=` and `PidsLimit=` are the keys a reader (and a future
regeneration of this unit) looks at; a limit hidden in a `PodmanArgs=`
string is invisible to both, and a later edit that rewrites that line drops
the limit silently.

### Note: `DropCapability=ALL` and images with file capabilities

Not a rule, but the failure it causes is easy to misdiagnose as a broken
image. The template's `DropCapability=ALL` empties the capability
**bounding** set. The kernel refuses to `exec` a binary that carries
*permitted* file capabilities when those capabilities are not in the
bounding set, so such a container dies immediately — before any
healthcheck ever runs — with:

```
exec container process `/usr/bin/<binary>`: Operation not permitted
```

This is common for web servers built to bind ports below 1024
(`cap_net_bind_service=ep` on the entrypoint binary) and it happens even
when the container is not actually asked to bind a privileged port. Check
the image before blaming it:

```bash
podman run --rm --entrypoint /bin/sh <REGISTRY>/<IMAGE>:<TAG> \
  -c 'getcap /usr/bin/<binary>'
```

Then add back only the capability it names, with a comment saying why:

```ini
DropCapability=ALL
# /usr/bin/<binary> carries cap_net_bind_service=ep; an empty bounding set
# makes exec fail with EPERM before the process starts.
AddCapability=NET_BIND_SERVICE
```

Note the diagnosis needs `journalctl --user -u <SERVICE_NAME>`, not `podman
logs`: the container is already removed by the time the failure is visible.

## R10 - Structured logging

The application's own JSON logging option is preferred when it has one (for
example `LOG_FORMAT=json` in `.env`, per R3). Otherwise `LogDriver=` is set
explicitly rather than left to the Podman default.

✅ Correct
```ini
LogDriver=journald
```

❌ Incorrect
```ini
# LogDriver= left unset, relying on whatever Podman defaults to
```

Why: an explicit driver makes log routing a stated fact of the unit instead
of an implicit default that can change across Podman versions.

## R11 - Absolute, canonical paths only

Every path in the unit — `EnvironmentFile=`, `Volume=` sources, secret mount
targets — is absolute and canonical. No `~`, no Quadlet's `%h` specifier, no
relative paths.

✅ Correct
```ini
EnvironmentFile=%HOME%/.myservice/.env
Volume=%HOME%/.myservice/data:/data:Z
```

❌ Incorrect
```ini
EnvironmentFile=~/.myservice/.env
EnvironmentFile=%h/.myservice/.env
Volume=./data:/data:Z
```

Why: `~` and `%h` are expanded by different layers (shell vs. systemd
specifier resolution) at different times, and relative paths depend on the
generator's current working directory; a canonical absolute path is
unambiguous regardless of who reads the unit.
