FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Set this to the numeric group that owns the host Docker socket. Compose passes
# the same value both here and as a supplemental runtime group.
ARG DOCKER_GID=999

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    git \
    jq \
    unzip \
    zip \
    tmux \
    nano \
    vim \
    openssh-client \
    build-essential \
    docker.io \
    supervisor \
    python3 \
    python3-pip \
    python3-venv \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# Runner scripts are deliberately not root. Docker-socket access is granted by
# an explicit numeric group rather than by passwordless sudo.
RUN set -eu \
    && useradd --create-home --shell /bin/bash cicd \
    && DOCKER_GROUP="$(getent group "${DOCKER_GID}" | cut -d: -f1 || true)" \
    && if [ -z "${DOCKER_GROUP}" ]; then \
        DOCKER_GROUP=docker-host; \
        groupadd --gid "${DOCKER_GID}" "${DOCKER_GROUP}"; \
    fi \
    && usermod -aG "${DOCKER_GROUP}" cicd

RUN mkdir -p \
    /opt/cicd/runners \
    /opt/cicd/projects \
    /opt/cicd/supervisor/conf.d \
    /opt/cicd/supervisor/logs \
    && chown -R cicd:cicd /opt/cicd

# Keep immutable configuration outside the data volume so image upgrades cannot
# be masked by /opt/cicd's persistent named volume.
COPY supervisord.conf /etc/cicd/supervisord.conf

RUN <<'EOF' cat > /usr/local/bin/add-runner
#!/usr/bin/env bash
set -euo pipefail

RUNNER_NAME="${1:-}"

log() { echo "[add-runner] $*"; }
fail() { log "ERROR: $*"; exit 1; }

if [[ -z "$RUNNER_NAME" ]]; then
    echo "Usage: add-runner <runner-name>"
    fail "no runner name supplied."
fi

if [[ ! "$RUNNER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    fail "invalid runner name '${RUNNER_NAME}' (allowed: letters, digits, '_' and '-')."
fi

RUNNER_DIR="/opt/cicd/${RUNNER_NAME}"
SUPERVISOR_DIR="/opt/cicd/supervisor"
SUPERVISOR_CONFIG="/etc/cicd/supervisord.conf"
CONFIG_FILE="${SUPERVISOR_DIR}/conf.d/${RUNNER_NAME}.ini"

[[ -d "$RUNNER_DIR" ]] || fail "runner directory not found: ${RUNNER_DIR}"
[[ -f "${RUNNER_DIR}/run.sh" ]] || fail "runner script not found: ${RUNNER_DIR}/run.sh"

if [[ ! -x "${RUNNER_DIR}/run.sh" ]]; then
    log "runner script is not executable; making it executable."
    chmod +x "${RUNNER_DIR}/run.sh"
fi

[[ ! -e "$CONFIG_FILE" ]] || fail "runner already registered: ${RUNNER_NAME}"

cat > "$CONFIG_FILE" <<CONFIG
[program:${RUNNER_NAME}]
directory=${RUNNER_DIR}
command=${RUNNER_DIR}/run.sh
user=cicd
autostart=true
autorestart=true
startsecs=10
stopasgroup=true
killasgroup=true
stdout_logfile=${SUPERVISOR_DIR}/logs/${RUNNER_NAME}.log
stderr_logfile=${SUPERVISOR_DIR}/logs/${RUNNER_NAME}-error.log
CONFIG

rollback() {
    rm -f "$CONFIG_FILE"
    supervisorctl -c "$SUPERVISOR_CONFIG" reread >/dev/null 2>&1 || true
    supervisorctl -c "$SUPERVISOR_CONFIG" update >/dev/null 2>&1 || true
}

log "Re-reading supervisor configurations..."
if ! supervisorctl -c "$SUPERVISOR_CONFIG" reread; then
    rollback
    fail "Supervisor rejected the new runner configuration."
fi

log "Updating supervisor state..."
if ! supervisorctl -c "$SUPERVISOR_CONFIG" update; then
    rollback
    fail "Supervisor could not apply the new runner configuration."
fi

log "Runner '${RUNNER_NAME}' registered successfully."
supervisorctl -c "$SUPERVISOR_CONFIG" status "$RUNNER_NAME" || true
EOF

RUN chmod 0755 /usr/local/bin/add-runner

USER cicd
WORKDIR /opt/cicd

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD /usr/bin/supervisorctl -c /etc/cicd/supervisord.conf status >/dev/null || exit 1

CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/cicd/supervisord.conf"]
