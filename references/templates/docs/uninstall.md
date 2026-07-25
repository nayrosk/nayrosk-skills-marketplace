# <SERVICE_NAME> - Uninstall

Complete removal, ordered so nothing is orphaned: stop the service before
removing its unit, remove the unit before reloading systemd, and remove the
secret and image only after the unit that used them is gone.

```bash
systemctl --user stop <SERVICE_NAME>
systemctl --user disable <SERVICE_NAME> 2>/dev/null || true
rm "${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/<SERVICE_NAME>.container"
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/<SERVICE_NAME>.network"
systemctl --user daemon-reload
podman secret rm <SECRET_NAME>
podman rmi <REGISTRY>/<IMAGE>:<TAG>
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
