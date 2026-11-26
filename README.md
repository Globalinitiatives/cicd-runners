# cicd-runners

A containerized, Supervisor-managed runner host. Each runner is a trusted, long-lived `/opt/cicd/<runner-name>/run.sh` process. `add-runner` creates its Supervisor program and reloads it without restarting the container.

## Security boundary

This image mounts `/var/run/docker.sock`. Anyone who can change a runner's `run.sh`, execute commands in this container, or access the Docker socket can control Docker on the host and should therefore be treated as host-privileged. Do not use this service for untrusted pull requests, arbitrary customer code, or multi-tenant workloads.

The runner user is non-root and no longer has passwordless `sudo`. Docker socket access is explicit through `DOCKER_GID`.

## Start

Set `DOCKER_GID` to the numeric group that owns your host Docker socket:

```bash
stat -c '%g' /var/run/docker.sock  # Linux
stat -f '%g' /var/run/docker.sock  # macOS/BSD
cp .env.example .env
# Edit .env and set DOCKER_GID to the value above.
```

Then build and start the service:

```bash
docker compose up --build -d
docker compose ps
```

`docker-compose.yml` builds `dockerfile`, creates the matching socket group in the image, and adds that numeric group to the running process. The only persistent path is `/opt/cicd`; Supervisor's immutable configuration stays in `/etc/cicd`, so it remains available across volume reuse and image upgrades.

## Deploy with Portainer

For a Portainer **standalone Docker** environment, create a new Stack and paste the contents of `portainer-stack.yml` into the Web editor. In the Stack's environment-variable section, enter the values from `stack.env.example` manually:

- `DOCKER_GID`: the numeric owner group of `/var/run/docker.sock` on the Docker host. Run `stat -c '%g' /var/run/docker.sock` on Linux to obtain it.
- `CICD_IMAGE_TAG`: `latest` tracks images published from `release`; use a `sha-...` tag to pin a deployment.

The stack pulls `ghcr.io/globalinitiatives/cicd-runners` and persists runner data in the `cicd-data` volume. If the GHCR package is private, configure Portainer's GitHub Container Registry credentials before deploying.

## Register a runner

Create a long-running script in the named volume, then register it:

```bash
docker compose exec cicd bash -lc '
  mkdir -p /opt/cicd/my-runner
  cat > /opt/cicd/my-runner/run.sh <<"EOF"
#!/usr/bin/env bash
while true; do
  echo "runner heartbeat"
  sleep 60
done
EOF
  chmod +x /opt/cicd/my-runner/run.sh
  add-runner my-runner
'
```

Inspect or manage it with:

```bash
docker compose exec cicd supervisorctl -c /etc/cicd/supervisord.conf status my-runner
docker compose exec cicd supervisorctl -c /etc/cicd/supervisord.conf stop my-runner
docker compose exec cicd tail -f /opt/cicd/supervisor/logs/my-runner.log
```

Runner names may contain only letters, numbers, `_`, and `-`. `add-runner` rejects duplicate registrations and exits non-zero if Supervisor cannot load the new configuration; it removes the failed configuration before exiting.

## Layout

```
/opt/cicd/
├── projects/
├── runners/
├── <runner-name>/run.sh
└── supervisor/
    ├── conf.d/<runner-name>.ini
    └── logs/<runner-name>.log
```

The service healthcheck verifies that Supervisor's control socket is responding. The GitHub Actions workflow validates Compose rendering, builds the image, starts Supervisor, and registers a smoke runner.

## Troubleshooting

- **Docker permission denied:** confirm `DOCKER_GID` matches the group ID of `/var/run/docker.sock`, then recreate the container with `docker compose up --build -d`.
- **Runner fails repeatedly:** inspect `supervisor/logs/<runner-name>-error.log`. `autorestart=true` is intended for long-running runner processes.
- **Runner already registered:** stop it, delete `/opt/cicd/supervisor/conf.d/<name>.ini`, then run `supervisorctl -c /etc/cicd/supervisord.conf reread` and `update` before registering it again.
