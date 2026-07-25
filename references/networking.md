# Networking

This is step 1 of the workflow: **decide where the service sits on the
network before writing any unit.** The decision drives which template
(`service.network` from `references/templates/`, or a `PublishPort=` line)
gets used, and — for anything that speaks HTTP — which Caddy route, if any,
gets added.

## Step 1: Detect an existing reverse proxy

Never assume a reverse proxy exists, and never install one without asking.
Detect first:

```bash
podman network ls --format '{{.Name}}'
podman ps --all --format '{{.Names}}\t{{.Image}}' \
  | grep -Ei 'caddy|traefik|nginx|npm|haproxy' || echo "no reverse proxy found"
```

**Reverse proxy found** → use it. Join its network and derive route syntax
from its configuration style (the Caddy snippets below if it is Caddy;
otherwise inspect its existing config for the pattern in use — do not
introduce a second proxy technology onto a host that already has one).

**None found** → ASK the user. Offer three options and let them choose:

1. Install Caddy first, as a separate run of this skill (Caddy only becomes
   the default reverse proxy once the user explicitly says yes — it is
   never installed silently as a side effect of installing something else).
2. Loopback-only exposure (`PublishPort=127.0.0.1:<PORT>:<CONTAINER_PORT>`,
   no proxy involved).
3. Internal network only (the `internal` decision below — no host port at
   all).

## Step 2: Exposure decision table

Every service lands in exactly one of these four buckets:

| Decision | Meaning | How it's wired |
|---|---|---|
| `public-noauth` | Reachable externally, unauthenticated | Join the reverse proxy network; add the plain route |
| `public-auth` | Reachable externally, authenticated | Join the reverse proxy network; add the route behind basic auth |
| `monitoring` | Metrics / health endpoints | Reachable on loopback **and** on the authenticated route; **never** publicly unauthenticated |
| `internal` | No external exposure | Dedicated `<SERVICE_NAME>.network` from `service.network`; no `PublishPort=` |

`monitoring` is not a variant of `public-noauth` — a metrics or health
endpoint is never handed out over the public route without authentication,
even if the service it belongs to is otherwise `public-noauth`. Route it
separately, as shown in the monitoring snippet below.

## Step 3: Caddy route snippets

These snippets target **Caddy 2.8 and later** — see "Version validated
against" below for exactly what was tested. The directive used for HTTP
basic auth was renamed from `basicauth` to `basic_auth` in Caddy 2.8; these
snippets use the current name throughout.

Placeholders: `<SERVICE_FQDN>` (the public hostname routed to this
service), `<SERVICE_NAME>` (matches the Quadlet unit and container name),
`<CONTAINER_PORT>` (the port the container listens on inside its network),
`<USERNAME>` and `<BCRYPT_HASH>` (from `caddy hash-password`; the plaintext
password itself is stored as a podman secret and never committed, and
never appears in a Caddyfile).

**Plain route** (`public-noauth`):

```caddyfile
<SERVICE_FQDN> {
    reverse_proxy <SERVICE_NAME>:<CONTAINER_PORT>
}
```

**Behind basic auth** (`public-auth`):

```caddyfile
<SERVICE_FQDN> {
    basic_auth {
        <USERNAME> <BCRYPT_HASH>
    }
    reverse_proxy <SERVICE_NAME>:<CONTAINER_PORT>
}
```

**Monitoring** (`monitoring` — loopback exempt, everything else
authenticated):

```caddyfile
<SERVICE_FQDN> {
    @monitoring path /metrics /healthz
    handle @monitoring {
        @notlocal not remote_ip 127.0.0.1/8 ::1
        basic_auth @notlocal {
            <USERNAME> <BCRYPT_HASH>
        }
        reverse_proxy <SERVICE_NAME>:<CONTAINER_PORT>
    }
    handle {
        reverse_proxy <SERVICE_NAME>:<CONTAINER_PORT>
    }
}
```

