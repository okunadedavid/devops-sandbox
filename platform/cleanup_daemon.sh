#!/bin/bash

set -euo pipefail

CLEANUP_LOG="logs/cleanup.log"
CHECK_INTERVAL=60

mkdir -p logs envs

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Cleanup daemon started (check interval: ${CHECK_INTERVAL}s)" | tee -a "$CLEANUP_LOG"

cleanup_loop() {
    while true; do
        CURRENT_TIME=$(date +%s)
        
        for STATE_FILE in envs/*.json; do
            [[ -f "$STATE_FILE" ]] || continue
            
            ENV_ID=$(basename "$STATE_FILE" .json)
            EXPIRE_AT=$(jq -r '.expire_at' "$STATE_FILE" 2>/dev/null || echo 0)
            TTL=$(jq -r '.ttl_seconds' "$STATE_FILE" 2>/dev/null || echo 0)
            NAME=$(jq -r '.name' "$STATE_FILE" 2>/dev/null || echo "unknown")
            
            if [[ $CURRENT_TIME -gt $EXPIRE_AT ]]; then
                ELAPSED=$((CURRENT_TIME - EXPIRE_AT))
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] TTL expired for '$NAME' ($ENV_ID) - expired ${ELAPSED}s ago" | tee -a "$CLEANUP_LOG"
                
                ./platform/destroy_env.sh "$ENV_ID" 2>&1 | sed "s/^/  [cleanup] /" >> "$CLEANUP_LOG"
            fi
        done
        
        sleep "$CHECK_INTERVAL"
    done
}

# Trap signals for graceful shutdown
trap 'echo "[$(date +"%Y-%m-%d %H:%M:%S")] Cleanup daemon stopped" | tee -a "$CLEANUP_LOG"; exit 0' SIGTERM SIGINT

cleanup_loop