# Networking

Step 1 of workflow: **decide where service sit on network before write any unit.** Decision drive which template (`service.network` from `references/templates/`, or `PublishPort=` line) get used, and - for anything speaking HTTP - which Caddy route, if any, get added.

## Step 1: Detect an existing reverse proxy

Never assume reverse proxy exist. Never install one without asking. Detect first:

```bash
podman network ls --format '{{.Name}}'
podman ps --all --format '{{.Names}}\t{{.Image}}' \
  | grep -Ei 'caddy|traefik|nginx|npm|haproxy' || echo "no reverse proxy found"
```

**Reverse proxy found** → use it. Join its network, derive route syntax from its config style (Caddy snippets below if Caddy; else inspect existing config for pattern in use - no second proxy technology on host that already have one).

**None found** → ASK user. Offer three options, let them choose:

1. Install Caddy first, as separate run of this skill (Caddy become default reverse proxy only when user explicitly say yes - never installed silently as side effect of installing something else).
2. Loopback-only exposure (`PublishPort=127.0.0.1:<PORT>:<CONTAINER_PORT>`, no proxy).
3. Internal network only (`internal` decision below - no host port at all).

## Step 2: Exposure decision table

Every service land in exactly one of five buckets:

| Decision | Meaning | How it's wired |
|---|---|---|
| `public-noauth` | Reachable externally, unauthenticated | Join the reverse proxy network; add the plain route |
| `public-auth` | Reachable externally, authenticated | Join the reverse proxy network; add the route behind basic auth |
| `monitoring` | Metrics / health endpoints | Reachable on loopback **and** on the authenticated route; **never** publicly unauthenticated |
| `loopback` | Reachable from this host only, with no proxy in front | `PublishPort=127.0.0.1:<PORT>:<CONTAINER_PORT>`; no route to write |
| `internal` | No external exposure at all | Dedicated `<SERVICE_NAME>.network` from `service.network`; no `PublishPort=` |

`loopback` = step 1 option 2, own bucket: not `internal` (which publish no host port at all), not `public-*` (nothing routed to it). Right answer whenever operator decline reverse proxy. **Only** correct answer for reverse proxy's own container - proxy is terminus of routing, never routed through itself. Install proxy as `loopback` (or, when it should serve outside world, publish on host's real addresses), route *other* services through it.

`loopback` and `internal` combinable too, and for reverse proxy normally are: publish proxy on loopback **and** give it dedicated `<SERVICE_NAME>.network` from `service.network`, so backends it proxy can join that network and be reached by container DNS name without publishing own ports. Generate both units in that case.

`monitoring` not variant of `public-noauth` - metrics or health endpoint never handed out over public route without auth, even if owning service otherwise `public-noauth`. Route it separately, per monitoring snippet below.

## Step 3: Caddy route snippets

Snippets target **Caddy 2.8 and later** - see "Version validated against" below for exact tested scope. HTTP basic auth directive renamed `basicauth` → `basic_auth` in Caddy 2.8; snippets use current name throughout.

Placeholders: `<SERVICE_FQDN>` (public hostname routed to this service), `<SERVICE_NAME>` (match Quadlet unit + container name), `<CONTAINER_PORT>` (port container listen on inside its network), `<USERNAME>` and `<BCRYPT_HASH>` (from `caddy hash-password`; plaintext password stored as podman secret, never committed, never in Caddyfile).

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

**Monitoring** (`monitoring` - loopback exempt, everything else authenticated):

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

Monitoring snippet's loopback exemption assume Caddy see real client IP for local requests. That assumption tested and does **not** hold under this skill's own deployment model.

Test performed: Caddy container run with `-p 127.0.0.1:8899:8899` (rootless Podman 6.0.1, netavark, `pasta` as rootless network command, `rootlessport` as port forwarder - this skill's default stack) and Caddyfile echoing `{http.request.remote.host}`. Request made with `curl` from **host's own loopback interface** - most trusted case there is - arrived at Caddy as host's LAN-facing IP, not `127.0.0.1`:

```
$ curl -s http://127.0.0.1:8899/
remote_ip=192.168.1.41 remote=192.168.1.41:53538
```

Rootless port-forwarding path (`rootlessport` handing off to `pasta`) rewrite apparent source address of every forwarded connection, including ones genuinely originating on loopback. Consequences:

- **Fails closed for the common case**: Prometheus instance (or admin's `curl`) running directly on host and scraping through Caddy's published port will *not* match `remote_ip 127.0.0.1/8 ::1`, so it get challenged for basic auth even though request never left machine. Plan for this - do not assume loopback exemption "just works" for host-local scraping through published port.
- **Cannot be trusted as security boundary either way**: because forwarder substitute its own address for real client's, `remote_ip` seen by Caddy container behind rootless port publishing reflect forwarding layer, not peer. Do not extend this pattern to other IP-based allow-lists (e.g. "allow my office's public IP") without independently verifying, on actual target host, that address Caddy log for known test request match expectations. Treat any `remote_ip`-based rule in front of rootless, port-published container as unverified until checked with same kind of test shown above.

**Recommended mitigation**: for `monitoring` decision, prefer network segregation over IP matching wherever possible. Give monitoring consumer (e.g. Prometheus container) membership in same internal Podman network as service and Caddy, have it scrape service directly by container DNS name - that path never cross rootless NAT boundary this caveat about, so needs no `remote_ip` check at all. Keep `remote_ip` guard in Caddyfile as defense in depth for externally-routed leg, but do not rely on it alone, and re-validate with live request on actual host (not just `caddy validate`, which only check syntax) before treating loopback access as working.

## Step 4: Validate the Caddyfile syntax

Always validate generated Caddyfile snippets against real Caddy container before handing to operator - `caddy validate` only check config parse + adapt, but still cheapest way to catch directive-name mismatch (like `basicauth` / `basic_auth` rename) before it reach production host:

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

`docker.io/library/caddy:2` resolved to **Caddy v2.11.4** at validation time. All three snippets above (plain route, basic auth, monitoring) run through `caddy validate --adapter caddyfile` against this version with placeholders substituted for concrete test values, each printed `Valid configuration`. `basic_auth` is correct, non-deprecated directive name on this version; `caddy validate` still accept pre-2.8 `basicauth` spelling on v2.11.4 with deprecation warning, not hard error - so stale snippet using old name would not be caught by validation alone. Use `basic_auth` regardless, and re-run this validation step against whatever Caddy image tag target host will actually pull if it differ from `caddy:2`.