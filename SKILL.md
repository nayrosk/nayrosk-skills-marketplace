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
   Every check is read-only except the two `references/preflight.md` marks
   as making a change: creating the Quadlet unit directory (**CREATE**) and
   enabling linger (**ASK**, only after an explicit yes). Both are host
   preconditions, not service artifacts; nothing belonging to the service
   being installed is written in this step. Creating the unit directory may
   also be deferred to step 6, which needs it anyway.
1. **Research** - find the newest version matching: rootless-capable,
   distroless or minimal, actively maintained. Read upstream docs for
   required capabilities, volumes, ports, environment variables and
   secrets. Resolve the exact tag and its digest with Podman itself, which
   preflight has already verified - no extra tool is required, and none may
   be assumed present. `podman search --list-tags <REGISTRY>/<IMAGE>
   --format '{{.Tag}}'` sorted with `sort -V` shows which tags exist, and
   `podman manifest inspect <REGISTRY>/<IMAGE>:<TAG>` queries the registry
   **without pulling**, printing the manifest for each platform. Pin the
   `digest` of the entry whose `platform.architecture` matches `podman info
   --format '{{.Host.Arch}}'`; for a single-platform image the manifest is
   printed directly and its digest is the one to use. Step 3 confirms the
   pinned digest after pulling with `podman image inspect --format
   '{{.Digest}}'`, which returns exactly this value. Decide network placement
   using `references/networking.md` (`public-noauth`, `public-auth`,
   `monitoring`, `loopback`, or `internal`).

> ### APPROVAL GATE - STOP HERE
> Present to the user: image, tag, digest, why this version, required
> capabilities, network placement, planned volumes, planned resource
> limits. **Write nothing to disk until the user approves.** No directory,
> secret, route, template, or unit file is created before this gate is
> passed.

2. **Create the local tree** - `$HOME/.<SERVICE_NAME>/` with `data/`,
   `config/`, `repo/` as applicable, and `docs/` always (step 10 writes
   the runbooks there). Resolve every path with `realpath` (R11); never
   write `~` or `%h` into a unit. `.env` itself is not created here - see
   step 4.
3. **Pull the image** by digest; verify with `podman image inspect --format
   '{{.Digest}}' <REGISTRY>/<IMAGE>@sha256:<DIGEST>` that the digest matches
   what was approved.
4. **Generate configuration** - copy `references/templates/service.container`
   (and `references/templates/service.network` when the placement is
   `internal`, or when a `loopback` service also needs a named network for
   other containers to reach it by DNS name), substitute the placeholders,
   and write `.env` from `references/templates/env.template`. This is the
   step that creates and fills `.env` - it does not exist before this
   point. Options must match the pulled version's own docs, not assumption.
   Delete every template line that does not apply to this service rather
   than leaving its placeholder in: an unused `Secret=` or `Volume=` line
   left as `<SECRET_NAME>` / `<CONTAINER_DATA_PATH>` is a runtime failure,
   not a harmless leftover. Write the unit next to where it will be
   installed but do not install it yet - generate it under a scratch
   directory, named exactly `<SERVICE_NAME>.container` (`validate.sh`
   derives the expected `$HOME/.<SERVICE_NAME>` tree from that basename),
   and copy it into the unit directory in step 6.
4b. **Validate** - run `scripts/validate.sh <unit>`. Exit 0 prints
   `conformant`. Exit 1 prints one or more `R<n>:` and/or `LINT:` lines - a
   real conventions or generator-lint failure; **return to step 1** and
   redo the research rather than patching the unit in place, restating
   which check failed and what changed when the revised proposal passes
   the approval gate again. After 3 such failed research -> validate
   cycles, stop and hand the decision to the user instead of cycling
   again. Exit 2 is a usage error (missing or unreadable unit path) - fix
   the invocation and re-run; it is not a conventions failure and neither
   returns to step 1 nor counts toward the 3-cycle limit.
4c. **Create secrets** - for every `Secret=<name>,type=...` line in the
   generated unit, ask the operator for the value (never invent it, never
   infer it from upstream docs or examples) and create it with
   `podman secret create <name> -`. The value is never written to `.env`
   or into the unit - only the secret's name appears there (R4).
5. **Write the reverse-proxy route** - for the `public-noauth`,
   `public-auth`, and `monitoring` placements, add the route using the
   matching snippet from `references/networking.md` and reload/validate
   the proxy's config as that section describes. The `loopback` and
   `internal` placements have no route to write - `loopback` is reached
   directly on `127.0.0.1` and `internal` is not exposed at all.
6. **Install** - place the unit(s) in
   `${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/`, then
   `systemctl --user daemon-reload`.
7. **Enable** - `systemctl --user start <SERVICE_NAME>`, then confirm it is
   active. The generated unit is `Type=notify`, so `systemctl --user
   is-active` can legitimately still print `activating` for a few seconds
   after `start` returns; re-check rather than treating the first
   `activating` as success. `failed`, or `activating (auto-restart)` with a
   rising restart counter, is a crash loop - go straight to the logs below
   instead of waiting it out.
8. **Monitor the healthcheck** - poll at most 20 times, 5s apart (`podman
   healthcheck run` checks immediately and does not wait out
   `HealthStartPeriod=` on its own). On timeout, fail loudly with
   `journalctl --user -u <SERVICE_NAME>` output and offer the rollback in
   `references/templates/docs/uninstall.md`, substituting the values used
   for this install - the generated copy in `docs/` does not exist yet at
   this point (see step 10). Use `journalctl`, **not** `podman logs`:
   Quadlet's generated `ExecStart` runs `podman run --rm` and its
   `ExecStopPost` runs `podman rm -f`, so a container that failed to start
   is already gone and `podman logs <SERVICE_NAME>` only reports `no such
   container` - exactly when its output is needed most.

   A container that dies immediately with `exec container process
   <path>: Operation not permitted` is the `DropCapability=ALL` /
   file-capability interaction, not a bad image: see
   `references/conventions.md` R9's note on hardening defaults.
9. **Test** - a functional probe appropriate to the service, plus
   reachability through the reverse-proxy route written in step 5, when
   one was configured.
10. **Write the runbooks** - copy `references/templates/docs/*.md`
   (`install.md`, `update.md`, `rotate.md`, `uninstall.md`) into
   `$HOME/.<SERVICE_NAME>/docs/` (created in step 2), filled with the
   values actually used, not left as placeholders.
11. **Update memory** - record service name, pinned version and digest,
   install path, network placement, install date.

## Hard rules

- Never overwrite an existing service tree or unit. If either exists, stop
  and ask.
- Never write anything before the approval gate: no directory, secret,
  route, or unit file.
- Never invent or infer a secret's value; ask the operator, and never
  write it to `.env` or into the unit.
- Never force-install past a `validate.sh` exit-1 failure, and never patch
  a unit in place to silence a check - go back to step 1 instead. A
  `validate.sh` exit-2 is a usage error, not a conventions failure.
- Never hardcode a path: derive from `$HOME` / `$XDG_CONFIG_HOME` and
  resolve with `realpath`. Preflight and `validate.sh` already locate the
  Quadlet generator via `scripts/find-quadlet.sh`; no other step needs to
  reference its path.
- All generated files, comments and docs are in English.

## Conformance checklist

Before step 6, every rule in `references/conventions.md` (R1-R11) must
hold. `scripts/validate.sh` checks R1-R11 mechanically; R10's "prefer the
application's own JSON logging option" also needs a human judgement call
that the linter cannot make on its own.