### Caveat: `remote_ip 127.0.0.1/8` is unreliable when Caddy itself runs as a rootless Podman container reached through a published port

The monitoring snippet's loopback exemption assumes Caddy sees the real
client IP for local requests. That assumption was tested and does **not**
hold under this skill's own deployment model.

Test performed: a Caddy container was run with
`-p 127.0.0.1:8899:8899` (rootless Podman 6.0.1, netavark, `pasta` as the
rootless network command, `rootlessport` as the port forwarder — this
skill's default stack) and a Caddyfile that echoes
`{http.request.remote.host}`. A request made with `curl` from the **host's
own loopback interface** — the most trusted case there is — arrived at
Caddy as the host's LAN-facing IP address, not `127.0.0.1`:

```
$ curl -s http://127.0.0.1:8899/
remote_ip=192.168.1.41 remote=192.168.1.41:53538
```

The rootless port-forwarding path (`rootlessport` handing off to `pasta`)
rewrites the apparent source address of every forwarded connection,
including ones that genuinely originated on loopback. Consequences:

- **Fails closed for the common case**: a Prometheus instance (or an
  admin's `curl`) running directly on the host and scraping through
  Caddy's published port will *not* match `remote_ip 127.0.0.1/8 ::1`, so
  it will be challenged for basic auth even though the request never left
  the machine. Plan for this — do not assume the loopback exemption "just
  works" for host-local scraping through a published port.
- **Cannot be trusted as a security boundary either way**: because the
  forwarder substitutes its own address for the real client's, `remote_ip`
  observed by a Caddy container behind rootless port publishing reflects
  the forwarding layer, not the peer. Do not extend this pattern to other
  IP-based allow-lists (e.g. "allow my office's public IP") without
  independently verifying, on the actual target host, that the address
  Caddy logs for a known test request matches expectations. Treat any
  `remote_ip`-based rule in front of a rootless, port-published container
  as unverified until checked with the same kind of test shown above.

**Recommended mitigation**: for the `monitoring` decision, prefer network
segregation over IP matching wherever possible. Give the monitoring
consumer (e.g. a Prometheus container) membership in the same internal
Podman network as the service and Caddy, and have it scrape the service
directly by container DNS name — that path never crosses the rootless
NAT boundary this caveat is about, so it needs no `remote_ip` check at
all. Keep the `remote_ip` guard in the Caddyfile as defense in depth for
the externally-routed leg, but do not rely on it alone, and re-validate it
with a live request on the actual host (not just `caddy validate`, which
only checks syntax) before treating loopback access as working.

## Step 4: Validate the Caddyfile syntax

Always validate generated Caddyfile snippets against a real Caddy
container before handing them to the operator — `caddy validate` only
checks that the config parses and adapts, but that is still the cheapest
way to catch a directive-name mismatch (like the `basicauth` /
`basic_auth` rename) before it reaches a production host:

```bash
podman run --rm -i docker.io/library/caddy:2 \
  caddy validate --adapter caddyfile --config /dev/stdin <<'EOF'
example.test {
    basic_auth {
        admin $2a$14$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTU
    }
    reverse_proxy myservice:8080
}
EOF
```

Expected: `Valid configuration`.

### Version validated against

`docker.io/library/caddy:2` resolved to **Caddy v2.11.4** at validation
time. All three snippets above (plain route, basic auth, monitoring) were
run through `caddy validate --adapter caddyfile` against this version with
their placeholders substituted for concrete test values, and each printed
`Valid configuration`. `basic_auth` is the correct, non-deprecated
directive name on this version; `caddy validate` additionally still
accepts the pre-2.8 `basicauth` spelling on v2.11.4 with a deprecation
warning rather than a hard error, so a stale snippet using the old name
would not be caught by validation alone — use `basic_auth` regardless, and
re-run this validation step against whatever Caddy image tag the target
host will actually pull if it differs from `caddy:2`.
