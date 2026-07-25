# Conventions

Eleven conventions. Every Quadlet unit from this skill must follow. Each rule got stable ID (`R1`..`R11`). `scripts/validate.sh` use ID as violation prefix (e.g. `R1: ...`). Conformance checklist in `SKILL.md` use too. IDs never renumbered, merged, reused.

Examples below use `%HOME%` as stand-in for user home dir: `%HOME%` mean value of `$HOME`, resolved to absolute path at generation time. Quadlet own `%h` specifier deliberately **not** used anywhere in generated units - R11 forbid it, plus `~` and any other relative or unresolved path form.

### Home-directory notation: three spellings, one meaning

Repo use different token for home dir in each kind of file. All mean same thing - absolute value of `$HOME` - but only one ever substituted:

| Spelling | Where it appears | What to do with it |
|---|---|---|
| `%HOME%` | this document examples, only | **Doc notation.** Never write into file. Exist so example path read like path. Not placeholder to substitute, not systemd specifier. |
| `<HOME>` | `references/templates/` | **Real placeholder.** Substitute with resolved absolute home dir when generating unit, `.env`, or runbook. |
| `$HOME` | `SKILL.md`, `references/preflight.md`, runbook shell snippets | **Shell variable**, in text meant for shell to run, where shell expand it. |

One mistake to avoid: write `%HOME%` into generated unit. Not systemd specifier, so systemd not expand - Quadlet pass literal string `%HOME%/...` through as path, mount fail. `%`-delimited form look like `%h`, which R11 forbid for own reasons; `%HOME%` not that either. When generating from template, token to find and replace is `<HOME>`.

## R1 - Pinned image version

Always pin explicit version. Upstream publish no semver → pin digest.

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

Why: `latest` turn restart into uncontrolled upgrade. Unit must state exactly what run.

## R2 - Rootless UID/GID mapping

`UserNS=keep-id` map container user onto invoking user own UID/GID, so files container write owned by host user, not namespaced UID. Use explicit form when in-container process need specific UID/GID.

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

Why: `keep-id` make bind-mounted host dirs (R8) readable and writable by container, no extra chown steps or root mapping tricks.

## R3 - No inline environment variables

Unit contain zero `Environment=` lines. Non-secret vars live in service `.env` file.

✅ Correct
```ini
EnvironmentFile=%HOME%/.myservice/.env
```

❌ Incorrect
```ini
Environment=TZ=Etc/UTC
Environment=LOG_LEVEL=info
```

Why: keep config in one greppable place outside unit, keep unit diffable across versions.

## R4 - Secrets only via podman secrets

Credentials, tokens, keys never appear as plain values in unit or `.env`. Created with `podman secret create`, referenced by name - injected as env var or mounted as file.

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

Why: `podman secret` keep sensitive material out of process listings, unit files, `.env` files that might get copied or committed by accident.

## R5 - Healthcheck required

`HealthCmd=` present together with `HealthInterval=`, `HealthTimeout=`, `HealthRetries=`, `HealthStartPeriod=`, so systemd and Podman detect wedged container instead of leaving it silently broken.

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

Why: no healthcheck → container running but not serving look identical to healthy one from systemd view.

Only exception: distroless image with no shell and no suitable binary to run check. Then omit healthcheck and record omission in unit in exactly this form, because `scripts/validate.sh` grep for this literal prefix:

```ini
# NO-HEALTHCHECK: distroless image, no shell available - <reason>
```

`<reason>` = short, specific justification (example: which base image used, why no alternative check command exist). Not placeholder left unfilled.

## R6 - Explicit pull policy, no auto-update

`Pull=missing` stated explicitly, so restart never re-pull image already present locally. `AutoUpdate=` absent: image upgrade = deliberate reviewed action (re-pin tag or digest per R1), not background process.

✅ Correct
```ini
Pull=missing
```

❌ Incorrect
```ini
Pull=always
AutoUpdate=registry
```

Why: unattended image swap defeat point of pinning version in R1.

## R7 - Restart policy

`[Service]` section set `Restart=always` with explicit `RestartSec=`, so unit come back after crash or host reboot, no unbounded restart-loop churn.

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

Why: `always` also cover exit code 0 (container exit cleanly but should still run). `RestartSec=` stop hot crash-loop hammering host.

## R8 - Bind-mounted, absolute, per-service storage

Every `Volume=` host path absolute, lives under `%HOME%/.<SERVICE_NAME>/`. No named volumes, no separate `.volume` unit files: whole service tree stay visible with plain filesystem tools.

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

