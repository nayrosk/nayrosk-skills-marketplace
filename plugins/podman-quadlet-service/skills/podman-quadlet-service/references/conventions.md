# Conventions

Fourteen conventions. Every Quadlet unit from this skill must follow. Each rule got stable ID (`R1`..`R14`). `scripts/validate.sh` use ID as violation prefix (e.g. `R1: ...`). Conformance checklist in `SKILL.md` use too. IDs never renumbered, merged, reused.

Examples below use `%HOME%` as stand-in for user home dir: `%HOME%` mean value of `$HOME`, resolved to absolute path at generation time. Quadlet own `%h` specifier deliberately **not** used anywhere in generated units - R11 forbid it, plus `~` and any other relative or unresolved path form.

### Home-directory notation: three spellings, one meaning

Repo use different token for home dir in each kind of file. All mean same thing - absolute value of `$HOME` - but only one ever substituted:

| Spelling | Where it appears | What to do with it |
|---|---|---|
| `%HOME%` | this document examples, only | **Doc notation.** Never write into file. Exist so example path read like path. Not placeholder to substitute, not systemd specifier. |
| `<HOME>` | `references/templates/` | **Real placeholder.** Substitute with resolved absolute home dir when generating unit, `.env`, or runbook. |
| `$HOME` | `SKILL.md`, `references/preflight.md`, runbook shell snippets | **Shell variable**, in text meant for shell to run, where shell expand it. |

One mistake to avoid: write `%HOME%` into generated unit. Not systemd specifier, so systemd not expand - Quadlet pass literal string `%HOME%/...` through as path, mount fail. `%`-delimited form look like `%h`, which R11 forbid for own reasons; `%HOME%` not that either. When generating from template, token to find and replace is `<HOME>`.

## R1 - Pinned image, by tag AND digest

`Image=` carries a human-readable tag **and** the manifest digest:
`<registry>/<image>:<tag>@sha256:<digest>`. The tag tells a reader what
version runs. The digest is what Podman actually resolves, and it cannot be
re-pointed upstream.

✅ Correct
```ini
Image=docker.io/library/postgres:16.4@sha256:0f7a...c21
```

❌ Incorrect
```ini
Image=docker.io/library/postgres:16.4        # tag only: mutable, can be re-pushed
Image=docker.io/library/postgres:latest
Image=docker.io/library/postgres
Image=ghcr.io/example/app@sha256:0f7a...c21  # digest only: unreadable in review
```

Why: tags are mutable pointers. A compromised or careless upstream push to
an existing tag changes what runs on the next pull, and `Pull=missing` (R6)
only delays that to the next image prune. The digest makes the unit state
exactly which bytes run, and the tag keeps it reviewable.

Supply-chain checks at research time (workflow step 1) build on this
pin. They are not linted, because the tools are optional:
- **Signature**: if upstream publishes sigstore/cosign signatures and
  `cosign` is present, run `cosign verify` against the digest with the
  identity upstream documents. A failed verification is a gate blocker. If
  there is no signature, say so at the gate rather than staying silent.
- **Vulnerabilities**: if `trivy` or `grype` is present, scan the pinned
  digest and report CRITICAL/HIGH counts at the gate, with fixed-in
  versions. The operator decides, and the decision goes in `install.md`.

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

Profile-dependent healthcheck keys (`references/lifecycle.md`), when a
`HealthCmd=` exists:

| Profile | Required | Why |
|---|---|---|
| `daemon` | `HealthOnFailure=kill` | a healthcheck nobody acts on only changes a status string; `kill` hands the wedged container to `Restart=always` |
| `on-demand`, `socket` | `Notify=healthy` | the unit counts as "started" only once healthy, so consumers ordered `After=` it never hit a cold port |

The `job` profile normally has no healthcheck: use the marker
`# NO-HEALTHCHECK: job - <what proves success>`.

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

## R7 - Lifecycle profile and matching restart policy

Unit declares exactly one lifecycle profile on a comment line, and its
`[Unit]`/`[Service]`/`[Install]` match that profile. Full decision guide:
`references/lifecycle.md`.

