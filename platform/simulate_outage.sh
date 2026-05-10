#!/bin/bash
set -euo pipefail

# Usage: ./platform/simulate_outage.sh --env ENV_ID --mode {crash|pause|network|recover|stress}

ENV_ID=""
MODE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env) ENV_ID="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$ENV_ID" ]] && { echo "Error: --env required"; exit 1; }
[[ -z "$MODE" ]] && { echo "Error: --mode required"; exit 1; }

STATE_FILE="envs/${ENV_ID}.json"
[[ -f "$STATE_FILE" ]] || { echo "Error: Environment not found: $ENV_ID"; exit 1; }

CONTAINER_NAME=$(jq -r '.container' "$STATE_FILE")
DOCKER_NETWORK=$(jq -r '.network' "$STATE_FILE")

# Safety: never target system containers
if [[ "$CONTAINER_NAME" =~ ^(nginx|daemon|api)$ ]]; then
    echo "Error: Cannot simulate outage on system container: $CONTAINER_NAME"
    exit 1
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Simulating $MODE on $CONTAINER_NAME"

case "$MODE" in
    crash)
        echo "  → Killing container"
        docker kill "$CONTAINER_NAME" 2>/dev/null || true
        sleep 5
        echo "  ✓ Container crashed"
        ;;
    
    pause)
        if [[ $(docker inspect -f '{{.State.Paused}}' "$CONTAINER_NAME") == "true" ]]; then
            echo "  → Container already paused, resuming..."
            docker unpause "$CONTAINER_NAME"
            echo "  ✓ Container resumed"
        else
            echo "  → Pausing container"
            docker pause "$CONTAINER_NAME"
            echo "  ✓ Container paused"
        fi
        ;;
    
    network)
        echo "  → Disconnecting from network"
        docker network disconnect -f "$DOCKER_NETWORK" "$CONTAINER_NAME" 2>/dev/null || true
        sleep 2
        echo "  → Reconnecting to network"
        docker network connect "$DOCKER_NETWORK" "$CONTAINER_NAME" 2>/dev/null || true
        echo "  ✓ Network recovered"
        ;;
    
    recover)
        echo "  → Recovering container"
        if [[ $(docker inspect -f '{{.State.Paused}}' "$CONTAINER_NAME") == "true" ]]; then
            docker unpause "$CONTAINER_NAME"
            echo "  ✓ Resumed from pause"
        fi
        if ! docker network inspect --format '{{.Name}}' "$DOCKER_NETWORK" | grep -q "$CONTAINER_NAME"; then
            docker network connect "$DOCKER_NETWORK" "$CONTAINER_NAME" 2>/dev/null || true
            echo "  ✓ Reconnected to network"
        fi
        docker start "$CONTAINER_NAME" 2>/dev/null || true
        echo "  ✓ Container recovered"
        ;;
    
    stress)
        if ! command -v stress-ng &>/dev/null; then
            echo "  ⚠ stress-ng not installed in container, skipping"
            exit 1
        fi
        echo "  → Stressing CPU for 60s"
        docker exec -d "$CONTAINER_NAME" stress-ng --cpu 4 --timeout 60s 2>/dev/null || true
        echo "  ✓ CPU stress test running"
        ;;
    
    *)
        echo "Error: Unknown mode: $MODE"
        exit 1
        ;;
esac