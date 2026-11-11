# Lifecycle profiles

Decide **when the container should exist** before writing the unit. This
decision changes `[Unit]`, `[Service]` and `[Install]`, the readiness gate,
and which extra artifacts (a client wrapper, a socket, a timer) get
generated. A unit with the wrong profile still runs, but it runs at the
wrong times: an always-on daemon that only one tool calls a few times a day
uses 2 GB of RAM for nothing, and an on-demand backend shaped like a daemon
respawns after every manual stop.

Every unit declares its profile on a comment line that `scripts/validate.sh`
reads (R7):

```ini
# LIFECYCLE: daemon
```

## Step 1: Classify the workload

Ask who starts the work and what "done" means. Answer from the operator's
description and the upstream docs, then confirm the choice at the approval
gate.

| Signal | Profile |
|---|---|
| Serves other machines or users, must survive reboot, is expected to be "up" (web app, database, reverse proxy, DNS, monitoring) | `daemon` |
| Backend for a **local client process** with a clear session lifetime: MCP server, IDE helper, CLI companion. Several clients may share it | `on-demand` |
| Network service used **sporadically** by arbitrary clients (curl, browser, other containers), with no client process to hook into, where a cold start of a few seconds is acceptable | `socket` |
| Does a unit of work and exits: backup, sync, report, certificate renewal, scheduled scrape | `job` |

Tie-breakers:

- If you can wrap the client's launch command, prefer `on-demand` to
  `socket`. Refcounting by client process is exact, while an idle timeout
  is a guess.
- `socket` is wrong when the client keeps a long-lived connection open but
  needs the backend between connections (cache warmup, in-memory state), or
  when a cold start is longer than the client's connect timeout.
- A database with on-demand consumers is still a `daemon`: data services
  must not be stopped mid-write by an idle timer.
- If the application natively supports systemd socket activation
  (`LISTEN_FDS`, e.g. some Go and Rust servers), Podman can pass the socket
  straight to the container with no proxy. That only works if upstream
  documents it, so do not assume it.

## Step 2: Unit shape per profile

### `daemon` - always on

```ini
# LIFECYCLE: daemon
[Container]
HealthOnFailure=kill          # unhealthy -> killed -> Restart= brings it back

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
```

Requires linger (`loginctl enable-linger`) so the unit starts at boot
without a login session. `HealthOnFailure=kill` is what makes the
healthcheck act: without it Podman marks the container `unhealthy` and
nothing else happens.

### `on-demand` - refcounted by client processes

```ini
# LIFECYCLE: on-demand
[Unit]
StopWhenUnneeded=yes

[Container]
Notify=healthy                # "started" only once the healthcheck passes
HealthStartupCmd=<same probe as HealthCmd>
HealthStartupInterval=1s
HealthStartupRetries=120
HealthStartupSuccess=1

[Service]
Restart=on-failure
RestartSec=10

# no [Install] section
```

Each client launches through the wrapper generated from
`references/templates/client-wrapper.sh`. The wrapper runs the real client
command inside a transient `systemd-run --user --scope` that `Wants=` and
is ordered `After=` the container unit. systemd keeps the refcount: the
first scope starts the container, and when the last scope exits the
container is no longer needed and `StopWhenUnneeded=yes` stops it.

The scope inherits the caller's environment and stdio, so a stdio protocol
(MCP JSON-RPC, LSP) passes through unchanged. A client that exits on stdin
EOF or is killed with SIGTERM releases its scope immediately (verified
with Claude Code, Claude Desktop and OpenCode style launchers).

If the backend requires a token (it should whenever it listens on a TCP
port: any local web page can reach `127.0.0.1`), the same podman secret
feeds both sides. The container gets it through `Secret=` (R4), and the
wrapper exports it to the client only, at launch, never writing it to a
file:
`export <CLIENT_VAR>="$(podman secret inspect --showsecret --format
'{{.SecretData}}' <SECRET_NAME>)"`. The client-side variable name comes
from the client's docs: ask the operator if it is not documented.

Point every client config at the wrapper, never at the raw command: one
client that bypasses it can neither start the container nor keep it alive.

**Caveat:** a client that is itself a long-running daemon (e.g.
`opencode serve`) holds its scope for its whole lifetime, so the container
stays up as long as that daemon runs. That is correct behavior, but tell
the operator at the gate.

**Gotcha:** `systemctl --user start <SERVICE_NAME>` on its own is not a
test of this profile. Nothing needs the unit, so `StopWhenUnneeded=yes`
stops it within the same second (verified). To keep it up for
debugging, hold it from a scope:
`systemd-run --user --scope -p Wants=<SERVICE_NAME>.service -p
After=<SERVICE_NAME>.service -- sleep 600`.

`Notify=healthy` matters here: without it the scope is released to run its
command as soon as `podman run` forks, and the client's first request hits
a port that is not listening yet. The startup probe at 1s makes readiness
take seconds instead of a full `HealthInterval=`.

