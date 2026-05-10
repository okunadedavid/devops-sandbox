#!/usr/bin/env python3

from flask import Flask, request, jsonify, send_file
from werkzeug.exceptions import NotFound
import json
import glob
import os
import subprocess
from datetime import datetime
from pathlib import Path
import io

app = Flask(__name__)

def load_state(env_id):
    """Load env state file."""
    state_file = f"envs/{env_id}.json"
    try:
        with open(state_file) as f:
            return json.load(f)
    except FileNotFoundError:
        raise NotFound(f"Environment not found: {env_id}")

def get_active_envs():
    """List all active environments."""
    envs = []
    for state_file in glob.glob("envs/*.json"):
        try:
            with open(state_file) as f:
                state = json.load(f)
                # Calculate TTL remaining
                now = int(datetime.now().timestamp())
                ttl_remaining = max(0, state['expire_at'] - now)
                state['ttl_remaining_seconds'] = ttl_remaining
                envs.append(state)
        except:
            pass
    return sorted(envs, key=lambda x: x['created_at'], reverse=True)

@app.route('/health', methods=['GET'])
def api_health():
    """API health check."""
    return jsonify({"status": "ok", "timestamp": datetime.now().isoformat()})

@app.route('/envs', methods=['POST'])
def create_env():
    """POST /envs with {name, ttl_minutes}"""
    data = request.json or {}
    name = data.get('name', f"env-{datetime.now().strftime('%s')}")
    ttl_minutes = data.get('ttl_minutes', 30)
    ttl_seconds = ttl_minutes * 60
    
    try:
        result = subprocess.run(
            ['bash', 'platform/create_env.sh', f'--name', name, f'--ttl', str(ttl_seconds)],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode != 0:
            return jsonify({"error": result.stderr}), 500
        
        # Extract env ID from output
        for line in result.stdout.split('\n'):
            if 'ID:' in line:
                env_id = line.split('ID:')[1].strip()
                return jsonify(load_state(env_id)), 201
        
        return jsonify({"error": "Could not parse response"}), 500
    
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/envs', methods=['GET'])
def list_envs():
    """GET /envs"""
    envs = get_active_envs()
    return jsonify({
        "count": len(envs),
        "envs": envs,
        "timestamp": datetime.now().isoformat()
    })

@app.route('/envs/<env_id>', methods=['DELETE'])
def destroy_env(env_id):
    """DELETE /envs/:id"""
    try:
        load_state(env_id)  # Verify exists
        
        result = subprocess.run(
            ['bash', 'platform/destroy_env.sh', env_id],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode != 0:
            return jsonify({"error": result.stderr}), 500
        
        return jsonify({"status": "destroyed", "id": env_id})
    
    except NotFound:
        return jsonify({"error": f"Environment not found: {env_id}"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/envs/<env_id>/logs', methods=['GET'])
def get_logs(env_id):
    """GET /envs/:id/logs"""
    lines = request.args.get('lines', 100, type=int)
    load_state(env_id)  # Verify exists
    
    log_file = f"logs/{env_id}/app.log"
    if not os.path.exists(log_file):
        return jsonify({"error": "Log file not found"}), 404
    
    try:
        with open(log_file) as f:
            all_lines = f.readlines()
            recent_lines = all_lines[-lines:] if len(all_lines) > lines else all_lines
        
        return jsonify({
            "env_id": env_id,
            "total_lines": len(all_lines),
            "returned_lines": len(recent_lines),
            "logs": "".join(recent_lines)
        })
    
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/envs/<env_id>/health', methods=['GET'])
def get_health(env_id):
    """GET /envs/:id/health"""
    lines = request.args.get('lines', 10, type=int)
    load_state(env_id)  # Verify exists
    
    log_file = f"logs/{env_id}/health.log"
    if not os.path.exists(log_file):
        return jsonify({"env_id": env_id, "health_checks": []})
    
    try:
        with open(log_file) as f:
            all_checks = [json.loads(line) for line in f if line.strip()]
            recent_checks = all_checks[-lines:] if len(all_checks) > lines else all_checks
        
        return jsonify({
            "env_id": env_id,
            "total_checks": len(all_checks),
            "health_checks": recent_checks
        })
    
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/envs/<env_id>/outage', methods=['POST'])
def trigger_outage(env_id):
    """POST /envs/:id/outage with {mode}"""
    data = request.json or {}
    mode = data.get('mode', 'crash')
    
    valid_modes = ['crash', 'pause', 'network', 'recover', 'stress']
    if mode not in valid_modes:
        return jsonify({"error": f"Invalid mode. Must be one of: {valid_modes}"}), 400
    
    try:
        load_state(env_id)  # Verify exists
        
        result = subprocess.run(
            ['bash', 'platform/simulate_outage.sh', '--env', env_id, '--mode', mode],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode != 0:
            return jsonify({"error": result.stderr}), 500
        
        return jsonify({
            "status": "simulating",
            "env_id": env_id,
            "mode": mode,
            "output": result.stdout
        })
    
    except NotFound:
        return jsonify({"error": f"Environment not found: {env_id}"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/envs/<env_id>/download-logs', methods=['GET'])
def download_logs(env_id):
    """GET /envs/:id/download-logs - download logs as tar.gz"""
    load_state(env_id)  # Verify exists
    
    import tarfile
    log_dir = f"logs/{env_id}"
    if not os.path.exists(log_dir):
        return jsonify({"error": "No logs for environment"}), 404
    
    try:
        tar_buffer = io.BytesIO()
        with tarfile.open(fileobj=tar_buffer, mode='w:gz') as tar:
            tar.add(log_dir, arcname=env_id)
        
        tar_buffer.seek(0)
        return send_file(
            tar_buffer,
            mimetype='application/gzip',
            as_attachment=True,
            download_name=f"{env_id}-logs.tar.gz"
        )
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)