#!/bin/bash

set -Eeuo pipefail

VERSION="${1:-}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LOG_DIR="$HOME/.local/state/app-deploy"
LOG_FILE="$LOG_DIR/deploy.log"

APP1_CONTAINER="application-stack-app1-1"
APP2_CONTAINER="application-stack-app2-1"
NGINX_CONTAINER="application-stack-nginx-1"
POSTGRES_CONTAINER="application-stack-postgres-1"

COMPOSE_PROJECT="application-stack"
COMPOSE_FILE="$REPO_DIR/docker/compose.yaml"
ENV_FILE="$REPO_DIR/.env"

APP1_IMAGE="app-v1:${VERSION}"
APP2_IMAGE="app-v2:${VERSION}"

MIN_FREE_GB=2
HEALTH_TIMEOUT=60

mkdir -p "$LOG_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1


log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}


fail() {
    log "ERROR: $*"
    exit 1
}


require_command() {

    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        fail "Required command not found: $command_name"
    fi
}


check_disk_space() {

    local available_kb
    local required_kb

    available_kb="$(
        df -Pk "$REPO_DIR" |
        awk 'NR==2 {print $4}'
    )"

    required_kb=$((MIN_FREE_GB * 1024 * 1024))

    log "Available disk space: $((available_kb / 1024 / 1024)) GB"
    log "Required minimum disk space: ${MIN_FREE_GB} GB"

    if (( available_kb < required_kb )); then
        fail "Not enough disk space"
    fi
}


check_configuration() {

    [[ -f "$ENV_FILE" ]] ||
        fail "Required configuration file missing: $ENV_FILE"

    [[ -f "$COMPOSE_FILE" ]] ||
        fail "Compose file missing: $COMPOSE_FILE"

    [[ -f "/opt/nginx/nginx.conf" ]] ||
        fail "Nginx configuration missing"

    [[ -d "/opt/nginx/tls" ]] ||
        fail "Nginx TLS directory missing"

    if ! grep -q '^POSTGRES_PASSWORD=' "$ENV_FILE"; then
        fail "POSTGRES_PASSWORD is missing from .env"
    fi

    log "Required configuration verified"
}


check_docker() {

    if ! sudo docker info >/dev/null 2>&1; then
        fail "Docker daemon is not available"
    fi

    log "Docker is available"
}


get_current_version() {

    local version_response

    version_response="$(
        curl -ksf \
            --max-time 5 \
            https://127.0.0.1:8443/version
    )" || fail "Unable to determine current application version"

    CURRENT_APP_VERSION="$(
        printf '%s\n' "$version_response" |
        sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
    )"

    [[ -n "$CURRENT_APP_VERSION" ]] ||
        fail "Current application version could not be parsed"

    log "Current application version: $CURRENT_APP_VERSION"
}


validate_target_version() {

    if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        fail "Invalid target version: $VERSION"
    fi

    if ! git -C "$REPO_DIR" \
        rev-parse --verify "refs/tags/$VERSION" >/dev/null 2>&1
    then
        fail "Git tag does not exist: $VERSION"
    fi

    log "Target version verified: $VERSION"

    if [[ "$CURRENT_APP_VERSION" == "$VERSION" ]]; then
        fail "Target version is already deployed: $VERSION"
    fi
}


validate_post_deploy_state() {

    local expected_version="$1"

    log "Checking container health"

    local app1_health
    local app2_health
    local nginx_health

    app1_health="$(
        sudo docker inspect \
            -f '{{.State.Health.Status}}' \
            "$APP1_CONTAINER" 2>/dev/null || true
    )"

    app2_health="$(
        sudo docker inspect \
            -f '{{.State.Health.Status}}' \
            "$APP2_CONTAINER" 2>/dev/null || true
    )"

    nginx_health="$(
        sudo docker inspect \
            -f '{{.State.Health.Status}}' \
            "$NGINX_CONTAINER" 2>/dev/null || true
    )"

    log "app1=$app1_health app2=$app2_health nginx=$nginx_health"

    [[ "$app1_health" == "healthy" ]] || return 1
    [[ "$app2_health" == "healthy" ]] || return 1
    [[ "$nginx_health" == "healthy" ]] || return 1


    log "Checking HTTP health"

    if ! curl -ksf \
        --max-time 5 \
        https://127.0.0.1:8443/health >/dev/null
    then
        return 1
    fi


    log "Checking application version"

    local deployed_version

    deployed_version="$(
        curl -ksf \
            --max-time 5 \
            https://127.0.0.1:8443/version
    )"

    if ! printf '%s\n' "$deployed_version" |
        grep -q "\"version\": \"$expected_version\""
    then
        return 1
    fi


    log "Checking database connectivity"

    if ! sudo docker exec \
        "$POSTGRES_CONTAINER" \
        pg_isready \
        -U appuser \
        -d appdb >/dev/null 2>&1
    then
        return 1
    fi


    log "Running database query"

    if ! sudo docker exec \
        "$POSTGRES_CONTAINER" \
        psql \
        -U appuser \
        -d appdb \
        -tAc "SELECT 1;" |
        grep -qx "1"
    then
        return 1
    fi

    log "All post-deploy checks passed"

    return 0
}


