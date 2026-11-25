FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

ARG DOCKER_GID=987

# --------------------------------------------------
# System packages
# --------------------------------------------------

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
    sudo \
    openssh-client \
    build-essential \
    docker.io \
    supervisor \
    gnupg \
    lsb-release \
    software-properties-common \
    python3 \
    python3-pip \
    python3-venv \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# --------------------------------------------------
# CI/CD user and Docker socket group
# --------------------------------------------------

RUN set -eu \
    && if ! id cicd >/dev/null 2>&1; then \
        echo "[dockerfile] Creating 'cicd' user..."; \
        useradd -m -s /bin/bash cicd; \
    else \
        echo "[dockerfile] 'cicd' user already exists; skipping."; \
    fi \
    && echo "[dockerfile] Resolving Docker socket group..." \
    && if getent group docker >/dev/null 2>&1; then \
        DOCKER_GROUP_NAME="docker"; \
        DOCKER_GID="$(getent group docker | cut -d: -f3)"; \
        echo "[dockerfile] Found existing 'docker' group, GID ${DOCKER_GID}."; \
    else \
        DOCKER_GROUP_NAME="docker-host"; \
        echo "[dockerfile] No 'docker' group; will create '${DOCKER_GROUP_NAME}' at GID ${DOCKER_GID}."; \
    fi \
    && if ! awk -F: -v gid="$DOCKER_GID" '$3 == gid { found=1 } END { exit found ? 0 : 1 }' /etc/group; then \
        echo "[dockerfile] Group '${DOCKER_GROUP_NAME}' (GID ${DOCKER_GID}) missing; creating..."; \
        groupadd -g "${DOCKER_GID}" "${DOCKER_GROUP_NAME}"; \
    else \
        DOCKER_GROUP="$(getent group "${DOCKER_GID}" | cut -d: -f1)"; \
        echo "[dockerfile] Group '${DOCKER_GROUP}' (GID ${DOCKER_GID}) already present."; \
    fi \
    && usermod -aG "${DOCKER_GROUP}" cicd \
    && usermod -aG sudo cicd \
    && echo "[dockerfile] Granting 'cicd' passwordless sudo..." \
    && echo "cicd ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/cicd \
    && chmod 0440 /etc/sudoers.d/cicd \
    && echo "[dockerfile] Done: user 'cicd' has passwordless sudo; socket group '${DOCKER_GROUP_NAME}' (GID ${DOCKER_GID})."

# --------------------------------------------------
# CI/CD directory structure
# --------------------------------------------------

RUN mkdir -p \
    /opt/cicd/runners \
    /opt/cicd/projects \
    /opt/cicd/supervisor/conf.d \
    /opt/cicd/supervisor/logs \
    && chown -R cicd:cicd /opt/cicd

WORKDIR /opt/cicd

# --------------------------------------------------
# Supervisor configuration
# --------------------------------------------------

COPY supervisord.conf /opt/cicd/supervisord.conf

# --------------------------------------------------
# Runner registration utility
# --------------------------------------------------

RUN cat > /usr/local/bin/add-runner <<'EOF'
#!/usr/bin/env bash
set -u

RUNNER_NAME="${1:-}"

log() { echo "[add-runner] $*"; }

if [[ -z "$RUNNER_NAME" ]]; then
    log "ERROR: no runner name supplied."
    echo "Usage: add-runner <runner-name>"
    exit 1
fi

if [[ ! "$RUNNER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log "ERROR: invalid runner name '${RUNNER_NAME}'."
    echo "Allowed: letters, digits, '_', '-' only."
    exit 1
fi

RUNNER_DIR="/opt/cicd/${RUNNER_NAME}"
SUPERVISOR_DIR="/opt/cicd/supervisor"
CONFIG_FILE="${SUPERVISOR_DIR}/conf.d/${RUNNER_NAME}.ini"

if [[ ! -d "${RUNNER_DIR}" ]]; then
    log "ERROR: runner directory not found: ${RUNNER_DIR}"
    echo "Create it first, e.g.: mkdir -p ${RUNNER_DIR}"
    exit 1
fi

if [[ ! -f "${RUNNER_DIR}/run.sh" ]]; then
    log "ERROR: runner script not found: ${RUNNER_DIR}/run.sh"
    exit 1
fi

if [[ ! -x "${RUNNER_DIR}/run.sh" ]]; then
    log "notice: runner script is not executable; chmod +x it"
    chmod +x "${RUNNER_DIR}/run.sh"
fi

if [[ -f "$CONFIG_FILE" ]]; then
    log "ERROR: runner already registered: ${RUNNER_NAME}"
    exit 1
fi

log "Registering runner '${RUNNER_NAME}' (directory: ${RUNNER_DIR})"
log "Writing supervisor config: ${CONFIG_FILE}"

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

if [[ -f "$CONFIG_FILE" ]]; then
    log "Config written:"
    sed -n '1,/^\[/p' "$CONFIG_FILE"
else
    log "ERROR: failed to write config: ${CONFIG_FILE}"
    exit 1
fi

log "Re-reading supervisor configurations..."
supervisorctl -c /opt/cicd/supervisord.conf reread
RC=$?
if [[ $RC -ne 0 ]]; then
    log "notice: supervisorctl -c /opt/cicd/supervisord.conf reread exited ${RC}"
fi

log "Updating supervisor state..."
supervisorctl -c /opt/cicd/supervisord.conf update
RC=$?
if [[ $RC -ne 0 ]]; then
    log "notice: supervisorctl -c /opt/cicd/supervisord.conf update exited ${RC}"
fi

if [[ -f "$CONFIG_FILE" ]]; then
    log "Runner '${RUNNER_NAME}' registered successfully."
    log "Start it:   supervisorctl start ${RUNNER_NAME}"
    log "Stop it:    supervisorctl stop ${RUNNER_NAME}"
    log "Logs:       tail -f ${SUPERVISOR_DIR}/logs/${RUNNER_NAME}.log"
else
    log "ERROR: runner '${RUNNER_NAME}' not registered (config missing)."
    exit 1
fi
EOF

RUN chmod +x /usr/local/bin/add-runner \
    && chown -R cicd:cicd /opt/cicd

# --------------------------------------------------
# Default user
# --------------------------------------------------

USER cicd

WORKDIR /opt/cicd

# --------------------------------------------------
# Start Supervisor
# --------------------------------------------------

CMD ["/usr/bin/supervisord", "-n", "-c", "/opt/cicd/supervisord.conf"]
