SHELL := /bin/bash

# Config

API_PORT=8000
API_HOST=0.0.0.0

PYTHON=python3
UVICORN=uvicorn

COMPOSE=docker compose
COMPOSE_FILE=docker-compose.yml

CREATE_SCRIPT=./platform/create_env.sh
DESTROY_SCRIPT=./platform/destroy_env.sh
CLEANUP_SCRIPT=./platform/cleanup_daemon.sh
OUTAGE_SCRIPT=./platform/simulate_outage.sh
MONITOR_SCRIPT=./monitor/health_poller.sh

ENVS_DIR=envs
LOGS_DIR=logs

# Phony Targets

.PHONY: help up down create destroy logs health simulate clean api daemon monitor

# Default Help

help:
	@echo ""
	@echo "Ephemeral Environment Platform"
	@echo ""
	@echo "Available commands:"
	@echo "  make up"
	@echo "  make down"
	@echo "  make create"
	@echo "  make destroy ENV=env-abc123"
	@echo "  make logs ENV=env-abc123"
	@echo "  make health"
	@echo "  make simulate ENV=env-abc123 MODE=crash"
	@echo "  make clean"
	@echo ""

# Start Platform

up:
	@echo "Starting platform..."

	@mkdir -p logs
	@mkdir -p logs/nginx
	@mkdir -p logs/archived
	@mkdir -p envs

	@echo "Starting Nginx..."
	@docker compose up

	@echo "Starting Cleanup Daemon..."
	@nohup $(CLEANUP_SCRIPT) \
	> logs/cleanup-daemon.out 2>&1 &

	@echo "Starting Health Monitor..."
	@nohup $(MONITOR_SCRIPT) \
	> logs/monitor.out 2>&1 &

	@echo "Starting API..."
	@nohup $(UVICORN) platform.api:app \
	--host $(API_HOST) \
	--port $(API_PORT) \
	> logs/api.out 2>&1 &

	@echo ""
	@echo "Platform started"
	@echo "API: http://localhost:$(API_PORT)"


# Stop Everything

down:
	@echo "Destroying all environments..."

	@if ls $(ENVS_DIR)/*.json >/dev/null 2>&1; then \
		for env in $(ENVS_DIR)/*.json; do \
			ENV_ID=$$(basename $$env .json); \
			echo "Destroying $$ENV_ID"; \
			$(DESTROY_SCRIPT) $$ENV_ID; \
		done \
	else \
		echo "No active environments"; \
	fi

	@echo "Stopping nginx..."
	@$(COMPOSE) -f $(COMPOSE_FILE) down

	@echo "Stopping API..."
	@pkill -f "uvicorn api.main:app" || true

	@echo "Stopping cleanup daemon..."
	@pkill -f cleanup_daemon.sh || true

	@echo "Stopping health monitor..."
	@pkill -f health_poller.sh || true

	@echo "Platform stopped"

# Create Environment

create:
	@read -p "Environment name: " NAME; \
	read -p "TTL in minutes (default 30): " TTL; \
	TTL=$${TTL:-30}; \
	$(CREATE_SCRIPT) $$NAME $$TTL

# Destroy Environment

destroy:
	@if [ -z "$(ENV)" ]; then \
		echo "Usage: make destroy ENV=env-abc123"; \
		exit 1; \
	fi

	@$(DESTROY_SCRIPT) $(ENV)

# Tail Logs

logs:
	@if [ -z "$(ENV)" ]; then \
		echo "Usage: make logs ENV=env-abc123"; \
		exit 1; \
	fi

	@if [ ! -f logs/$(ENV)/app.log ]; then \
		echo "No logs found for $(ENV)"; \
		exit 1; \
	fi

	@tail -f logs/$(ENV)/app.log

# Show Health Status

health:
	@echo ""
	@echo "Environment Health"
	@echo "=========================="

	@if ls $(ENVS_DIR)/*.json >/dev/null 2>&1; then \
		for env in $(ENVS_DIR)/*.json; do \
			STATUS=$$(jq -r '.status' $$env); \
			NAME=$$(jq -r '.name' $$env); \
			ID=$$(jq -r '.id' $$env); \
			echo "$$ID ($$NAME) → $$STATUS"; \
		done \
	else \
		echo "No active environments"; \
	fi


# Simulate Outage

simulate:
	@if [ -z "$(ENV)" ]; then \
		echo "Usage: make simulate ENV=env-abc123 MODE=crash"; \
		exit 1; \
	fi

	@if [ -z "$(MODE)" ]; then \
		echo "MODE required"; \
		echo "Options: crash pause network recover stress"; \
		exit 1; \
	fi

	@$(OUTAGE_SCRIPT) \
	--env $(ENV) \
	--mode $(MODE)

# Clean Everything

clean:
	@echo "Cleaning platform..."

	@make down || true

	@rm -rf envs/*
	@rm -rf logs/*
	@rm -rf nginx/conf.d/*

	@mkdir -p logs/nginx
	@mkdir -p logs/archived
	@mkdir -p envs

	@docker network prune -f

	@echo "Platform cleaned"