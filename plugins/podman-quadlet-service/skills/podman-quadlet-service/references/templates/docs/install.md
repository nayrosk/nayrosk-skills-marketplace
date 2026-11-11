# <SERVICE_NAME> - Install

This document is generated once, at install time, and is filled in with the
values actually used for this install - not left as placeholders. It is the
permanent record of what was installed and why, for whoever operates this
service next (including a future you).

## Purpose

<one paragraph: what <SERVICE_NAME> is, and a link to its upstream project
or documentation>

## Image

| | |
|---|---|
| Registry | `<REGISTRY>` |
| Image | `<IMAGE>` |
| Tag | `<TAG>` |
| Digest | `sha256:<DIGEST>` |
| Pull policy | `Pull=missing` (R6) - upgrades are deliberate, see `update.md` |

Why this version: <the reason this tag/digest was chosen over other
available versions - e.g. latest stable at install time, a specific fix it
carries, or a compatibility constraint>

## Local tree

```
<HOME>/.<SERVICE_NAME>/
├── .env            # non-secret configuration, see env.template (R3)
├── data/            # persistent state, bind-mounted at <CONTAINER_DATA_PATH> (R8)
├── config/          # read-only configuration, bind-mounted at <CONTAINER_CONFIG_PATH> (R8)
├── repo/            # present only if this service is built from a checked-out repo
└── docs/            # this file and its siblings
```

## Configuration decisions

- **Network placement**: `<NETWORK>` - <which of the five exposure decisions
  from `references/networking.md` applies (`public-noauth`, `public-auth`,
  `monitoring`, `loopback`, `internal`), and why>.
  - If published on loopback: `PublishPort=127.0.0.1:<PORT>:<CONTAINER_PORT>`.
  - If routed through a reverse proxy: public hostname `<SERVICE_FQDN>`,
    container port `<CONTAINER_PORT>`.
  - If behind basic auth: username `<USERNAME>`, credential stored as a
    podman secret, never in this file or in the Caddyfile in plaintext.
- **Rootless user mapping**: `UserNS=keep-id:uid=<CONTAINER_UID>,gid=<CONTAINER_GID>`
  (R2) - <why this UID/GID, if not simply the invoking user's own>.
- **Resource limits** (R9): `Memory=<MEM_LIMIT>`, `PidsLimit=<PIDS_LIMIT>`,
  `PodmanArgs=--cpus=<CPU_LIMIT>` - <how these numbers were sized: upstream
  recommendation, observed usage, host headroom>.
- **Healthcheck** (R5): `HealthCmd=<HEALTH_COMMAND>` - <why this command
  proves the service is actually serving, not just running>.
  - If no healthcheck was possible (distroless image, no shell): record the
    `# NO-HEALTHCHECK:` justification exactly as it appears in the unit,
    and repeat the reason here.
- **Lifecycle** (R7): `<PROFILE>` (`daemon`, `on-demand`, `socket` or
  `job`, see `references/lifecycle.md`) - <why this profile>.
  - on-demand: wrapper `<HOME>/.local/bin/<SERVICE_NAME>-client` (or the
    name chosen), and every client config repointed at it (file path, and
    the backup made before editing it).
  - socket: public `127.0.0.1:<PUBLIC_PORT>`, backend
    `127.0.0.1:<BACKEND_PORT>`, idle timeout `<IDLE_TIMEOUT>`, measured
    cold start.
  - job: `OnCalendar=<ON_CALENDAR>`, and what counts as success.
- **Stop path** (R12): PID 1 is <catatonit via `RunInit=true` / the image's
  own init>, `Exec=` override <yes - why / no>, `StopTimeout=<STOP_TIMEOUT>`,
  `TimeoutStopSec=<TIMEOUT_STOP_SEC>`, measured stop time <N>s, and the stop
  test result (`Result=success`).
- **Hardening** (R13): baseline `NoNewPrivileges=true`, `DropCapability=ALL`,
  `ReadOnly=true`, default seccomp. Exceptions: <one line per
  `HARDENING-EXCEPTION` marker - key, what failed without it, how it was
  tested, date; "none" if the baseline held>. Re-test each exception at
  every image update and drop it once it is no longer needed.
- **Supply chain** (R1): signature <verified with cosign (identity) / not
  published / cosign not available>; scan <tool, CRITICAL/HIGH counts,
  operator decision / no scanner available>.
- **Secrets** (R4): `Secret=<SECRET_NAME>,type=env,target=<VAR_NAME>` -
  <what this secret is, without its value>.

## Install commands run

```bash
# Exact commands executed for this install, in order - preflight output,
# image pull, unit and .env generation, daemon-reload, start. Paste the
# real transcript here, not a description of it.
```

## Verifying health

```bash
# daemon / job: query the unit directly. on-demand / socket: the unit is
# normally inactive - hold it up first, in another shell:
#   systemd-run --user --scope -p Wants=<SERVICE_NAME>.service \
#     -p After=<SERVICE_NAME>.service -- sleep 600
systemctl --user is-active <SERVICE_NAME>
podman healthcheck run <SERVICE_NAME>
podman inspect <SERVICE_NAME> --format '{{.Config.Image}} {{.State.Health.Status}}'
```

Expected: `active`, then the healthcheck exits 0, then the inspect line
shows the pinned image and `healthy`. If exposed through a reverse proxy,
also record the command used to confirm reachability through
`<SERVICE_FQDN>` and its result.