rollback() {

    log "Starting automatic rollback"

    if ! sudo docker image inspect "$CURRENT_APP1_IMAGE" >/dev/null 2>&1; then
        log "ERROR: Rollback image missing: $CURRENT_APP1_IMAGE"
        return 1
    fi

    if ! sudo docker image inspect "$CURRENT_APP2_IMAGE" >/dev/null 2>&1; then
        log "ERROR: Rollback image missing: $CURRENT_APP2_IMAGE"
        return 1
    fi


    if sudo env \
        APP1_IMAGE="$CURRENT_APP1_IMAGE" \
        APP2_IMAGE="$CURRENT_APP2_IMAGE" \
        APP_VERSION="$CURRENT_APP_VERSION" \
        docker compose \
        --env-file "$ENV_FILE" \
        -p "$COMPOSE_PROJECT" \
        -f "$COMPOSE_FILE" \
        up -d app1 app2
    then
        log "Application containers restored"
    else
        log "ERROR: Failed to restore application containers"
        return 1
    fi


    if ! sudo docker restart "$NGINX_CONTAINER"; then
        log "ERROR: Failed to restart Nginx during rollback"
        return 1
    fi

    sleep 5


    if ! validate_post_deploy_state "$CURRENT_APP_VERSION"; then
        log "ERROR: Rollback validation failed"
        return 1
    fi

    log "Rollback completed successfully"

    return 0
}


log "========================================"
log "Starting deployment"
log "Target version: $VERSION"
log "========================================"


# ============================================================
# PRE-DEPLOY CHECKS
# ============================================================

log "Running pre-deploy checks"

require_command git
require_command docker
require_command curl
require_command awk
require_command sed
require_command grep
require_command df
require_command tar
require_command tee

check_disk_space
check_configuration
check_docker
get_current_version
validate_target_version


# ============================================================
# CURRENT DEPLOYMENT STATE
# ============================================================

log "Saving current deployment state"

CURRENT_APP1_IMAGE="$(
    sudo docker inspect \
        -f '{{.Config.Image}}' \
        "$APP1_CONTAINER"
)"

CURRENT_APP2_IMAGE="$(
    sudo docker inspect \
        -f '{{.Config.Image}}' \
        "$APP2_CONTAINER"
)"

log "Current app1 image: $CURRENT_APP1_IMAGE"
log "Current app2 image: $CURRENT_APP2_IMAGE"

if ! sudo docker image inspect "$CURRENT_APP1_IMAGE" >/dev/null 2>&1; then
    fail "Current app1 rollback image is missing: $CURRENT_APP1_IMAGE"
fi

if ! sudo docker image inspect "$CURRENT_APP2_IMAGE" >/dev/null 2>&1; then
    fail "Current app2 rollback image is missing: $CURRENT_APP2_IMAGE"
fi


# ============================================================
# EXTRACT RELEASE SOURCE
# ============================================================

TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

log "Extracting release source from Git tag"

git -C "$REPO_DIR" archive "$VERSION" |
    tar -x -C "$TMP_DIR"


# ============================================================
# BUILD TARGET IMAGES
# ============================================================

log "Building $APP1_IMAGE"

if ! sudo docker build \
    -t "$APP1_IMAGE" \
    -f "$TMP_DIR/docker/app-v1/Dockerfile" \
    "$TMP_DIR/app-v1"
then
    fail "Failed to build $APP1_IMAGE"
fi


log "Building $APP2_IMAGE"

if ! sudo docker build \
    -t "$APP2_IMAGE" \
    -f "$TMP_DIR/docker/app-v2/Dockerfile" \
    "$TMP_DIR/app-v2"
then
    fail "Failed to build $APP2_IMAGE"
fi


# ============================================================
# VERIFY TARGET IMAGES
# ============================================================

log "Verifying target images"

sudo docker image inspect "$APP1_IMAGE" >/dev/null 2>&1 ||
    fail "Target image missing: $APP1_IMAGE"

sudo docker image inspect "$APP2_IMAGE" >/dev/null 2>&1 ||
    fail "Target image missing: $APP2_IMAGE"

log "Target images verified"


# ============================================================
# DEPLOY
# ============================================================

log "Deploying version $VERSION"

if ! sudo env \
    APP1_IMAGE="$APP1_IMAGE" \
    APP2_IMAGE="$APP2_IMAGE" \
    APP_VERSION="$VERSION" \
    docker compose \
    -p "$COMPOSE_PROJECT" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    up -d app1 app2
then

    log "Deployment command failed"

    rollback || true

    fail "Docker Compose deployment failed"
fi


# ============================================================
# WAIT FOR APPLICATION HEALTH
# ============================================================

log "Waiting for application containers to become healthy"

START_TIME="$(date +%s)"

while true; do

    APP1_HEALTH="$(
        sudo docker inspect \
            -f '{{.State.Health.Status}}' \
            "$APP1_CONTAINER" 2>/dev/null || true
    )"

    APP2_HEALTH="$(
        sudo docker inspect \
            -f '{{.State.Health.Status}}' \
            "$APP2_CONTAINER" 2>/dev/null || true
    )"

    log "app1=$APP1_HEALTH app2=$APP2_HEALTH"

    if [[ "$APP1_HEALTH" == "healthy" &&
          "$APP2_HEALTH" == "healthy" ]]; then
        break
    fi

    NOW="$(date +%s)"

    if (( NOW - START_TIME >= HEALTH_TIMEOUT )); then

        log "Application health timeout"

        rollback || true

        fail "Health check timeout"
    fi

    sleep 2
done


# ============================================================
# REFRESH NGINX
# ============================================================

log "Refreshing Nginx"

if ! sudo docker restart "$NGINX_CONTAINER"; then

    log "Nginx restart failed"

    rollback || true

    fail "Nginx restart failed"
fi

sleep 5


# ============================================================
# POST-DEPLOY VALIDATION
# ============================================================

log "Running post-deploy validation"

if ! validate_post_deploy_state "$VERSION"; then

    log "Post-deploy validation failed"

    rollback || true

    fail "Deployment validation failed"
fi


# ============================================================
# SUCCESS
# ============================================================

log "========================================"
log "Deployment completed successfully"
log "Application version: $VERSION"
log "========================================"

exit 0
