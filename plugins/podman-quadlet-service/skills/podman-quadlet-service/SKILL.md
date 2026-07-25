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

Install containerized service as rootless Podman Quadlet unit. Enforce
`references/conventions.md` (R1-R11) end to end: pinned image, no inline
secrets, healthcheck, bind-mounted state, resource limits, generated runbook.
Need Podman **5.0**+; preflight check real installed version, no assume.

## Workflow

0. **Preflight** - run every check in `references/preflight.md`, in order.
   Failed **ABORT** check stop workflow here, name check. All checks
   read-only except two `references/preflight.md` mark as change: create
   Quadlet unit directory (**CREATE**) and enable linger (**ASK**, only
   after explicit yes). Both host preconditions, not service artifacts;
   nothing belong to service being installed written this step. Unit
   directory creation can defer to step 6, which need it anyway.
1. **Research** - find newest version matching: rootless-capable,
   distroless or minimal, actively maintained. Read upstream docs for
   required capabilities, volumes, ports, env vars, secrets. Resolve exact
   tag + digest with Podman itself, already verified by preflight - no
   extra tool required, none may be assumed present. `podman search
   --list-tags <REGISTRY>/<IMAGE> --format '{{.Tag}}'` sorted with `sort
   -V` show which tags exist. `podman manifest inspect
   <REGISTRY>/<IMAGE>:<TAG>` query registry **without pulling**, print
   manifest per platform. Pin `digest` of entry whose
   `platform.architecture` match `podman info --format
   '{{.Host.Arch}}'`; single-platform image print manifest directly, its
   digest is the one. Step 3 confirm pinned digest after pull with `podman
   image inspect --format '{{.Digest}}'`, which return exactly this value.
   Decide network placement using `references/networking.md`
   (`public-noauth`, `public-auth`, `monitoring`, `loopback`, `internal`).

> ### APPROVAL GATE - STOP HERE
> Present to user: image, tag, digest, why this version, required
> capabilities, network placement, planned volumes, planned resource
> limits. **Write nothing to disk until the user approves.** No directory,
> secret, route, template, or unit file created before gate passed.

2. **Create the local tree** - `$HOME/.<SERVICE_NAME>/` with `data/`,
   `config/`, `repo/` as applicable, and `docs/` always (step 10 write
   runbooks there). Resolve every path with `realpath` (R11); never write
   `~` or `%h` into unit. `.env` not created here - see step 4.
3. **Pull the image** by digest; verify with `podman image inspect --format
   '{{.Digest}}' <REGISTRY>/<IMAGE>@sha256:<DIGEST>` that digest match
   approved one.
4. **Generate configuration** - copy `references/templates/service.container`
   (and `references/templates/service.network` when placement `internal`,
   or when `loopback` service also need named network so other containers
   reach it by DNS name), substitute placeholders, write `.env` from
   `references/templates/env.template`. This step create and fill `.env` -
   not exist before this point. Options must match pulled version own
   docs, not assumption. Delete every template line that not apply rather
   than leave placeholder: unused `Secret=` or `Volume=` line left as
   `<SECRET_NAME>` / `<CONTAINER_DATA_PATH>` is runtime failure, not
   harmless leftover. Write unit next to where it install but do not
   install yet - generate under scratch directory, named exactly
   `<SERVICE_NAME>.container` (`validate.sh` derive expected
   `$HOME/.<SERVICE_NAME>` tree from that basename), copy into unit
   directory in step 6.
4b. **Validate** - run `scripts/validate.sh <unit>`. Exit 0 print
   `conformant`. Exit 1 print one or more `R<n>:` and/or `LINT:` lines -
   real conventions or generator-lint failure; **return to step 1** and
   redo research rather than patch unit in place, restate which check
   failed and what changed when revised proposal pass approval gate again.
   After 3 such failed research -> validate cycles, stop and hand decision
   to user instead of cycling again. Exit 2 is usage error (missing or
   unreadable unit path) - fix invocation and re-run; not conventions
   failure, no return to step 1, no count toward 3-cycle limit.
4c. **Create secrets** - for every `Secret=<name>,type=...` line in
   generated unit, ask operator for value (never invent, never infer from
   upstream docs or examples) and create with `podman secret create <name>
   -`. Value never written to `.env` or into unit - only secret name
   appear there (R4).
5. **Write the reverse-proxy route** - for `public-noauth`, `public-auth`,
   `monitoring` placements, add route using matching snippet from
   `references/networking.md` and reload/validate proxy config as that
   section describe. `loopback` and `internal` have no route to write -
   `loopback` reached directly on `127.0.0.1`, `internal` not exposed.
6. **Install** - place unit(s) in
   `${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/`, then
   `systemctl --user daemon-reload`.
7. **Enable** - `systemctl --user start <SERVICE_NAME>`, then confirm
   active. Generated unit is `Type=notify`, so `systemctl --user
   is-active` can legitimately still print `activating` few seconds after
   `start` return; re-check rather than treat first `activating` as
   success. `failed`, or `activating (auto-restart)` with rising restart
   counter, is crash loop - go straight to logs below, no wait it out.
8. **Monitor the healthcheck** - poll at most 20 times, 5s apart (`podman
   healthcheck run` check immediately, not wait out `HealthStartPeriod=`
   on own). On timeout, fail loud with `journalctl --user -u
   <SERVICE_NAME>` output and offer rollback in
   `references/templates/docs/uninstall.md`, substituting values used for
   this install - generated copy in `docs/` not exist yet at this point
   (see step 10). Use `journalctl`, **not** `podman logs`: Quadlet
   generated `ExecStart` run `podman run --rm` and `ExecStopPost` run
   `podman rm -f`, so container that failed to start already gone and
   `podman logs <SERVICE_NAME>` only report `no such container` - exactly
   when its output needed most.

   Container that die immediately with `exec container process <path>:
   Operation not permitted` is `DropCapability=ALL` / file-capability
   interaction, not bad image: see `references/conventions.md` R9 note on
   hardening defaults.
9. **Test** - functional probe appropriate to service, plus reachability
   through reverse-proxy route written in step 5, when one configured.
10. **Write the runbooks** - copy `references/templates/docs/*.md`
   (`install.md`, `update.md`, `rotate.md`, `uninstall.md`) into
   `$HOME/.<SERVICE_NAME>/docs/` (created in step 2), filled with values
   actually used, not left as placeholders.
11. **Update memory** - record service name, pinned version and digest,
   install path, network placement, install date.

## Hard rules

- Never overwrite existing service tree or unit. If either exist, stop and
  ask.
- Never write anything before approval gate: no directory, secret, route,
  or unit file.
- Never invent or infer secret value; ask operator, never write it to
  `.env` or into unit.
- Never force-install past `validate.sh` exit-1 failure, never patch unit
  in place to silence check - go back to step 1. `validate.sh` exit-2 is
  usage error, not conventions failure.
- Never hardcode path: derive from `$HOME` / `$XDG_CONFIG_HOME`, resolve
  with `realpath`. Preflight and `validate.sh` already locate Quadlet
  generator via `scripts/find-quadlet.sh`; no other step need reference
  its path.
- All generated files, comments, docs in English.

## Conformance checklist

Before step 6, every rule in `references/conventions.md` (R1-R11) must
hold. `scripts/validate.sh` check R1-R11 mechanically; R10 "prefer the
application's own JSON logging option" also need human judgement call
linter cannot make alone.