# nayrosk-skills-marketplace

A Claude Code plugin marketplace.

## Use it

```
/plugin marketplace add nayrosk/nayrosk-skills-marketplace
```

Then install any plugin below.

## Plugins

### podman-quadlet-service

```
/plugin install podman-quadlet-service@nayrosk-skills-marketplace
```

Installs a containerized service as a rootless Podman Quadlet systemd unit,
enforcing pinned image versions, podman secrets, healthchecks, bind mounts,
resource limits and reverse-proxy placement, and generating install, update,
rotation and uninstall runbooks. Ships `validate.sh`, a conformance linter
that works standalone, without Claude.

Requires Podman >= 5.0, rootless subuid/subgid, a systemd user session with
linger enabled, and `bash`.

See [plugins/podman-quadlet-service/README.md](plugins/podman-quadlet-service/README.md).

## License

MIT. See `LICENSE`.
