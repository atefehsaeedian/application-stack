#!/bin/bash

set -Eeuo pipefail

VERSION="${1:-}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOG_DIR="$HOME/.local/state/app-deploy"
LOG_FILE="$LOG_DIR/deploy.log"

APP1_CONTAINER="application-stack-app1-1"
APP2_CONTAINER="application-stack-app2-1"
NGINX_CONTAINER="application-stack-nginx-1"

APP1_IMAGE="app-v1:${VERSION}"
APP2_IMAGE="app-v2:${VERSION}"

mkdir -p "$LOG_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

log "Starting deployment"

# 1. Validate version format
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "Invalid version: $VERSION"
fi

# 2. Verify Git tag exists
if ! git -C "$REPO_DIR" rev-parse --verify "refs/tags/$VERSION" >/dev/null 2>&1; then
    fail "Git tag does not exist: $VERSION"
fi

log "Git tag verified: $VERSION"

# 3. Extract exact source from Git tag
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

log "Extracting release source"

git -C "$REPO_DIR" archive "$VERSION" | tar -x -C "$TMP_DIR"

# 4. Save current deployment state for rollback
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

CURRENT_APP_VERSION="$(
    sudo docker inspect "$APP1_CONTAINER" \
        --format '{{range .Config.Env}}{{println .}}{{end}}' |
        awk -F= '$1=="APP_VERSION"{print $2; exit}'
)"

log "Current app1 image: $CURRENT_APP1_IMAGE"
log "Current app2 image: $CURRENT_APP2_IMAGE"
log "Current application version: $CURRENT_APP_VERSION"

# 5. Rollback function
rollback() {

    log "Deployment failed. Starting rollback..."

    sudo env \
        APP1_IMAGE="$CURRENT_APP1_IMAGE" \
        APP2_IMAGE="$CURRENT_APP2_IMAGE" \
        APP_VERSION="$CURRENT_APP_VERSION" \
        docker compose \
        --env-file "$REPO_DIR/.env" \
        -f "$REPO_DIR/compose.yaml" \
        up -d app1 app2

    sudo docker restart "$NGINX_CONTAINER"

    log "Rollback completed"
}

# 6. Build release-specific images
log "Building $APP1_IMAGE"

sudo docker build \
    -t "$APP1_IMAGE" \
    "$TMP_DIR/app-v1"

log "Building $APP2_IMAGE"

sudo docker build \
    -t "$APP2_IMAGE" \
    "$TMP_DIR/app-v2"

# 7. Deploy application containers
log "Deploying version $VERSION"

if ! sudo env \
    APP1_IMAGE="$APP1_IMAGE" \
    APP2_IMAGE="$APP2_IMAGE" \
    APP_VERSION="$VERSION" \
    docker compose \
    --env-file "$REPO_DIR/.env" \
    -f "$REPO_DIR/compose.yaml" \
    up -d app1 app2
then
    rollback
    fail "Docker Compose deployment failed"
fi

# 8. Wait for application health
log "Waiting for application health"

HEALTH_TIMEOUT=60
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

    if [[ "$APP1_HEALTH" == "healthy" && "$APP2_HEALTH" == "healthy" ]]; then
        break
    fi

    NOW="$(date +%s)"

    if (( NOW - START_TIME >= HEALTH_TIMEOUT )); then
        rollback
        fail "Health check timeout"
    fi

    sleep 2
done

log "Both application containers are healthy"

# 9. Refresh Nginx after backend containers are recreated
log "Refreshing Nginx"

if ! sudo docker restart "$NGINX_CONTAINER"; then
    rollback
    fail "Nginx restart failed"
fi

sleep 2

# 10. Verify externally visible version
log "Verifying deployed version"

if ! curl -ksf --max-time 5 \
    https://127.0.0.1:8443/version |
    grep -q "\"version\": \"$VERSION\""
then
    rollback
    fail "Version verification failed"
fi

log "Version verification successful: $VERSION"

log "Deployment completed successfully"

exit 0