```ini
# LIFECYCLE: daemon | on-demand | socket | job
```

| Profile | `[Service] Restart=` | `RestartSec=` | `[Unit] StopWhenUnneeded=yes` | `[Install]` |
|---|---|---|---|---|
| `daemon` | `always` | required | forbidden | `WantedBy=default.target` required |
| `on-demand` | `on-failure` | required | required | forbidden |
| `socket` | `on-failure` | required | required | forbidden |
| `job` | `no` or `on-failure` | if `on-failure` | forbidden | forbidden (the `.timer` is enabled) |

✅ Correct (on-demand)
```ini
# LIFECYCLE: on-demand
[Unit]
StopWhenUnneeded=yes
[Service]
Restart=on-failure
RestartSec=10
```

❌ Incorrect - on-demand backend shaped like a daemon
```ini
[Service]
Restart=always
[Install]
WantedBy=default.target
```

Why: `Restart=always` on an on-demand backend turns every stop that is not
issued through systemd (a `podman stop`, an OOM kill, a SIGKILL after a
missed stop timeout) into a respawn, and `WantedBy=default.target` starts
it at every login whether anything needs it or not. Conversely,
`StopWhenUnneeded=yes` on a daemon stops it the moment nothing depends on
it, which is immediately. The profile is declared explicitly so a reviewer
and the linter both know which shape is intended.

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

### External mounts (cross-service, operator-chosen destinations)

A service sometimes has a legitimate need for a path outside its own tree,
typically a `job` backing up another service or writing to a folder the
operator chose. That is allowed only behind a marker naming the **exact**
host path, one marker per path:

```ini
# EXTERNAL-MOUNT: %HOME%/.uptime-kuma/data - nightly backup source
Volume=%HOME%/.uptime-kuma/data:/src:ro,z
# EXTERNAL-MOUNT: %HOME%/backups - backup destination chosen by the operator
Volume=%HOME%/backups:/dst:Z
```

Hard limits that no marker lifts (`scripts/validate.sh` enforces them):

- the path stays under `%HOME%`, and is never `%HOME%` itself;
- never a credential or client-config store: `.ssh`, `.gnupg`, `.config`,
  `.local`, `.password-store`, `.kube`, `.aws`, `.docker`, `.claude`;
- another service's tree (any other `%HOME%/.<name>/...`) is mounted
  read-only (`:ro`, or `ro`/`readonly` in `Mount=`);
- `--volumes-from` in `PodmanArgs=` is rejected like `-v`: it imports
  every mount of another container wholesale and bypasses all of the above.

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

### Sizing: every limit has a source

Validator only check limits exist; value is a decision. Take it from the image needs profile (`SKILL.md` step 1), in this order: upstream Helm chart `resources.limits` (or `requests` with margin), then upstream docs, then the template values (`512m` / `256` / `1.0`) labelled `guess` at the gate. Never present a guess as a fact.

Step 9 measure it: peak memory and PIDs from `podman stats` during the functional probe. Peak above 80% or below 20% of a limit: propose a new value, operator approve, write measurement and before/after values in `docs/install.md`. One-shot probe is not load: runbook say so.

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

Common for web servers built to bind ports below 1024 (`cap_net_bind_service=ep` on entrypoint binary). Happen even when container never asked to bind privileged port. Not the same problem as the host refusing a port below 1024 to rootless Podman (`net.ipv4.ip_unprivileged_port_start`, see `references/networking.md` "Privileged ports"); both can apply at once. Check image before blaming it (workflow step 1 profile already run `getcap` from host on mounted image; command below for when it did not):

```bash
# same --userns= as the unit (hosts defaulting to userns=auto may otherwise
# fail with "not enough unused IDs"); scan the whole image, not just the
# entrypoint:
podman run --rm --userns=keep-id --entrypoint /bin/sh <REGISTRY>/<IMAGE>@sha256:<DIGEST> \
  -c 'getcap -r / 2>/dev/null || echo "no getcap in image"'
```

