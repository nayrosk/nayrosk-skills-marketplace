# <SERVICE_NAME> - Rotate secrets and logs

## Secret rotation

Podman secrets are immutable by name: rotating a value means replacing the
secret under the same name, then restarting so the container picks up the
new value at the next start (secrets are injected at container creation,
not live-reloaded).

```bash
# Replace the secret's value, then restart to pick it up
printf '%s' "$NEW_VALUE" | podman secret create --replace <SECRET_NAME> -
systemctl --user restart <SERVICE_NAME>

# Poll for health instead of probing once - podman healthcheck run executes
# the check immediately and does not wait out HealthStartPeriod= on its
# own, so a single call right after a restart can misreport a service that
# is merely slow to start. Same bound as update.md and the install
# workflow: at most 20 times, 5s apart, failing loudly with the service log
# on timeout. Use journalctl, not `podman logs`: the generated unit runs
# `podman run --rm`, so a container that failed to start is already gone and
# `podman logs` prints only "no such container".
healthy=0
for i in $(seq 1 20); do
  podman healthcheck run <SERVICE_NAME> >/dev/null 2>&1 && { healthy=1; break; }
  sleep 5
done
if [ "$healthy" -eq 1 ]; then
  echo "healthy"
else
  echo "TIMEOUT: <SERVICE_NAME> did not become healthy after rotation" >&2
  journalctl --user -u <SERVICE_NAME> --no-pager -n 100
fi
```

If the new value is wrong, the previous secret content is not recoverable
from Podman (secrets are not versioned) - keep the old value in a password
manager until the rotation is confirmed healthy, not in a file in this
service's tree.

## Reverse proxy basic-auth rotation

Only applies when this service is routed through Caddy with the
`public-auth` or `monitoring` decision (`references/networking.md`). The
credential itself is a podman secret (never a plaintext value in the
Caddyfile); only the bcrypt hash appears in the route.

```bash
# 1. Generate a new bcrypt hash for the new password. --algorithm bcrypt is
#    explicit here because <BCRYPT_HASH> in the Caddyfile route must be a
#    bcrypt hash, and it should not depend on whatever algorithm caddy
#    hash-password defaults to on the image version in use.
NEW_HASH="$(podman run --rm -i <REGISTRY>/<IMAGE>:<TAG> \
  caddy hash-password --plaintext "$NEW_PASSWORD" --algorithm bcrypt)"

# 2. Store the plaintext password as a podman secret (never in the
#    Caddyfile or in this repo), and update the <USERNAME> line in the
#    Caddyfile route for <SERVICE_FQDN> with $NEW_HASH in place of the old
#    <BCRYPT_HASH>.

# 3. Reload Caddy's config without dropping existing connections. Adjust
#    the config path to wherever Caddy's own install keeps its Caddyfile.
podman exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
```

If `caddy reload` is unavailable (Caddy container not running, or was not
installed with an admin endpoint), fall back to
`systemctl --user restart caddy`, which is a harder cut - active
connections through the proxy are dropped.

## Log rotation

`LogDriver=journald` (R10) is the default, and journald already rotates
its own logs - no action needed here in that case.

If this service was configured to write log files to disk instead (inside
`<HOME>/.<SERVICE_NAME>/data/` or `<HOME>/.<SERVICE_NAME>/config/`, per
R8 - never outside the service tree), rotate them with a user-level
`logrotate` config rather than a system one, since this is a rootless
install:

```conf
# <HOME>/.<SERVICE_NAME>/logrotate.conf
"<HOME>/.<SERVICE_NAME>/data/*.log" {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
```

```bash
# Run on a schedule (user cron or a systemd --user timer), or by hand:
logrotate --state "<HOME>/.<SERVICE_NAME>/logrotate.state" \
  "<HOME>/.<SERVICE_NAME>/logrotate.conf"
```
