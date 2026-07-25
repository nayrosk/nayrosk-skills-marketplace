# <SERVICE_NAME> - Uninstall

Complete removal, ordered so nothing is orphaned: stop the service before
removing its unit, remove the unit before reloading systemd, and remove the
secret and image only after the unit that used them is gone.

```bash
systemctl --user stop <SERVICE_NAME>
systemctl --user disable <SERVICE_NAME> 2>/dev/null || true
rm "${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/<SERVICE_NAME>.container"
systemctl --user daemon-reload
podman secret rm <SECRET_NAME>
podman rmi <REGISTRY>/<IMAGE>:<TAG>
```

If this service was installed with the `internal` network placement
(`references/networking.md`), a dedicated `<SERVICE_NAME>.network` unit
also exists - remove it too, and only **after** the container above is
already gone. The container's own generated unit removes the container on
stop (`podman rm`), so stopping it first guarantees nothing is still
attached to the network when the network is torn down next; stopping the
network first would either fail (network still in use) or, worse, delete
a network a running container still depends on:

```bash
systemctl --user stop <SERVICE_NAME>-network 2>/dev/null || true
systemctl --user disable <SERVICE_NAME>-network 2>/dev/null || true
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/<SERVICE_NAME>.network"
systemctl --user daemon-reload
```

`service.network`'s `NetworkDeleteOnStop=true` makes the `stop` above
remove the actual Podman network via a generated `ExecStopPost` - a
`.network` unit only *creates* the network on start, it does not delete it
on stop by default, so skipping this step (or reordering it before the
container is gone) leaves a stranded network behind. Confirm it is
actually gone:

```bash
podman network ls --format '{{.Name}}' | grep -qx <SERVICE_NAME> && echo "STILL PRESENT" || echo "network removed"
```

If this service was routed through a reverse proxy, remove its route from
the proxy's own configuration and reload the proxy:

```bash
# Remove the <SERVICE_FQDN> block from the reverse proxy's config, then
# reload it - see rotate.md's "Reverse proxy basic-auth rotation" section
# for the reload command.
```

Data is kept by default. `<HOME>/.<SERVICE_NAME>/` (`.env`, `data/`,
`config/`, `repo/`, `docs/`) is left in place after the commands above:
uninstall must never destroy data as a side effect of removing the
service. Delete it only as a separate, deliberate act:

```bash
# Data deletion - deliberate only, never run as part of a routine uninstall:
#   rm -rf "<HOME>/.<SERVICE_NAME>"
```
