# podman-quadlet-service v3: image needs profile and default-deny egress

Date: 2026-11-11
Plugin: `plugins/podman-quadlet-service` (currently v2.0.0)

## Intent

The skill today knows *how* to write a hardened Quadlet unit, but it does
not work out *what a given image needs*. It tells the agent to "read the
upstream docs" and leaves the rest to luck. Two concrete gaps came out of
the discussion:

- A Caddy-like image needs to listen on host ports 80/443. Rootless Podman
  cannot do that unless the host's `net.ipv4.ip_unprivileged_port_start`
  allows it. The skill only covers the narrower file-capability case
  (`cap_net_bind_service=ep` on the binary, R9 note / R13 exception) and
  never detects or explains the sysctl problem.
- R9 forces `Memory=`, `PidsLimit=` and `--cpus=` to exist, but nothing
  says how to size them. The template value (`512m / 256 / 1.0`) ends up
  copied regardless of whether the image is Postgres or a tiny MCP server.

The operator wants the skill to **adapt to the image generically**: inspect
any image and research it online, rather than maintain a catalogue of
per-image recipes. They also chose to add **default-deny outbound network
access** as a security improvement.

## Goals

1. A new **image needs profile** produced in workflow step 1, from local
   inspection plus web research, presented at the approval gate with the
   source of every claim.
2. **Privileged port handling**: detect when a host port below the host's
   unprivileged-port threshold is wanted and stop to ask the operator,
   offering the alternatives.
3. **Resource sizing**: initial limits come from research, then are checked
   against a real measurement during verification.
4. **Default-deny egress**: every service sits on its own `Internal=true`
   network unless it carries a justified `# EGRESS:` marker. Enforced by a
   new validator rule **R14**.

## Non-goals

- No per-image recipe catalogue (Caddy, Postgres, ...). Detection stays
  generic.
- No audit/migration of services already installed with v2. (Offered and
  not chosen.)
- No update-watch timer. (Offered and not chosen.)
- The skill never changes host-wide settings on its own (sysctl, firewall).

## Anti-goals (would be a failure even if it "works")

- Applying `sysctl` or firewall changes without an explicit operator yes.
- Granting egress "to make it start" without a recorded reason, i.e. the
  same failure mode R13 already forbids for hardening.
- Presenting guessed values (limits, ports, egress need) as facts: every
  line of the profile names its source.
- Making the Caddy migration silent: editing an existing proxy unit or
  restarting it without asking.

## Constraints (existing contract, unchanged)

- Podman 5.0+, rootless, systemd user units, nothing written before the
  approval gate, all generated files in English, never hardcode paths.
- Rule IDs are never renumbered or reused: the new rule is R14.
- `scripts/validate.sh` stays Podman/bash-only; no new hard dependencies.
  Tests live in `tests/run.sh` with `tests/fixtures/`.

## Design

### 1. Image needs profile (workflow step 1)

After the digest is pulled (already allowed before the gate), the agent
builds a profile from two sources.

**Local inspection** (no assumption that the image contains any tool):

- `podman image inspect` on the pinned digest: `Config.ExposedPorts`,
  `Config.User`, `Config.Volumes`, `Entrypoint`/`Cmd`, `StopSignal`,
  `Env` (hint names only, never values to copy), OCI labels
  (`org.opencontainers.image.source`, `.documentation`, `.url`) used as
  research starting points.
- File capabilities: `podman unshare` + `podman image mount <digest>`,
  then the **host's** `getcap -r <mountpoint>` (then `podman image
  unmount`). This replaces relying on `getcap` inside the image. If the
  host has no `getcap`, report "not checked" at the gate.
- Derived facts: runs as root in-image or not; which ports are below 1024;
  which paths are declared volumes.

**Web research**: upstream docs, the project's `compose.yaml`/
`docker-compose.yml`, and the official or most-used Helm chart. Look for:
ports, required writable paths, outbound needs (ACME, webhooks, plugin or
model downloads, external APIs, telemetry), shutdown behaviour, and
recommended resources (Helm `resources.requests/limits` are a preferred
sizing source).

**Output**: a table shown at the approval gate, one row per need (ports,
privileged ports, user/UID, volumes, capabilities, egress, memory, CPU,
PIDs, stop path), with columns *value* and *source* (`inspect`,
`docs <url>`, `compose <url>`, `helm <url>`, or `guess`). The gate list in
`SKILL.md` gains this profile. The profile is also written into
`docs/install.md` of the installed service.

### 2. Privileged ports

When the chosen placement needs a host port P (from `PublishPort=` or
`Network=host`) and `sysctl -n net.ipv4.ip_unprivileged_port_start` is
greater than P, the agent stops (ASK) and offers:

1. Lower the sysctl: needs root, host-wide, made persistent in
   `/etc/sysctl.d/`. The skill prints the exact commands for the operator
   to run; it does not run them.
2. Publish on a high port (e.g. 8443) and redirect with the host firewall
   (operator-run, commands printed).
3. Stay `loopback` behind no public port.

Note in the docs: `Network=host` under rootless is subject to the same
sysctl. This is distinct from the existing file-capability case (binary
carrying `cap_net_bind_service=ep`), which keeps its current R13
`AddCapability=NET_BIND_SERVICE` exception path; the profile's `getcap`
output decides which case applies, and both can apply at once.

This is a profile-gated check added to `references/preflight.md` (runs
after placement is known, before the gate).

### 3. Resource sizing

- Initial values: from the research source (Helm defaults, upstream
  recommendation), otherwise a guess labelled as such. Template defaults
  remain only as a last resort and are labelled `guess`.
- Verification (step 9) adds a measurement: sample `podman stats
  --no-stream` for the container during the functional probe and record
  peak memory and PIDs.
- *Builder's call (mine):* propose an adjustment when peak memory exceeds
  80% of `Memory=`, or is under 20% of it; same for PIDs. The operator
  approves any change; the new values and the measurement go in
  `docs/install.md`. A one-shot probe does not represent load, so the
  runbook says so.
- The cgroups v1 warning in preflight stays as is.

### 4. Default-deny egress (new rule R14)

**Rule**: a `.container` unit must have no outbound internet access unless
justified. Conformant when either:

- every `Network=` it uses is a `<name>.network` Quadlet unit with
  `Internal=true` (or `Network=none`), or
- it carries `# EGRESS: <reason>` with a non-empty reason, in the same
  style as the R13 `HARDENING-EXCEPTION` marker.

