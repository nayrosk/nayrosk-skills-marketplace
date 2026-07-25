---
name: podman-quadlet-service
description: >
  Use when installing, deploying, or self-hosting a containerized service with
  Podman as a systemd Quadlet unit - including "install X with podman", "deploy
  a container service", "set up a rootless container", "create a quadlet",
  "installer un service podman", "deployer un conteneur". Enforces conventions:
  pinned image versions, podman secrets, healthchecks, bind mounts, resource
  limits, reverse proxy routing, and generated runbooks.
---

# Podman Quadlet Service Installation

Installs a containerized service as a rootless Podman Quadlet unit, enforcing
the conventions in `references/conventions.md` (R1-R11) end to end: pinned
image, no inline secrets, healthcheck, bind-mounted state, resource limits,
and a generated runbook. Requires Podman **5.0** or newer; preflight verifies
the actual installed version rather than assuming one.

## Workflow

0. **Preflight** - run every check in `references/preflight.md`, in order.
   A failed **ABORT** check stops the workflow here, naming the check.
   Nothing is written to disk in this step.
1. **Research** - find the newest version matching: rootless-capable,
   distroless or minimal, actively maintained. Read upstream docs for
   required capabilities, volumes, ports, environment variables and
   secrets. Resolve the exact tag and its digest. Decide network placement
   using `references/networking.md` (`public-noauth`, `public-auth`,
   `monitoring`, or `internal`).

> ### APPROVAL GATE - STOP HERE
> Present to the user: image, tag, digest, why this version, required
> capabilities, network placement, planned volumes, planned resource
> limits. **Write nothing to disk until the user approves.** No directory,
> template, secret, or unit file is created before this gate is passed.

2. **Create the local tree** - `$HOME/.<SERVICE_NAME>/` with `.env`, plus
   `data/`, `config/`, `repo/`, `docs/` as applicable. Resolve every path
   with `realpath` (R11); never write `~` or `%h` into a unit.
3. **Pull the image** by digest; verify the digest matches what was
   approved.
4. **Generate configuration** - copy `references/templates/service.container`
   (and `references/templates/service.network` when the placement is
   `internal`), substitute the placeholders, and write `.env` from
   `references/templates/env.template`. Options must match the pulled
   version's own docs, not assumption.
4b. **Validate** - run `scripts/validate.sh <unit>`. It exits 0 and prints
   `conformant` when clean; otherwise it exits 1 and prints one or more
   `R<n>:` and/or `LINT:` lines. **On any failure, return to step 1**: a
   violation means the chosen image or version does not fit the
   conventions, so redo the research rather than patching the unit
   in place. The revised proposal passes the approval gate again, stating
   which check failed and what changed. After 3 failed research -> validate
   cycles, stop and hand the decision to the user instead of cycling again.
5. **Install** - place the unit(s) in
   `${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/` (locate the
   Quadlet generator with `scripts/find-quadlet.sh`, never a literal path),
   then `systemctl --user daemon-reload`.
6. **Enable** - `systemctl --user start <SERVICE_NAME>` and confirm it is
   active.
7. **Monitor the healthcheck** - poll at most 20 times, 5s apart (`podman
   healthcheck run` checks immediately and does not wait out
   `HealthStartPeriod=` on its own). On timeout, fail loudly with `podman
   logs` output and offer the rollback in the generated `docs/uninstall.md`.
8. **Test** - a functional probe appropriate to the service, plus
   reachability through the reverse proxy route when one was configured.
9. **Write the runbooks** - copy `references/templates/docs/*.md`
   (`install.md`, `update.md`, `rotate.md`, `uninstall.md`) into
   `$HOME/.<SERVICE_NAME>/docs/`, filled with the values actually used, not
   left as placeholders.
10. **Update memory** - record service name, pinned version and digest,
   install path, network placement, install date.

## Hard rules

- Never overwrite an existing service tree or unit. If either exists, stop
  and ask.
- Never write anything before the approval gate.
- Never force-install past a `validate.sh` failure, and never patch a unit
  in place to silence a check - go back to step 1 instead.
- Never hardcode a path: derive from `$HOME` / `$XDG_CONFIG_HOME`, resolve
  with `realpath`, and locate the Quadlet generator with
  `scripts/find-quadlet.sh` (never a literal generator path - it differs
  across distributions).
- All generated files, comments and docs are in English.

## Conformance checklist

Before step 5, every rule in `references/conventions.md` (R1-R11) must
hold. `scripts/validate.sh` checks R1-R11 mechanically; R10's "prefer the
application's own JSON logging option" also needs a human judgement call
that the linter cannot make on its own.
