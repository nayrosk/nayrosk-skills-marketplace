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

- **Network placement**: `<NETWORK>` - <which of the four exposure decisions
  from `references/networking.md` applies (`public-noauth`, `public-auth`,
  `monitoring`, `internal`), and why>.
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
- **Capabilities**: `NoNewPrivileges=true`, `DropCapability=ALL`,
  `ReadOnly=true` by default - <any capability re-added, and why the
  service cannot run without it; leave as "none" if the defaults held>.
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
systemctl --user is-active <SERVICE_NAME>
podman healthcheck run <SERVICE_NAME>
podman inspect <SERVICE_NAME> --format '{{.Config.Image}} {{.State.Health.Status}}'
```

Expected: `active`, then the healthcheck exits 0, then the inspect line
shows the pinned image and `healthy`. If exposed through a reverse proxy,
also record the command used to confirm reachability through
`<SERVICE_FQDN>` and its result.