A unit with no `Network=` at all (default rootless network, which has
egress) and no marker violates R14.

**Validator**: `validate.sh` already resolves sibling `.network` files for
its linter pass; R14 reads each referenced sibling `.network` and checks
for `Internal=true`. A referenced network that is not a sibling file (an
external network created elsewhere, e.g. an existing proxy network)
counts as **not internal** unless the marker is present. New fixtures:
pass (internal network, `Network=none`, marker with reason) and violation
(no network, non-internal network, marker without reason, missing sibling).
Existing fixtures that now fail R14 get updated so they keep testing what
they were testing.

**Template**: `service.network` gains `Internal=true` by default, with a
comment that removing it requires the `# EGRESS:` marker on the container.

**Decision source**: the profile's egress row. No evidence of an outbound
need means no egress. If the app then fails during step 8 because of it,
egress is earned the same way as a hardening exception: show the evidence,
add the marker, re-validate, report.

**Reverse proxy (inverted topology)**: today backends "join the reverse
proxy network". Since the proxy itself needs egress (ACME), that would
leak egress to every backend. New rule in `references/networking.md`: each
backend has its own internal network, and **the proxy joins the backend's
network** (one more `Network=` line in the proxy's unit). The proxy unit
keeps its own `# EGRESS:` marker. Editing and restarting the proxy unit is
an ASK step (back up the unit first), done at install step 8.

**Proxy not managed as a Quadlet unit** (decided by the operator): when
the detected proxy was started by `podman run`, compose, by hand, or is
otherwise not a Quadlet unit, its networks cannot be edited. Fallback:
the backend joins the proxy's network as in v2 and carries
`# EGRESS: proxy not Quadlet-managed`; the skill then offers to reinstall
the proxy with this skill. It never edits or restarts a non-Quadlet proxy.

**Proxy installed by v2** (decided by the operator): the skill adds only
the backend's `Network=` line and the proxy's own `# EGRESS:` marker,
after an ASK and a backup. It runs `validate.sh` on the proxy unit and
*reports* any other v2-to-v3 gap without fixing it (consistent with the
no-migration non-goal).

**Uninstall**: `uninstall.md` gains a step, before removing the backend's
network: remove the backend's `Network=` line from the proxy unit (ASK,
backup), `daemon-reload`, restart the proxy. Otherwise the proxy fails on
its next start.

**Egress scope is all-or-nothing in v3** (decided by the operator).
`Internal=true` also cuts the LAN and the host. A service that only needs
a NAS or a LAN database gets full egress via the marker. The docs and the
red-flags table say this explicitly. Narrower scopes (LAN-only, allow
lists) are out of scope: they need host firewall changes.

**Loopback and socket profiles (verified)**: on this host (rootless
Podman 6.1.4, netavark, pasta), a container on a `--internal` network
with `-p 127.0.0.1:18765:8000` answered HTTP 200 from the host, while
outbound `wget http://1.1.1.1` from inside failed with
`Network is unreachable`. So `loopback` = internal network plus
`PublishPort=127.0.0.1:...`, and the `socket` profile's proxyd reaches the
backend the same way. No relay needed. Not verified on Podman 5.x: record
the tested version in `networking.md`. *My call:* if the step 9 probe
shows the loopback port unreachable on a host, the fallback is the
`# EGRESS:` marker with reason "loopback publish unsupported on Podman
<version>", reported to the operator.

### Versioning

R14 rejects units that v2 accepted, so this is a breaking change:
plugin version **3.0.0** (*my call*), README and `plugin.json` description
updated, conventions header says "Fourteen conventions".

## Files expected to change

- `skills/podman-quadlet-service/SKILL.md`: step 1 profile, gate list,
  step 8 egress earning and proxy edit, step 9 resource measurement, red
  flags rows for egress and guessed limits, hard rule about host-wide
  changes.
- `references/conventions.md`: R14; R9 sizing guidance; cross-reference
  from R13 file-capability note to the privileged-port section.
- `references/networking.md`: inverted proxy topology, privileged ports,
  loopback/internal finding.
- `references/preflight.md`: privileged-port profile-gated check, `getcap`
  availability INFO.
- `references/templates/service.network`, `service.container`,
  `docs/install.md`.
- `scripts/validate.sh`, `tests/run.sh`, `tests/fixtures/*`.
- `README.md`, `.claude-plugin/plugin.json`, marketplace manifest if it
  carries the version.

## Left to the builder

- Exact wording and layout of the profile table.
- How R14's marker parsing is implemented, provided it matches R13's
  marker conventions.
- Fixture names and how existing fixtures are adapted.
- The loopback/internal verification and the fallback choice, with
  evidence recorded.
