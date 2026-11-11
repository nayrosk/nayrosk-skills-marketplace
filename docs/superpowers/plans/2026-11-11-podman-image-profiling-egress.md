# podman-quadlet-service v3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an image needs profile (inspection + research, privileged ports, measured resource sizing) and default-deny egress enforced by a new validator rule R14.

**Architecture:** R14 is the only mechanical change: a new check in `scripts/validate.sh` with fixtures in `tests/`. Everything else is agent-facing guidance (SKILL.md, references, templates, runbooks) that tells the agent how to build the profile, handle privileged ports, size and measure limits, and wire the inverted proxy topology.

**Tech Stack:** bash, awk, sed, Podman 5.0+ Quadlet generator, Markdown.

**Spec:** `docs/superpowers/specs/2026-11-11-podman-image-profiling-egress-design.md`

`S` below means `plugins/podman-quadlet-service/skills/podman-quadlet-service`.

## Global Constraints

- Podman 5.0+, rootless, systemd user units; nothing written before the approval gate.
- Rule IDs never renumbered or reused; new rule is **R14**.
- `validate.sh` stays bash/awk/sed + Podman only; no new dependencies. Exit codes unchanged (0 conformant, 1 violations, 2 usage).
- All generated files, comments and docs in English. No em dashes (repo convention, commit e08cf01). Files under `S/references/` use the existing compressed style; keep it.
- The skill never changes host-wide settings (sysctl, firewall) itself: it prints commands for the operator.
- Egress is all-or-nothing in v3.
- Plugin version becomes **3.0.0**.

## Review Focus

1. `Network=` with options (`Network=fixture.network:ip=10.0.0.5`) must be judged by the network name before `:`, not rejected as unknown.
2. A unit with several `Network=` lines where one is internal and one is not must fail R14 (egress leaks through any non-internal network).
3. Egress smuggled through `PodmanArgs=--network=...` / `--net ...` must fail R14, like R8/R9 reject hidden `-v`/`-m`.
4. `Internal=` in the sibling `.network` accepts systemd booleans (`true`, `yes`, `1`, `on`, any case); `Internal=false` or a later `Internal=false` overriding an earlier `true` is not internal.
5. An `# EGRESS:` marker with an empty or whitespace-only reason does not count.

Each is pinned by a fixture in Task 1.

---

### Task 1: R14 in the validator

**Files:**
- Modify: `S/scripts/validate.sh` (new R14 block before the "Quadlet generator must accept the unit" section; header comment `R1..R13` -> `R1..R14`)
- Modify: `S/tests/run.sh` (explicit pass checks; `render()` already copies sibling `.network`)
- Modify: every existing `S/tests/fixtures/*.container` that uses `Network=podman` (insert marker line)
- Modify: `S/tests/fixtures/pass-network-ref.network` (add `Internal=true`)
- Create fixtures listed in Step 1

**Interfaces:**
- Produces: validator diagnostics prefixed `R14:`; marker syntax `# EGRESS: <reason>` (comment line, reason must contain a non-space character). Later tasks document exactly this syntax.