Capabilities on **helper** binaries fail differently: the container runs,
but one feature breaks silently (e.g. `/usr/bin/ping` with `cap_net_raw=ep`
behind an "ICMP monitor" option). List them at the gate as "feature X
needs capability Y". Add the capability only if the operator needs that
feature, behind a marker, and only after testing.

Then add back only capability it name, with comment saying why:

```ini
DropCapability=ALL
# HARDENING-EXCEPTION: AddCapability - /usr/bin/<binary> carries
# cap_net_bind_service=ep; an empty bounding set makes exec fail with EPERM.
AddCapability=NET_BIND_SERVICE
```

R13 requires the `# HARDENING-EXCEPTION: AddCapability` marker.

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

## R12 - Graceful, observable stop

A stop issued by systemd must reach the application as SIGTERM, finish
within a stated budget, and end with `Result=success`. A container that is
always SIGKILLed loses in-flight writes, leaves lock files behind, and
reports exit 137, which `Restart=` policies count as a failure.

Required:

- `StopTimeout=<seconds>` in `[Container]`: the grace period podman gives
  between the stop signal and SIGKILL. Size it from the application's real
  shutdown time, measured, not guessed.
- `TimeoutStopSec=` in `[Service]`, **strictly greater** than
  `StopTimeout=` (the Podman man page says why: otherwise systemd kills
  `podman rm` itself mid-stop). Rule of thumb: `StopTimeout + 15`.
- `RunInit=true`, **or** a marker justifying why PID 1 already handles
  signals: `# PID1: <entrypoint> - <why it forwards SIGTERM and reaps>`
  (e.g. the image already ships `tini`, `dumb-init` or `s6-overlay` as
  entrypoint).
- `SuccessExitStatus=` may list `143` (SIGTERM) for applications that have
  no SIGTERM handler and die from the default action. It **never** lists
  `137`/`SIGKILL`/`KILL`: that would hide the exact failure this rule exists
  to catch.

✅ Correct
```ini
[Container]
Exec=node --max-old-space-size=256 server.js   # exec form: no sh in front
RunInit=true
StopTimeout=30
[Service]
TimeoutStopSec=45
```

❌ Incorrect
```ini
[Container]
# image CMD is `sh -c "node server.js"`, left as is, no RunInit
[Service]
SuccessExitStatus=137
```

Why: the kernel ignores every signal for which PID 1 of a PID namespace has
not installed a handler. Images whose `CMD`/`ENTRYPOINT` is a shell form
(`sh -c ...`) put a shell at PID 1 that neither handles nor forwards
SIGTERM, so `podman stop` always waits out the timeout and SIGKILLs. Check
at research time:

```bash
podman image inspect <IMAGE>@sha256:<DIGEST> \
  --format 'entrypoint={{json .Config.Entrypoint}} cmd={{json .Config.Cmd}} stopsignal={{.Config.StopSignal}}'
```

If the effective command starts with `sh -c`/`bash -c` (also via an
entrypoint script that does not `exec "$@"`), override it with `Exec=` in
exec form. Shell expansion is gone then, so copy expanded values from
`.env` and comment the duplication. Add `RunInit=true`: catatonit becomes
PID 1, forwards SIGTERM, and reaps orphaned grandchildren (browsers,
workers).

**Mandatory stop test** (workflow step 9), from a running, healthy unit.
For `on-demand`/`socket`, hold it up first with the scope from
`references/lifecycle.md`, because a bare `start` is stopped again at once:

```bash
systemctl --user stop <SERVICE_NAME>
systemctl --user show <SERVICE_NAME> -p Result,ExecMainStatus
# PASS: Result=success. FAIL: ExecMainStatus=137, or Result=timeout.
journalctl --user -u <SERVICE_NAME> -n 30 --no-pager   # time from "Stopping" to "Stopped"
```

## R13 - Hardened by default, every relaxation justified and tested

