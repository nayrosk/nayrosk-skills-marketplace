---
name: podman-quadlet-service
description: >
  Use when installing, deploying, self-hosting, or reworking a containerized
  service as a rootless Podman Quadlet systemd unit - "install X with podman",
  "deploy a container service", "create a quadlet", "run this only when my
  tool needs it", "MCP server backend container", "socket-activated
  container", "scheduled container job", "installer un service podman",
  "deployer un conteneur". Also use when an existing Quadlet service
  respawns in a loop, starts when nothing needs it, never stops, or ends
  every podman stop in SIGKILL / exit 137.
---

# Podman Quadlet Service

Install a containerized service as a rootless Podman Quadlet unit that is
**pinned, least-privilege, observable, and alive only when it should be**.
`references/conventions.md` (R1-R13) is the contract, and
`scripts/validate.sh` enforces it mechanically. Podman **5.0**+; preflight
checks the real version.

**Core principle:** a unit is correct when its *lifecycle*, its *stop
path* and its *privilege* were each decided on purpose and verified on the
host, not when it merely starts. Most broken units fail on one of those
three: always-on when it should be on-demand, SIGKILLed on every stop, or
relaxed "until it works" with no record of why.

## Workflow

0. **Preflight** - run `references/preflight.md` top to bottom. An
   **ABORT** stops everything. Only two host preconditions may be written
   here (unit directory **CREATE**, linger after an explicit **ASK** yes).
   No service artifact is written before the gate.

1. **Research** the image. Pick the newest maintained, rootless-capable,
   minimal variant. Read the upstream docs for ports, volumes, env, secrets,
   capabilities, and **how the app shuts down**. Resolve tag and digest with
   Podman alone (no extra tool may be assumed):
   `podman search --list-tags --limit 10000 <REG>/<IMG> --format '{{.Tag}}'
   | grep -E '^v?[0-9]+(\.[0-9]+){1,2}' | sort -V | tail -20`. Without
   `--limit`, only the first 25 tags come back (often the **oldest**), and
   `sort -V` alone ranks `edge`/`latest`/date tags above real versions.
   Then `podman manifest inspect <REG>/<IMG>:<TAG>` and take the
   digest whose `platform.architecture` matches `podman info --format
   '{{.Host.Arch}}'` (per-architecture digest: it is what `podman image
   inspect` reports after a pull). **Pull that digest now**: the
   inspections below need the image config and filesystem. A pull fills
   Podman's image store only and creates no service artifact, so it is
   allowed before the gate (step 4 re-verifies it). Then, for the pinned
   digest:
   - **Supply chain (R1):** `cosign verify` if upstream signs and cosign is
     present (`cosign tree <ref>` first: it shows whether any signature or
     attestation exists at all); `trivy`/`grype` scan if present. Scan an
     exported archive so no Podman socket is needed:
     `podman save -o <scratch>/img.tar <REF>@sha256:<DIGEST>` then
     `trivy image --input <scratch>/img.tar --cache-dir <scratch>/trivy
     --severity CRITICAL,HIGH` (or `grype docker-archive:<scratch>/img.tar`
     with `GRYPE_DB_CACHE_DIR=<scratch>/grype`). Keep every tool cache in
     scratch (`TUF_ROOT=` for cosign): they default to `$HOME`. Report
     results, or their absence, at the gate.
   - **PID 1 and stop path (R12):** `podman image inspect` the
     entrypoint/cmd/stop signal, and read how the app handles SIGTERM.
     - The process that receives SIGTERM must handle or forward it. A shell
       form (`sh -c ...`) or an entrypoint script that neither `exec`s the
       app nor `trap`s TERM and forwards it: `Exec=` override in exec form
       plus `RunInit=true`. A script that traps and forwards TERM (read it)
       is fine as is.
     - Every `$` meant for the shell inside the container (in `Exec=`,
       `HealthCmd=`) is written `$$`, and every literal `%` is written `%%`.
       systemd expands single ones first, to an empty string. Check the
       result with the generator's `-dryrun`.
     - Image already ships `tini`/`dumb-init`/`s6` as entrypoint: use the
       `# PID1:` marker, not `RunInit=true` (no stacked inits).
     - The app exits 0 on SIGTERM: nothing more. It dies from SIGTERM
       (143): `SuccessExitStatus=143`, except for a `job`, where 143 means an
       interrupted run and must stay a failure.
     - `StopTimeout=`: upstream's documented shutdown timeout plus a margin,
       or 30s when undocumented. Step 9 measures the real stop. If it uses
       more than half the budget, raise the budget and regenerate.
   - **Inspection runs** (`podman run --rm --entrypoint ...`) use the same
     `--userns=` as the unit; hosts defaulting to `userns=auto` otherwise
     fail with "not enough unused IDs".
   - **Hardening needs (R13):** start from the full baseline. Expect to
     relax nothing; relax only what you then prove necessary in step 8.
   - **Network placement:** `references/networking.md` (`public-noauth`,
     `public-auth`, `monitoring`, `loopback`, `internal`).

2. **Classify the lifecycle** with `references/lifecycle.md`: `daemon`,
   `on-demand`, `socket` or `job`. Who starts the work, and what ends it?
   Then run the profile-gated preflight checks.

> ### APPROVAL GATE - STOP HERE
> Present: image, tag, digest, why this version, signature and scan
> results (or "not available"), **lifecycle profile and why**, stop path
> (Exec override? RunInit? StopTimeout?), planned hardening exceptions
> (should normally be none yet), network placement, volumes, resource
> limits, and for `on-demand` every client config that will be repointed
> at the wrapper. **Write nothing to disk until the operator approves.**