### `socket` - socket-activated with idle exit

Three units. The container keeps its own loopback `PublishPort=` on an
**internal** port, and systemd owns the **public** port:

```ini
# <SERVICE_NAME>.container
# LIFECYCLE: socket
[Unit]
StopWhenUnneeded=yes
[Container]
PublishPort=127.0.0.1:<BACKEND_PORT>:<CONTAINER_PORT>
Notify=healthy
HealthStartupCmd=...          # as for on-demand
[Service]
Restart=on-failure
# no [Install]
```

Then copy `references/templates/socket-proxy.socket` and
`references/templates/socket-proxy.service` to
`${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/<SERVICE_NAME>-proxy.{socket,service}`
and enable only the socket (`systemctl --user enable --now
<SERVICE_NAME>-proxy.socket`). `<SOCKET_PROXYD>` is the absolute path
preflight resolved, because it differs between distributions. The first connection starts the proxy, the
proxy `Requires=` and is ordered `After=` the container (which is only
"started" once healthy). `systemd-socket-proxyd --exit-idle-time=` (systemd
246 or later) exits after the idle period, nothing needs the container any
more, and it stops.

Measured on this skill's reference host: about 0.6s cold start for a small
HTTP server, idle stop at the configured timeout.

Pick `--exit-idle-time=` above the client's longest expected pause between
requests (default suggestion: `10min`).

**Failure mode:** if the container cannot start, every incoming connection
retries the start and the unit hits `start-limit-hit` in under a second.
The socket stays listening, but nothing gets through until
`systemctl --user reset-failed <SERVICE_NAME>`. Verify the backend starts
on its own (`systemctl --user start <SERVICE_NAME>`) **before** enabling
the socket.

### `job` - run to completion

```ini
# LIFECYCLE: job
[Service]
Type=oneshot                  # Quadlet keeps this when set explicitly
Restart=no
# no [Install]: the timer is what gets enabled
```

Pair it with `references/templates/service.timer` installed as
`<SERVICE_NAME>.timer` in `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/`
(enable the timer, never the service). No healthcheck is needed for a job
that exits. Record the omission with the R5 marker
`# NO-HEALTHCHECK: job - <what proves success, e.g. exit status 0>`.
`Persistent=true` on the timer catches runs missed while the host was off.
Drop `RandomizedDelaySec=` when the operator asked for an exact time.

Job specifics:

- **Shell payload.** A job is often a short script, which is legitimate:
  `Exec=/bin/sh -euc '<script>'` with `RunInit=true`. Write `$$` for every
  shell `$` and `%%` for every literal `%` (systemd expands single ones),
  and check the expanded command with `quadlet -dryrun`.
- **Exit 143 is a failure here.** A job killed mid-run did not finish, so
  never add `SuccessExitStatus=143` to a job.
- **Reading another service's data** (backup, export) uses R8's
  `# EXTERNAL-MOUNT:` marker. The source is mounted `:ro`, and a
  destination outside the job's tree must be named by the operator.
  Several containers sharing one directory use the shared SELinux label
  `:z` (lowercase); `:Z` would relabel it private to the last container
  that mounted it.
- **Consistency.** Copying a live database file (SQLite, LevelDB, a
  Postgres data dir) can produce a corrupt backup. Prefer the app's own
  dump or backup command. Otherwise quiesce the source around the copy
  (`ExecStartPre=systemctl --user stop <SOURCE>` /
  `ExecStopPost=systemctl --user start <SOURCE>`), and state the downtime
  window at the gate.
- **Retention.** Write to `<name>.part`, then rename on success. Prune
  archives older than the retention period in the same run, matching the
  job's own filename prefix only. The retention period is the operator's
  decision: ask for it.


## Step 3: What to show at the approval gate

- The profile and the one-line reason, based on the classification table.
- For `on-demand`: every client config that will be repointed at the
  wrapper, by file path.
- For `socket`: public port, backend port, idle timeout, and the measured
  or expected cold-start time.
- For `job`: the schedule (`OnCalendar=`), and what counts as success.

## Step 4: Lifecycle verification (step 9 of the workflow)

| Profile | Must observe |
|---|---|
| `daemon` | `systemctl --user is-enabled` prints `enabled`; after `podman kill <name>` the unit comes back by itself |
| `on-demand` | the container is `inactive` before any client starts; it is `active` while a wrapper runs; it is `inactive` again a few seconds after the last wrapper exits; `NRestarts=0` |
| `socket` | backend `inactive` before the first connection; first request succeeds; backend `inactive` after `--exit-idle-time` plus a few seconds |
| `job` | `systemctl --user start <name>` ends with `Result=success`; `systemctl --user list-timers` shows the next run |

And for every profile, run the R12 stop test from `references/conventions.md`.
