#!/bin/bash

set -euo pipefail

# name and optional TTL
NAME=${1:-"env"}
TTL=${2:-1800}
ENV_ID="$(date +%s)-$(openssl rand -hex 4)"
CREATED_AT=$(date +%s)
EXPIRE_AT=$((CREATED_AT + TTL))

# load config from .env
source .env 2>/dev/null || true
APP_IMAGE="${APP_IMAGE:-nginx:latest}"
APP_PORT="${APP_PORT:-8080}"

CONTAINER_NAME="sandbox_${ENV_ID}"
# Create a dedicated docker network
DOCKER_NETWORK="${DOCKER_NETWORK:-devops-sandbox}"

docker network create "$DOCKER_NETWORK" 2>/dev/null || true
echo "Docker network created: $DOCKER_NETWORK"

# start the app container
docker run -d \
    --name "${CONTAINER_NAME}" \
    --label "sandbox.env=${ENV_ID}" \
    --network "${DOCKER_NETWORK}" \
    "${APP_IMAGE}"

# write state file
state_file="envs/${env_id}.json"
temp_file="${state_file}.tmp"
cat > "$temp_file" <<EOF
{
    "id": "${ENV_ID}",
    "name": "${NAME}",
    "ttl": ${TTL},
    "created_at": ${CREATED_AT},
    "expire_at": ${EXPIRE_AT},
    "container_name": "${CONTAINER_NAME}",
    "app_port": ${APP_PORT},
    "status": "healthy"
}
EOF
mv "$temp_file" "$state_file"


# Setup logging
mkdir -p "logs/${ENV_ID}"
docker logs -f "$CONTAINER_NAME" > "logs/${ENV_ID}/app.log" 2>&1 &
echo $! > "logs/${ENV_ID}/app.log.pid"
echo "Logging to logs/${ENV_ID}/app.log"

# Initialize health log
touch "logs/${ENV_ID}/health.log"

# generate nginx route
NGINX_CONF_FILE="$NGINX_CONF_DIR/${ENV_ID}.conf"
cat > "$NGINX_CONF_FILE" <<EOF
server {
    listen 80;

    server_name ${ENV_ID}.${BASE_DOMAIN};

    location / {
        proxy_pass http://${CONTAINER_NAME}:${APP_PORT};

        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

echo "Nginx config written"

# reload nginx
docker exec "$NGINX_CONTAINER" nginx -s reload
echo "Nginx reloaded"