3. **Create the local tree** - `$HOME/.<SERVICE_NAME>/` with `data/`,
   `config/`, `repo/` as needed, `docs/` always. Resolve paths with
   `realpath` (R11). Never write `~` or `%h` into a unit.

4. **Verify the pull** - `podman image inspect --format '{{.Digest}}'
   <REF>@sha256:<DIGEST>` matches the approved digest (pull it now if step
   1 did not).

5. **Generate** in a scratch directory, named exactly
   `<SERVICE_NAME>.container` (the validator derives the data tree from the
   basename): `references/templates/service.container`, keeping only the
   blocks for the chosen profile; `service.network` when the placement
   needs one; `.env` from `env.template`; and the profile's companions -
   `client-wrapper.sh` (on-demand), `socket-proxy.{socket,service}`
   (socket), `service.timer` (job). Every option must match the pulled
   version's own docs. Delete every line that does not apply; a leftover
   placeholder is a runtime failure.

6. **Validate** - `bash scripts/validate.sh <unit>`. Exit 0 prints
   `conformant`. Exit 1 prints `R<n>:`/`LINT:` lines: **go back to step 1**,
   fix the decision rather than patching the unit to silence the check, and
   pass the gate again with what changed. After 3 failed cycles, hand the
   decision to the operator. Exit 2 is a usage error, so fix the invocation
   and do not count it as a cycle.

7. **Secrets** - for each `Secret=` line, ask the operator for the value
   (never invent or infer it) and `podman secret create <name> -`.

8. **Install and start**
   - Copy units into `${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/`
     and the profile's companions into
     `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/` (wrapper:
     `$HOME/.local/bin/<SERVICE_NAME>-client`, mode 0755), then `systemctl --user daemon-reload`.
   - Write the reverse-proxy route for `public-*`/`monitoring`
     (`references/networking.md`).
   - Smoke-start it. `daemon`/`job`: `systemctl --user start
     <SERVICE_NAME>`. `on-demand`/`socket`: a bare `start` is stopped again
     within a second by `StopWhenUnneeded=yes`, which is a false failure.
     Hold it with a scope instead: `systemd-run --user --scope -p
     Wants=<SERVICE_NAME>.service -p After=<SERVICE_NAME>.service -- sleep
     600 &`, and kill that scope when done. `activating` for a few seconds is normal (`Type=notify`);
     `failed` or a rising restart counter is a crash loop, so read
     `journalctl --user -u <SERVICE_NAME>` (never `podman logs`: the
     container is already removed).
   - Poll the healthcheck at most 20 times, 5s apart.
   - **Hardening exceptions are earned here, never upfront:** if the app
     fails under the baseline, identify the one key responsible (toggle one
     at a time), relax only that key with a keyed
     `# HARDENING-EXCEPTION: <Key> - <evidence>` marker, re-validate, and
     report it back to the operator. `exec ...: Operation not permitted` is
     the file-capability case (conventions R9 note), not a broken image.
   - Then arm the profile: `daemon` - `systemctl --user enable`; `on-demand`
     - repoint each approved client config at the wrapper (back up each
     file first; a client config that does not exist yet is created only
     where and how the operator says), then release the hold scope; `socket` - stop the unit, `enable --now`
     the `.socket` only; `job` - `enable --now` the `.timer` only.

9. **Verify** - all of these, with output shown:
   - functional probe of the service, and through the proxy route if any;
   - the **R12 stop test** (`Result=success`, never `ExecMainStatus=137`);
   - the **lifecycle checks** from `references/lifecycle.md` Step 4 (e.g.
     on-demand: inactive, then active under a wrapper, then inactive after
     it exits, `NRestarts=0`).
   A step that was not run is reported as not run.

10. **Runbooks** - fill `references/templates/docs/*.md` into
    `$HOME/.<SERVICE_NAME>/docs/` with the values actually used, including
    profile, stop budget, every hardening exception with its evidence, and
    supply-chain results.

11. **Memory** - record service, pinned tag and digest, profile, install
    path, placement, exceptions, date.

## Red flags - stop and go back

| Thought | Reality |
|---|---|
| "`Restart=always` + `WantedBy=default.target` is the safe default" | Only for `daemon`. For a backend that only some tool uses, it costs RAM all day and respawns after every manual stop. Classify first (step 2). |
| "The image's CMD is fine as is" | A shell at PID 1 swallows SIGTERM, so every stop becomes SIGKILL/137. Inspect it (step 1). |
| "137 on stop is normal for containers" | It means data loss risk and a failed unit. R12 fails it; fix the stop path, never whitelist 137. |
| "Relax seccomp/caps/ReadOnly now so it starts, tighten later" | Later never comes. Start fully hardened and relax one tested key at a time with a marker (step 8). |
| "Tag pinning is enough" | Tags are re-pushable. R1 requires the digest. |
| "It started, so it works" | Not verified until the stop test and lifecycle checks pass (step 9). |
| "One client can call the binary directly, it's simpler" | That client neither starts nor holds the on-demand container. Every client goes through the wrapper. |

## Hard rules

- Never overwrite an existing service tree, unit, or client config without
  asking. Back up any client config before repointing it.
- Nothing is written before the approval gate.
- Never invent a secret value or write one to `.env` or a unit.
- Never install past a `validate.sh` exit-1. Never edit a unit only to
  silence a check.
- Never hardcode a path: derive it from `$HOME`/`$XDG_CONFIG_HOME` and
  resolve it with `realpath`.
- All generated files, comments and docs are in English.

## Conformance

`scripts/validate.sh` checks R1-R13 and runs the Quadlet generator as a
linter. Two things need human judgement it cannot make: R10 (prefer the
app's own JSON log format) and whether each `HARDENING-EXCEPTION` reason is
real evidence. The validator only checks that one exists. Run
`bash tests/run.sh` after changing the validator.
