# Local development shortcuts
# Supported environments: macOS / Windows (Docker Desktop) / Linux
#
# Running `make` alone shows all available targets.
# `make help` does the same.

# -------- OS 判定 --------
UNAME := $(shell uname -s)
ifeq ($(UNAME), Darwin)
  OS := macOS
else ifeq ($(OS), Windows_NT)
  OS := Windows
else
  OS := Linux
endif

# docker-compose file selection
# - For local postgres: docker-compose.yml
# - For Dev Container: .devcontainer/docker-compose.yml
COMPOSE_FILE ?= docker-compose.yml
DEVCONTAINER_COMPOSE := .devcontainer/docker-compose.yml

.PHONY: help os-check up migrate down reset info validate clean psql logs status build \
        spotless-check spotless-fix \
        devcontainer-up devcontainer-stop devcontainer-logs \
        gradle-check gradle-fix

.DEFAULT_GOAL := help

# -------- Help --------

help: ## Show this help
	@echo "========================================"
	@echo "ecs-migration-runner Local Dev Commands"
	@echo "========================================"
	@echo ""
	@echo "Detected OS: $(OS)"
	@echo ""
	@echo "Available Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk -F ':.*?## ' '{printf "  \033[36m%-20s\033[0m  %s\n", $$1, $$2}'
	@echo ""
	@echo "Usage:"
	@echo "  make up              - Start PostgreSQL + Flyway (local compose)"
	@echo "  make spotless-fix    - Auto-format SQL files"
	@echo "  make spotless-check  - Check SQL format"
	@echo ""
	@echo "Using Dev Container:"
	@echo "  make devcontainer-up    - Start Dev Container in VSCode"
	@echo "  make gradle-check       - Check Spotless in Dev Container"
	@echo "  make gradle-fix         - Fix Spotless in Dev Container"

os-check: ## Show detected environment
	@echo "Detected OS: $(OS)"
	@echo "Docker: $$(docker --version 2>/dev/null || echo 'Not installed')"
	@echo "Docker Compose: $$(docker compose version 2>/dev/null || docker-compose --version 2>/dev/null || echo 'Not installed')"
	@echo "Make: $$(make --version 2>/dev/null | head -1)"

# -------- Local DB Start / Stop --------

up: ## Start DB + Flyway migrate (applies all migrations)
	docker compose -f $(COMPOSE_FILE) up --abort-on-container-exit flyway

migrate: up ## Alias for up

down: ## Stop containers (data volume remains, can continue next time)
	docker compose -f $(COMPOSE_FILE) down

reset: ## Stop containers + delete data volume (full reset)
	docker compose -f $(COMPOSE_FILE) down -v

# -------- Flyway Subcommands (local compose) --------

info: ## Show applied migrations list
	docker compose -f $(COMPOSE_FILE) run --rm flyway info

validate: ## Validate SQL syntax + checksum (verify no applied files changed)
	docker compose -f $(COMPOSE_FILE) run --rm flyway validate

clean: ## Erase all schema (dev only, no confirmation!)
	@echo "WARNING: This will DELETE all data in the database!"
	@read -p "Are you sure? Type 'yes' to continue: " confirm; \
	if [ "$$confirm" = "yes" ]; then \
		docker compose -f $(COMPOSE_FILE) run --rm flyway clean; \
	else \
		echo "Cancelled."; \
	fi

# -------- Existing DB Integration (Baseline + Schema Dump) --------

baseline-init: ## Initialize existing DB with Baseline (mark V1.0 as applied)
	@echo "WARNING: Registering existing schema as Baseline"
	@echo "   Use this when integrating Flyway with already-running DB"
	@read -p "Enter Baseline Version (default: 1.0): " version; \
	VERSION=$${version:-1.0}; \
	docker compose -f $(COMPOSE_FILE) run --rm flyway baseline \
	  -baselineVersion=$$VERSION \
	  -baselineDescription="Initial schema (manual setup)" && \
	echo "OK: Baseline initialized at version $$VERSION"

dump-schema: ## Dump existing tables to SQL
	@echo "Dumping existing schema to migrations/sql/V0__baseline.sql..."
	@mkdir -p migrations/sql
	@docker compose -f $(COMPOSE_FILE) exec -T db pg_dump \
	  -U appuser \
	  -d appdb \
	  --schema-only \
	  --no-privileges \
	  --no-owner \
	  > migrations/sql/V0__baseline.sql && \
	echo "OK: Schema dumped to migrations/sql/V0__baseline.sql"
	@echo ""
	@echo "Next steps:"
	@echo "1. Review migrations/sql/V0__baseline.sql"
	@echo "2. Run: make baseline-init"
	@echo "3. Run: make up to verify"

repair: ## Repair Flyway checksum errors (if you edited existing SQL)
	@echo "WARNING: flyway repair is a last resort"
	@echo "   This recalculates checksums in flyway_schema_history"
	@echo "   Normally use new migration files instead"
	@read -p "Really execute? (yes/no): " confirm; \
	if [ "$$confirm" = "yes" ]; then \
		docker compose -f $(COMPOSE_FILE) run --rm flyway repair; \
		echo "OK: Repair completed"; \
	else \
		echo "Cancelled."; \
	fi

# -------- Observation / Connection --------

psql: ## Connect to DB with psql (\dt for tables, \q to exit)
	docker compose -f $(COMPOSE_FILE) exec db psql -U appuser -d appdb

logs: ## Tail DB logs (Ctrl+C to exit)
	docker compose -f $(COMPOSE_FILE) logs -f db

status: ## Show containers and volumes status
	@echo "-- containers --"
	@docker compose -f $(COMPOSE_FILE) ps
	@echo ""
	@echo "-- volumes --"
	@docker volume ls --filter name=ecs-migration || true

# -------- Production Image Build Check --------

build: ## Build production image with linux/amd64 (no push)
	docker buildx build --platform linux/amd64 \
	  -f docker/Dockerfile \
	  -t flyway-migration:local-amd64 \
	  --load .

# -------- Spotless (SQL Format/Lint) - Local Gradle --------

spotless-check: ## Check SQL format/lint (local Gradle)
ifeq ($(shell command -v gradle 2>/dev/null),)
	@echo "WARNING: Gradle not installed locally."
	@echo "   For Dev Container: make gradle-check"
	@echo "   Using docker-compose..."
	@docker compose -f $(COMPOSE_FILE) down 2>/dev/null || true
	docker compose -f $(DEVCONTAINER_COMPOSE) run --rm gradle gradle spotlessCheck
else
	gradle spotlessCheck
endif

spotless-fix: ## Auto-format SQL files (local Gradle)
ifeq ($(shell command -v gradle 2>/dev/null),)
	@echo "WARNING: Gradle not installed locally."
	@echo "   For Dev Container: make gradle-fix"
	@echo "   Using docker-compose..."
	@docker compose -f $(COMPOSE_FILE) down 2>/dev/null || true
	docker compose -f $(DEVCONTAINER_COMPOSE) run --rm gradle gradle spotlessApply
else
	gradle spotlessApply
endif

# -------- Dev Container (VSCode) --------

devcontainer-up: ## Start Dev Container in VSCode
	@echo "Opening Dev Container in VSCode..."
	@if [ "$(OS)" = "macOS" ]; then \
		code . --remote container-env:.devcontainer; \
	elif [ "$(OS)" = "Windows" ]; then \
		code . --remote container-env:.devcontainer; \
	else \
		code . --remote container-env:.devcontainer; \
	fi
	@echo "Waiting for Dev Container to start..."
	@sleep 3
	@echo "OK: Dev Container starting. PostgreSQL + Flyway initializing..."

devcontainer-stop: ## Stop Dev Container
	docker compose -f $(DEVCONTAINER_COMPOSE) down

devcontainer-logs: ## Show Dev Container logs
	docker compose -f $(DEVCONTAINER_COMPOSE) logs -f

devcontainer-shell: ## Enter Dev Container shell
	docker compose -f $(DEVCONTAINER_COMPOSE) exec gradle bash

# -------- Gradle (via Dev Container) --------

gradle-check: ## Check SQL format in Dev Container
	@echo "Running Spotless Check in Dev Container..."
	docker compose -f $(DEVCONTAINER_COMPOSE) run --rm gradle gradle spotlessCheck

gradle-fix: ## Auto-format SQL in Dev Container
	@echo "Running Spotless Fix in Dev Container..."
	docker compose -f $(DEVCONTAINER_COMPOSE) run --rm gradle gradle spotlessApply

gradle-build: ## Run Gradle build in Dev Container
	docker compose -f $(DEVCONTAINER_COMPOSE) run --rm gradle gradle build

gradle-clean: ## Run Gradle clean in Dev Container
	docker compose -f $(DEVCONTAINER_COMPOSE) run --rm gradle gradle clean

# -------- Troubleshooting --------

clean-gradle-cache: ## Delete Gradle cache (Windows/Mac)
	rm -rf ~/.gradle/caches/
	@echo "OK: Gradle cache cleared"

docker-prune: ## Delete dangling Docker containers/images
	docker system prune -f
	@echo "OK: Docker system pruned"