R14 semantics (copy into the code's comment):
- Collect `get_all Network Container`. Strip any `:options` suffix.
- No `Network=` at all -> egress (rootless default network).
- `none` -> no egress. `host`, `pasta*`, `slirp4netns*`, `podman`, `bridge`, `container:*`, `ns:*`, a bare name, or any `<x>.network` that is not a sibling file -> egress.
- `<x>.network` sibling file in the unit's directory -> internal iff the last `Internal=` in its `[Network]` section is a systemd true value (`1|yes|true|on`, case-insensitive).
- Any `PodmanArgs=` (dequoted) containing `--network` or `--net` (with `=` or space) -> fail `R14: PodmanArgs= must not set the network, use Network=` regardless of marker.
- If any network gives egress and no valid marker exists -> `R14: <reason> without '# EGRESS: <reason>'` naming the offending network (or "no Network=").

- [ ] **Step 1: Write the failing fixtures** (copy `conformant.container` as base each time, change only what is named)
  - `violation-r14-no-network.container`: `Network=` line removed, no marker.
  - `violation-r14-podman-network.container`: `Network=podman`, no marker.
  - `violation-r14-non-internal-network.container` + `.network`: `Network=fixture.network`, sibling without `Internal=`.
  - `violation-r14-internal-false-override.container` + `.network`: sibling has `Internal=true` then `Internal=false`.
  - `violation-r14-mixed-networks.container` + `.network`: internal sibling `fixture.network` plus `Network=podman`.
  - `violation-r14-missing-sibling.container`: `Network=other.network`, no file. (Will also LINT; check_rule only needs the R14 line.)
  - `violation-r14-empty-marker.container`: `Network=podman`, `# EGRESS:   `.
  - `violation-r14-podmanargs-network.container`: internal sibling plus `PodmanArgs=--cpus=1.0 --network=host`, with a valid marker present.
  - `pass-egress-internal.container` + `.network`: sibling `Internal=yes`, `Network=fixture.network:ip=10.89.0.5`.
  - `pass-egress-none.container`: `Network=none`.
  - `pass-egress-marker.container`: `Network=podman`, `# EGRESS: fetches ACME certificates from Let's Encrypt`.

  Note on `render()`: it only copies `<fixture-basename>.network`, renamed `fixture.network`; so every sibling-using fixture references `fixture.network`.

- [ ] **Step 2: Add explicit pass checks to `run.sh`**

```bash
check "internal sibling network with options passes (R14)" 0 "$VALIDATE" "$(render "$HERE/fixtures/pass-egress-internal.container")"
check "Network=none passes without marker (R14)" 0 "$VALIDATE" "$(render "$HERE/fixtures/pass-egress-none.container")"
check "EGRESS marker with reason allows a non-internal network (R14)" 0 "$VALIDATE" "$(render "$HERE/fixtures/pass-egress-marker.container")"
```

- [ ] **Step 3: Run `bash S/tests/run.sh`**
  Expected: the 8 `violation-r14-*` cases FAIL ("expected a R14 violation", most exit 0); the 3 new `pass-egress-*` checks PASS (no R14 yet); every pre-existing case still PASSES.

- [ ] **Step 4: Implement the R14 block in `validate.sh`**
  Marker read from the raw file like R13: `tr -d '\r' < "$unit" | grep -qE '^#[[:space:]]*EGRESS:[[:space:]]*[^[:space:]]'`. Sibling `.network` parsed with a small awk over the sibling file (section tracking, last `Internal=` in `[Network]`); reuse the existing `dequote` helper for `PodmanArgs=`.

- [ ] **Step 5: Run `bash S/tests/run.sh`**
  Expected: every new case passes; the old `pass-*` and `conformant` cases now FAIL with `R14` (they use `Network=podman`).

- [ ] **Step 6: Adapt old fixtures**
  Insert `# EGRESS: test fixture, egress is not what this case tests` as line 2 of every existing `*.container` fixture that has egress (all except `pass-network-ref`). Add `Internal=true` under `[Network]` in `pass-network-ref.network`.

- [ ] **Step 7: Run `bash S/tests/run.sh`**
  Expected: `ALL TESTS PASSED`.

- [ ] **Step 8: Commit**

```bash
git add plugins/podman-quadlet-service/skills/podman-quadlet-service/{scripts/validate.sh,tests}
git commit -m "feat(podman)!: R14 default-deny egress in validate.sh"
```

### Task 2: Conventions and unit templates

**Files:**
- Modify: `S/references/conventions.md` (header: "Fourteen conventions", `R1`..`R14`; new `## R14 - No outbound network unless justified` after R13; R9 sizing paragraph; R13 file-capability note cross-references Task 3's privileged-port section)
- Modify: `S/references/templates/service.network` (add `Internal=true` with comment)
- Modify: `S/references/templates/service.container` (network block lines 54-71: default `Network=<SERVICE_NAME>.network`; commented `# EGRESS: <reason>` line with instruction; proxy now joins the service network, not the reverse)

**Interfaces:**
- Consumes: R14 semantics and marker syntax from Task 1.

R14 section content (same shape as other rules: rule, ✅/❌ ini examples, Why): correct = internal sibling, `Network=none`, or marker with reason; incorrect = no `Network=`, `Network=podman` without marker, empty marker, `PodmanArgs=--network=`. State: all-or-nothing (`Internal=true` cuts internet, LAN and host; a service needing only a NAS gets full egress via marker); egress earned like a hardening exception (evidence at step 8).

R9 sizing content: limits come from the image needs profile with a source; Helm `resources.limits` preferred, then upstream docs, else the template values labelled `guess`; step 9 measures peak and proposes a change when peak memory or PIDs is above 80% or below 20% of the limit; operator approves.

- [ ] **Step 1:** Write the conventions changes above.
- [ ] **Step 2:** Edit the templates.
- [ ] **Step 3: Verify the template still lints.** Render `service.container` with the conformant fixture's values, `Network=fixture.network`, plus `service.network` rendered as `fixture.network` with `NetworkName=fixture`, in a temp dir under the scratchpad; run `bash S/scripts/validate.sh <dir>/fixture.container`. Expected: `conformant`. Run `bash S/tests/run.sh`: `ALL TESTS PASSED`.
- [ ] **Step 4: Commit** `docs(podman): R14 convention, sizing guidance, internal-by-default templates`

### Task 3: Networking and preflight references

**Files:**
- Modify: `S/references/networking.md`
- Modify: `S/references/preflight.md`

Networking content to add (decided in the spec, do not re-decide):
- **Inverted topology:** every backend has its own internal `<SERVICE_NAME>.network`; the proxy joins it with one extra `Network=` line in the proxy unit. Proxy keeps its own `# EGRESS:` (ACME). Replace every "join the reverse proxy network" in the decision table and Step 1 text.
- **Proxy unit edit** (Quadlet proxy): ASK, back up the unit, add the `Network=` line, `daemon-reload`, restart proxy. If the proxy is a v2 unit: add the line and the proxy's `# EGRESS:` marker only, run `validate.sh` on it, report other gaps without fixing them.
- **Non-Quadlet proxy** (detected via `podman ps` but no matching `.container` in the unit dir): backend joins the proxy's network with `# EGRESS: proxy not Quadlet-managed`; offer to reinstall the proxy with this skill; never edit or restart it.
- **loopback** = internal network + `PublishPort=127.0.0.1:...`. Record the verification: Podman 6.1.4, netavark, pasta; `--internal` network, `-p 127.0.0.1:18765:8000`, host curl HTTP 200, in-container `wget http://1.1.1.1` -> `Network is unreachable`. Not verified on 5.x; if the step 9 probe fails, fallback marker `# EGRESS: loopback publish unsupported on Podman <version>`, reported to the operator. Same for the `socket` profile's backend port.
- **Privileged ports** section: when a host port P (via `PublishPort=` or `Network=host`) is below `sysctl -n net.ipv4.ip_unprivileged_port_start`, ASK with three options: (1) lower sysctl, root and host-wide, persistent via `/etc/sysctl.d/`, commands printed only; (2) publish a high port (e.g. 8443) plus operator-run firewall redirect, commands printed; (3) `loopback`. `Network=host` is subject to the same sysctl. Distinct from the file-capability case (R13 `AddCapability=NET_BIND_SERVICE`), decided by the profile's `getcap` output; both can apply.

Preflight content to add: profile-gated row "any placement with a host port below 1024 | `sysctl -n net.ipv4.ip_unprivileged_port_start` | value <= lowest wanted port | **ASK** (networking.md privileged ports)"; row "any | `command -v getcap` | path | **INFO**, profile reports file capabilities as not checked".

- [ ] **Step 1:** Write the networking changes.
- [ ] **Step 2:** Write the preflight rows.
- [ ] **Step 3: Verify** every Caddyfile snippet still only uses backend names reachable via the inverted topology (`reverse_proxy <SERVICE_NAME>:<CONTAINER_PORT>` stays valid since the proxy now sits on the backend's network); `grep -n "join.*proxy network" S/references/networking.md` returns only the non-Quadlet fallback.
- [ ] **Step 4: Commit** `docs(podman): inverted proxy topology, privileged ports, egress preflight`

### Task 4: SKILL.md workflow and runbooks

**Files:**
- Modify: `S/SKILL.md`
- Modify: `S/references/templates/docs/install.md`, `S/references/templates/docs/uninstall.md`

SKILL.md changes:
- Intro and Conformance: `R1-R13` -> `R1-R14`.
- Step 1: new **Image needs profile** bullet, after the pull: `podman image inspect` fields (`Config.ExposedPorts`, `Config.User`, `Config.Volumes`, `Entrypoint`/`Cmd`, `StopSignal`, `Env` names only, OCI labels `org.opencontainers.image.source`/`.documentation`/`.url`); file capabilities via `podman unshare sh -c 'm=$(podman image mount <REF>@sha256:<DIGEST>); getcap -r "$m"; podman image unmount <REF>@sha256:<DIGEST>'` using the host's `getcap` ("not checked" if absent); web research of upstream docs, compose file, Helm chart for ports, writable paths, outbound needs (ACME, webhooks, plugin/model downloads, external APIs, telemetry), shutdown, resources. Output: table with rows ports, privileged ports, user/UID, volumes, capabilities, egress, memory, CPU, PIDs, stop path; columns value and source (`inspect`, `docs <url>`, `compose <url>`, `helm <url>`, `guess`).
- Gate list: add the profile table, egress decision, privileged-port choice.
- Step 8: egress earned like hardening exceptions (evidence, marker, re-validate, report); proxy unit edit or non-Quadlet fallback per networking.md.
- Step 9: add resource measurement: `podman stats --no-stream --format '{{.MemUsage}} {{.PIDs}}' <SERVICE_NAME>` sampled during the functional probe; propose adjustment above 80% / below 20%; note a one-shot probe is not load.
- Red flags rows: "Give it network access so it starts" -> egress earned with evidence; "512m is fine" -> limits need a source or the `guess` label; "Lower the sysctl / open the firewall for them" -> print commands, operator runs them.
- Hard rules: never change host-wide settings (sysctl, firewall); never edit or restart a proxy unit without asking.

Runbooks:
- `install.md`: section "Image needs profile" (the table) and "Resource measurement" (peak values, limits before/after, date).
- `uninstall.md`: before the network removal block, a step that removes the backend's `Network=` line from the proxy unit (ASK, backup), `daemon-reload`, restart proxy; explain the proxy otherwise fails on next start.

- [ ] **Step 1:** Edit SKILL.md.
- [ ] **Step 2:** Edit both runbooks.
- [ ] **Step 3: Verify** `grep -n "R1-R13\|R1..R13" -r plugins/podman-quadlet-service` returns nothing; `grep -c "EGRESS" S/SKILL.md` >= 2.
- [ ] **Step 4: Commit** `docs(podman): image needs profile, egress and sizing in workflow`

### Task 5: Release 3.0.0

**Files:**
- Modify: `plugins/podman-quadlet-service/.claude-plugin/plugin.json` (`version` 3.0.0; description mentions image needs profiling and default-deny egress)
- Modify: `.claude-plugin/marketplace.json:13` (`version` 3.0.0)
- Modify: `plugins/podman-quadlet-service/README.md` (R14 row in the rules table near line 82; `R1..R13` -> `R1..R14` at line 106; short "What's new in v3" with the breaking change: v2 units without internal network or marker now fail R14)

- [ ] **Step 1:** Edit the three files.
- [ ] **Step 2: Verify** `python3 -m json.tool` on both JSON files succeeds; `bash S/tests/run.sh` -> `ALL TESTS PASSED`.
- [ ] **Step 3: Commit** `chore(podman)!: release 3.0.0`
