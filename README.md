# cicd-runners

A containerized, **supervisor-managed CI/CD runner farm**. Drop a per-job `run.sh` into a runner directory and supervisor keeps it alive, restarts it on failure, and logs its output — all inside one reusable container image.

Two ways to run it:

1. **`docker compose up` (recommended)** — a single service with the image built from `dockerfile`, a `DOCKER_GID` env var, the docker socket mounted, and an inline bootstrap that sets up the `cicd` user + socket group.
2. **`docker run` with `add-runner`** — build the image, run it, then register runners with the bundled `add-runner` helper.

---

## Files

| File | Purpose |
| --- | --- |
| `dockerfile` | Ubuntu 24.04 image: toolchain, `cicd` user, socket-group setup, `add-runner` helper, supervisor entrypoint. |
| `docker-compose.yml` | Single-service stack: builds the image, passes `DOCKER_GID`, mounts the docker socket, starts the container. |
| `supervisord.conf` | Supervisor config: unix socket, `cicd` user, and `[include] conf.d/*.ini` for per-runner program blocks. |
| `.env.example` | Template for `DOCKER_GID` (copy to `.env`, see below). |
| `README.md` | This file. |

---

## Concept

A **runner** is a directory `/opt/cicd/<runner-name>/` containing a `run.sh` script. `add-runner <runner-name>` writes a supervisor `conf.d/<runner-name>.ini` program block for it, then re-reads and updates supervisor so the job is supervised and restartable.

Supervisor program block (generically):

```ini
[program:<runner-name>]
directory=/opt/cicd/<runner-name>
command=/opt/cicd/<runner-name>/run.sh
user=cicd
autostart=true
autorestart=true
startsecs=10
stopasgroup=true
killasgroup=true
stdout_logfile=/opt/cicd/supervisor/logs/<runner-name>.log
stderr_logfile=/opt/cicd/supervisor/logs/<runner-name>-error.log
```

---

## Quick start (docker-compose)

### 1. Build the image

```bash
docker compose build
```

### 2. Set `DOCKER_GID`

docker-compose auto-loads the `.env` file in this directory. Copy the template and set the socket group ID:

```bash
cp .env.example .env
```

`DOCKER_GID` must match the group ID of the docker socket on your host. Find it with:

```bash
stat -c '%g' /var/run/docker.sock     # Linux
stat -f '%g' /var/run/docker.sock     # macOS/BSD
```

`docker-compose.yml` also defaults to `999` if `DOCKER_GID` is unset, and `dockerfile` defaults to `987` — change the value in `.env` to match your host so the container's socket group lines up with the mounted socket.

### 3. Start the stack

```bash
docker compose up -d
docker compose ps
```

The container runs a bootstrap that:

- ensures the `docker.io` toolchain is installed,
- creates the `cicd` user (uid 1000) if missing,
- creates the `docker-host` group at `DOCKER_GID` if missing,
- adds `cicd` to it, so it can read the mounted docker socket,
- keeps the container alive with `sleep infinity`.

### 4. Register a runner

```bash
mkdir -p /opt/cicd/my-runner        # on the host, via a volume
cat > /opt/cicd/my-runner/run.sh <<'EOF'
#!/usr/bin/env bash
echo "hello from my-runner"
EOF
chmod +x /opt/cicd/my-runner/run.sh
docker compose exec cicd add-runner my-runner
```

Supervisor re-reads and adds the runner. Manage it with `supervisorctl`:

```bash
docker compose exec cicd supervisorctl status my-runner
docker compose exec cicd supervisorctl start my-runner
docker compose exec cicd supervisorctl stop my-runner
docker compose exec cicd tail -f /opt/cicd/supervisor/logs/my-runner.log
```

---

## Quick start (docker run + add-runner)

```bash
docker build -t cicd-environment .
docker run -it --rm \
  --name cicd \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v cicd-data:/opt/cicd \
  -w /opt/cicd \
  cicd-environment
```

Inside the container, drop a runner, then run:

```bash
mkdir -p /opt/cicd/my-runner
cat > /opt/cicd/my-runner/run.sh <<'EOF'
#!/usr/bin/env bash
echo "hello from my-runner"
EOF
chmod +x /opt/cicd/my-runner/run.sh
add-runner my-runner
supervisorctl start my-runner
```

---

## Environment variables

| Variable | Default | Where used | Notes |
| --- | --- | --- | --- |
| `DOCKER_GID` | `999` (compose) / `987` (dockerfile) | `docker-compose.yml`, `dockerfile` | Group ID to match the docker socket. Set it in `.env`. |
| `DEBIAN_FRONTEND` | `noninteractive` | `dockerfile` | Keeps apt non-interactive. |

`DOCKER_GID` is **only** honoured by docker-compose at runtime and the Dockerfile build. Keying it to `.env` (and not hardcoding it) keeps the image reusable across hosts with different docker socket GIDs.

---

## Directory layout

```
/opt/cicd
├── runners/          # (created by add-runner when used via docker run)
├── projects/         # workspace volume for jobs
├── supervisor/
│   ├── supervisor.sock
│   ├── supervisord.pid
│   ├── conf.d/       # <runner-name>.ini program blocks
│   └── logs/         # <runner-name>.log and <runner-name>-error.log
└── <runner-name>/    # per-runner dir holding run.sh
```

---

## Runner lifecycle

```
1. mkdir /opt/cicd/<name> && write run.sh
2. add-runner <name>          -> writes conf.d/<name>.ini
3. supervisorctl reread       -> pick up the new program
4. supervisorctl start <name> -> run it
5. supervisorctl stop <name>  -> stop it (process group is killed)
6. logs land in supervisor/logs/<name>.log
```

`add-runner` validates the runner directory, the `run.sh` script, and whether it is already registered, and prints verbose `[add-runner]` lines for every step.

---

## Troubleshooting

- **Runner doesn't start** — run `supervisorctl status <name>` and read the logs in `supervisor/logs/`. A `run.sh` that exits is restarted by `autorestart=true`, so check for loop failures.
- **Socket group mismatch** — the container cannot reach the docker daemon with `Got permission denied` or similar. Confirm `DOCKER_GID` matches the host socket group (`stat -c '%g' /var/run/docker.sock`) and the socket volume is mounted.
- **Runner already registered** — `add-runner` refuses to overwrite. Delete `/opt/cicd/supervisor/conf.d/<name>.ini` (or `supervisorctl remove <name>`, then `reread`) to re-register.
- **Build fails on `groupadd`** — the GID is already taken inside the image. Pass a different `DOCKER_GID` build-arg or match your host's socket group.
- **`.env` not loaded** — docker-compose loads `.env` from the project directory. Confirm it exists and contains `DOCKER_GID=...`.

---

## Notes

- `supervisord.conf` runs `nodaemon=true` and as `user=cicd`, so the container stays in the foreground and supervisor is PID 1'd via the dockerfile `CMD`.
- The dockerfile's `add-runner` helper is self-contained at `/usr/local/bin/add-runner`; it does not depend on docker-compose.