Why: named volumes and relative paths hide state inside Podman storage tree. Backup, inspection, manual recovery harder than `ls` and `cp` on known dir.

`Volume=` only accepted spelling for bind mount. `scripts/validate.sh` enforce that too, not just path rule:

- **`Mount=` checked same way, not exempt.** Long-form spelling of same thing (`Mount=type=bind,source=%HOME%/.myservice/data,destination=/data`), so its `source=` (or `src=`) host path must be absolute and under `%HOME%/.<SERVICE_NAME>/` exactly like `Volume=` source must. Entry with no host path at all (`type=tmpfs`) got nothing to check, pass.
- **`PodmanArgs=` must not smuggle mount past that check.** `-v`, `--volume`, `--mount` in `PodmanArgs=` rejected outright, whatever value, because Quadlet tokenize and unquote `PodmanArgs=` into real `podman run` command line. Rejection cover every form reaching podman: quoted (`"-v" /etc:/host-etc`), `\`-continued across lines, `=`-separated, and short option value attached with no separator (`-v/etc:/host-etc:ro`).

❌ Also incorrect - same rule, different spelling
```ini
Mount=type=bind,source=/etc,destination=/host-etc,ro
PodmanArgs=-v /etc:/host-etc:ro
PodmanArgs=--mount type=bind,source=/etc,destination=/host-etc
```

Why: rule inspecting only `Volume=` trivially bypassed by writing same bind mount another way. All three spellings end as same `podman run` argument.

## R9 - Resource limits

`Memory=` and `PidsLimit=` set natively. Quadlet got no native CPU-limit key, so CPU limit pass through `PodmanArgs=--cpus=`.

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

Why: unbounded container starve host of memory or exhaust PID table. Explicit limits keep one service misbehavior from taking down rest of machine.

Memory and PID limits set with native keys only. `scripts/validate.sh` reject `-m`, `--memory`, `--pids-limit` in `PodmanArgs=`, in every form Quadlet accept (quoted, `\`-continued, `=`-separated, or value attached direct to short option, like `-m512m`) - same reason R8 reject `-v` there. `--cpus=` = one deliberate exception, because Quadlet got no native key for it.

❌ Also incorrect - native key bypassed through `PodmanArgs=`
```ini
PodmanArgs=--cpus=1.0 -m 512m
PodmanArgs=--cpus=1.0 --pids-limit 256
```

Why: `Memory=` and `PidsLimit=` = keys reader (and future regeneration of unit) look at. Limit hidden in `PodmanArgs=` string invisible to both, and later edit rewriting that line drop limit silently.

### Note: `DropCapability=ALL` and images with file capabilities

Not rule, but failure it cause easy to misdiagnose as broken image. Template `DropCapability=ALL` empty capability **bounding** set. Kernel refuse to `exec` binary carrying *permitted* file capabilities when those caps not in bounding set, so such container die immediately - before any healthcheck run - with:

```
exec container process `/usr/bin/<binary>`: Operation not permitted
```

Common for web servers built to bind ports below 1024 (`cap_net_bind_service=ep` on entrypoint binary). Happen even when container never asked to bind privileged port. Check image before blaming it:

```bash
podman run --rm --entrypoint /bin/sh <REGISTRY>/<IMAGE>:<TAG> \
  -c 'getcap /usr/bin/<binary>'
```

Then add back only capability it name, with comment saying why:

```ini
DropCapability=ALL
# /usr/bin/<binary> carries cap_net_bind_service=ep; an empty bounding set
# makes exec fail with EPERM before the process starts.
AddCapability=NET_BIND_SERVICE
```

Note: diagnosis need `journalctl --user -u <SERVICE_NAME>`, not `podman logs` - container already removed by time failure visible.

## R10 - Structured logging

Prefer app own JSON logging option when it got one (example `LOG_FORMAT=json` in `.env`, per R3). Otherwise set `LogDriver=` explicitly, not left to Podman default.

✅ Correct
```ini
LogDriver=journald
```

❌ Incorrect
```ini
# LogDriver= left unset, relying on whatever Podman defaults to
```

Why: explicit driver make log routing stated fact of unit, not implicit default that can change across Podman versions.

## R11 - Absolute, canonical paths only

Every path in unit - `EnvironmentFile=`, `Volume=` sources, secret mount targets - absolute and canonical. No `~`, no Quadlet `%h` specifier, no relative paths.

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

Why: `~` and `%h` expanded by different layers (shell vs systemd specifier resolution) at different times. Relative paths depend on generator current working dir. Canonical absolute path unambiguous no matter who read unit.