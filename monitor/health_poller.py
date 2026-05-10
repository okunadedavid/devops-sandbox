#!/usr/bin/env python3

import os
import json
import time
import glob
import requests
import subprocess
from datetime import datetime
from pathlib import Path

HEALTH_CHECK_INTERVAL = 30
FAILURE_THRESHOLD = 3
LOG_DIR = "logs"
ENVS_DIR = "envs"

def read_state(env_id):
    """Load environment state."""
    state_file = f"{ENVS_DIR}/{env_id}.json"
    try:
        with open(state_file) as f:
            return json.load(f)
    except FileNotFoundError:
        return None

def write_state(env_id, state):
    """Update environment state."""
    state_file = f"{ENVS_DIR}/{env_id}.json"
    with open(state_file, 'w') as f:
        json.dump(state, f, indent=2)

def check_health(env_id, state):
    """Hit /health endpoint and log result."""
    container_name = state.get('container')
    port = state.get('port')
    url = f"http://127.0.0.1:{port}/health"
    
    log_file = f"{LOG_DIR}/{env_id}/health.log"
    os.makedirs(os.path.dirname(log_file), exist_ok=True)
    
    start = time.time()
    status = "unknown"
    latency = 0
    
    try:
        resp = requests.get(url, timeout=5)
        latency = int((time.time() - start) * 1000)
        status = "up" if resp.status_code == 200 else "degraded"
    except Exception as e:
        latency = int((time.time() - start) * 1000)
        status = "down"
        error_msg = str(e)[:50]
    
    # Log result
    timestamp = datetime.now().isoformat()
    log_entry = {
        "timestamp": timestamp,
        "status": status,
        "latency_ms": latency,
        "url": url
    }
    
    with open(log_file, 'a') as f:
        f.write(json.dumps(log_entry) + "\n")
    
    # Track consecutive failures
    if status == "down":
        state['consecutive_failures'] = state.get('consecutive_failures', 0) + 1
    else:
        state['consecutive_failures'] = 0
    
    # Alert after 3 failures
    if state['consecutive_failures'] >= FAILURE_THRESHOLD:
        if state.get('status') != 'degraded':
            print(f"[{env_id}] {state['name']}: DEGRADED after {FAILURE_THRESHOLD} failures")
            state['status'] = 'degraded'
    else:
        state['status'] = 'healthy'
    
    write_state(env_id, state)
    return status, latency

def poll_all():
    """Poll all active environments."""
    state_files = glob.glob(f"{ENVS_DIR}/*.json")
    
    for state_file in state_files:
        env_id = os.path.basename(state_file).replace('.json', '')
        state = read_state(env_id)
        
        if state:
            status, latency = check_health(env_id, state)
            print(f"[{datetime.now().strftime('%H:%M:%S')}] {state['name']:20} {status:10} {latency:5}ms")

def main():
    print("Health poller started")
    try:
        while True:
            poll_all()
            time.sleep(HEALTH_CHECK_INTERVAL)
    except KeyboardInterrupt:
        print("\nHealth poller stopped")

if __name__ == '__main__':
    main()