#! /bin/bash
set -euo pipefail
ENV_ID="${1:?Error: ENV_ID required}"


STATE_FILE="envs/${ENV_ID}.json"
if [[ ! -f "$STATE_FILE" ]]; then
    echo "State file not found: $STATE_FILE"
    exit 1
fi

# Parse state
CONTAINER_NAME=$(jq -r '.container' "$STATE_FILE")
DOCKER_NETWORK=$(jq -r '.network' "$STATE_FILE")

# stop and remove container
if docker ps -a --filter "name=sandbox_${ENV_ID}" --format "{{.Names}}" | grep -q "sandbox_${ENV_ID}"; then
    docker rm -f "sandbox_${ENV_ID}"
    echo "Container removed: sandbox_${ENV_ID}"
else
    echo "Container not found: sandbox_${ENV_ID}"
fi

# Remove Nginx config
NGINX_CONF="nginx/conf.d/${ENV_ID}.conf"
if [[ -f "$NGINX_CONF" ]]; then
    rm "$NGINX_CONF"
    echo " Nginx config removed"
    
    if docker ps --format '{{.Names}}' | grep -q '^nginx$'; then
        docker exec nginx nginx -s reload 2>/dev/null || true
        echo "Nginx reloaded"
    fi
fi

# kill log shipper
LOG_PID=$(jq -r '.log_pid' "$STATE_FILE")

if [[ "$LOG_PID" != "null" ]]; then
    kill "$LOG_PID" 2>/dev/null || true
    echo "Stopped log shipper"
fi

# Archive logs
mkdir -p "logs/archived"
if [[ -d "logs/${ENV_ID}" ]]; then
    mv "logs/${ENV_ID}" \ "logs/archived/${ENV_ID}-$(date +%s)"
    echo "Logs archived"
fi

# Remove state file
rm "$STATE_FILE"
echo " State cleared"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Environment destroyed: $ENV_ID"