The unit keeps the hardening baseline below. Any relaxation is allowed
only with a marker comment naming the exact key, written after the
relaxation was **tested** to be necessary (state what failed without it):

```ini
# HARDENING-EXCEPTION: <Key> - <what broke without it, how it was tested>
```

| Baseline | Relaxation that needs a marker |
|---|---|
| `NoNewPrivileges=true` | absent or `false` → marker `NoNewPrivileges` |
| `DropCapability=ALL` | absent → marker `DropCapability`; any `AddCapability=` → marker `AddCapability` |
| `ReadOnly=true` | absent or `false` → marker `ReadOnly` |
| default seccomp | `SeccompProfile=unconfined` → marker `SeccompProfile` |
| SELinux labels on | `SecurityLabelDisable=true` → marker `SecurityLabelDisable` |
| no privilege flags | `--privileged`, `--cap-add`, `--security-opt` in `PodmanArgs=` are rejected outright, with or without a marker: use the native keys so the marker rule can see them |

✅ Correct
```ini
NoNewPrivileges=true
DropCapability=ALL
# HARDENING-EXCEPTION: ReadOnly - Firefox writes /etc, /root and /var/cache/fontconfig
# at startup; tested 2026-11-10, times out without them.
Tmpfs=/tmp:rw,size=256m,noexec,nosuid,nodev
```

❌ Incorrect
```ini
SeccompProfile=unconfined      # no marker: nobody can tell if this is still needed
PodmanArgs=--privileged
```

With `ReadOnly=true`, give the app writable scratch through
`Tmpfs=<path>:rw,size=<n>,noexec,nosuid,nodev` (size-bounded, no exec)
rather than relaxing `ReadOnly`.

Why: every relaxation widens the blast radius of an application compromise.
A marker turns a silent default into a reviewed decision that names its
evidence, so a later image bump can re-test it and drop the exception. The
marker must name the key, so one generic comment cannot cover several
relaxations.

## R14 - No outbound network unless justified

Unit get no outbound access by default. Conformant when **every** `Network=` is `none` or sibling `<x>.network` Quadlet unit whose last `[Network]` `Internal=` is true (`true`/`yes`/`1`/`on`), or when unit carry marker with non-empty reason:

```ini
# EGRESS: <what the app reaches outside, and the evidence>
```

`:options` after network name ignored (`Network=x.network:ip=...` judged by `x.network`). Sibling read with its drop-ins (`<x>.network.d/*.conf`, name order, last value win). `NetworkName=podman` never internal: Quadlet create network with `--ignore`, so existing name reused as is (other name clashes = runtime state, checked at step 9 with `podman network inspect`). `Pod=<x>.pod`: container live in pod's netns, so pod's own `[Pod]` `Network=` values judged same way (pod not sibling, or no `Network=` = egress). Network never set through `PodmanArgs=--network`/`--net`/`--pod`: rejected, marker or not.

✅ Correct
```ini
Network=<SERVICE_NAME>.network   # sibling unit has Internal=true
```
```ini
Network=none
```
```ini
# EGRESS: Caddy obtains certificates from Let's Encrypt (ACME)
Network=caddy.network
```

❌ Incorrect
```ini
# no Network= at all: rootless default network has egress
Network=podman                   # no marker
Network=host                     # no marker
Network=proxy.network            # not a sibling file: Internal= unknown, needs marker
# EGRESS:
PodmanArgs=--cpus=1.0 --network=host
```

All-or-nothing: `Internal=true` cut internet, LAN **and** host. Service that only need NAS or LAN database get full egress via marker. Narrower scope (LAN-only, allow list) need host firewall changes, out of scope.

Egress earned like hardening exception: decide from image needs profile (ACME, webhooks, plugin/model downloads, external APIs, telemetry); nothing found = no egress; app fail at step 8 because of it = show evidence, add marker, re-validate, report.

Why: compromised service with no route out cannot exfiltrate data, pull second stage, or join botnet. Most self-hosted backends (databases, caches, internal APIs) never need internet. Marker turn silent default into reviewed decision, same as R13.
