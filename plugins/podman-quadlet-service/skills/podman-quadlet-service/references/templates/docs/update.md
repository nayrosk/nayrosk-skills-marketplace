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

# 6. Reload and restart.
#    daemon: restart directly.
#    on-demand / socket: a bare restart is stopped again at once by
#    StopWhenUnneeded=yes. Hold the unit with a scope for steps 6-7, in
#    another shell:
#      systemd-run --user --scope -p Wants=<SERVICE_NAME>.service \
#        -p After=<SERVICE_NAME>.service -- sleep 600
#    job: nothing to restart; `systemctl --user start <SERVICE_NAME>` runs
#    it once with the new image and must end with Result=success.
systemctl --user daemon-reload
systemctl --user restart <SERVICE_NAME>

# 7. Verify health. `podman healthcheck run` executes the check command
#    immediately - it does NOT wait out HealthStartPeriod= the way the
#    container's own background timer does, so a service that is merely
#    slow to start can report unhealthy on the very first call right after
#    a restart even though it would pass a few seconds later. Poll instead
#    of probing once: at most 20 times, 5s apart, the same bound the
#    install workflow uses - and fail loudly with the service log on
#    timeout rather than silently declaring the update done.
healthy=0
for i in $(seq 1 20); do
  podman healthcheck run <SERVICE_NAME> >/dev/null 2>&1 && { healthy=1; break; }
  sleep 5
done
if [ "$healthy" -eq 1 ]; then
  echo "healthy"
else
  echo "TIMEOUT: <SERVICE_NAME> did not become healthy after the update" >&2
  # NOT `podman logs <SERVICE_NAME>`: the Quadlet-generated ExecStart runs
  # `podman run --rm` and ExecStopPost runs `podman rm -f`, so a container
  # that failed to start no longer exists and `podman logs` prints only
  # "no such container" - precisely when its output is needed.
  journalctl --user -u <SERVICE_NAME> --no-pager -n 100
  echo "See the Rollback section below." >&2
fi
systemctl --user status <SERVICE_NAME> --no-pager
podman inspect <SERVICE_NAME> --format '{{.Config.Image}} {{.State.Health.Status}}'
```

After a healthy result, repeat the R12 stop test - a new image can change
the entrypoint and silently bring back SIGKILL-on-stop:

```bash
systemctl --user stop <SERVICE_NAME>
systemctl --user show <SERVICE_NAME> -p Result,ExecMainStatus   # want Result=success
```

Re-check every `# HARDENING-EXCEPTION:` in the unit against the new
version too: drop the ones that are no longer needed.

## Rollback

If the service does not recover, restore the previous `Image=` line
recorded in step 1 and repeat steps 4-7 with it instead of `<NEW_TAG>` /
`<NEW_DIGEST>`. The image for the previous version is still present
locally (it was never removed), so step 3's pull is unnecessary on
rollback.
