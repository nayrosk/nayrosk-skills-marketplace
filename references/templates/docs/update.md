# <SERVICE_NAME> - Update

Every step is ordered and reversible: back up before pulling, validate
before restarting, and roll back to the recorded version if the new one
does not come back healthy.

```bash
# 1. Record the current pinned version, for rollback
grep '^Image=' "${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/<SERVICE_NAME>.container"

# 2. Back up persistent data
tar -C "<HOME>/.<SERVICE_NAME>" -czf \
    "<HOME>/.<SERVICE_NAME>/data-$(date +%Y%m%d-%H%M%S).tar.gz" data

# 3. Pull the new pinned version by digest
podman pull <REGISTRY>/<IMAGE>:<NEW_TAG>@sha256:<NEW_DIGEST>

# 4. Update Image= in the unit to the new tag and digest
sed -i "s|^Image=.*|Image=<REGISTRY>/<IMAGE>:<NEW_TAG>@sha256:<NEW_DIGEST>|" \
  "${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/<SERVICE_NAME>.container"

# 5. Re-validate before restarting. Exit 0 prints "conformant" and it is
#    safe to continue. Exit 1 prints one "R<n>: ..." or "LINT: ..." line per
#    problem - stop here, do not restart, and revert the sed above using the
#    Image= line recorded in step 1.
<SKILL_PATH>/scripts/validate.sh \
  "${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/<SERVICE_NAME>.container"

# 6. Reload and restart
systemctl --user daemon-reload
systemctl --user restart <SERVICE_NAME>

# 7. Verify health. `podman healthcheck run` executes the check command
#    immediately - it does NOT wait out HealthStartPeriod= the way the
#    container's own background timer does, so a service that is merely
#    slow to start can report unhealthy on the very first call right after
#    a restart even though it would pass a few seconds later. Give it a
#    moment, then check both the immediate probe and the aggregated status:
sleep 5
podman healthcheck run <SERVICE_NAME> && echo "healthy"
systemctl --user status <SERVICE_NAME> --no-pager
podman inspect <SERVICE_NAME> --format '{{.Config.Image}} {{.State.Health.Status}}'
```

## Rollback

If the service does not recover, restore the previous `Image=` line
recorded in step 1 and repeat steps 4-7 with it instead of `<NEW_TAG>` /
`<NEW_DIGEST>`. The image for the previous version is still present
locally (it was never removed), so step 3's pull is unnecessary on
rollback.
