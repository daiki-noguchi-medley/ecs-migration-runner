# ローカル開発用ショートカット
# 対応環境: macOS / Windows (Docker Desktop) / Linux
#
# `make` だけで利用可能なターゲット一覧が出る。
# `make help` でも同じ。

# -------- OS 判定 --------
UNAME := $(shell uname -s)
ifeq ($(UNAME), Darwin)
  OS := macOS
else ifeq ($(OS), Windows_NT)
  OS := Windows
else
  OS := Linux
endif

# docker-compose ファイル選択
# - ローカル postgres 使用時: docker-compose.yml
# - Dev Container 使用時: .devcontainer/docker-compose.yml
COMPOSE_FILE ?= docker-compose.yml
DEVCONTAINER_COMPOSE := .devcontainer/docker-compose.yml

.PHONY: help os-check up migrate down reset info validate clean psql logs status build \
        spotless-check spotless-fix \
        devcontainer-up devcontainer-stop devcontainer-logs \
        gradle-check gradle-fix

.DEFAULT_GOAL := help

# -------- ヘルプ --------

help: ## このヘルプを表示
	@echo "========================================"
	@echo "ecs-migration-runner ローカル開発コマンド"
	@echo "========================================"
	@echo ""
	@echo "検出環境: $(OS)"
	@echo ""
	@echo "ターゲット一覧:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk -F ':.*?## ' '{printf "  \033[36m%-20s\033[0m  %s\n", $$1, $$2}'
	@echo ""
	@echo "使い方:"
	@echo "  make up              - PostgreSQL + Flyway を起動（ローカル compose）"
	@echo "  make spotless-fix    - SQL を自動フォーマット"
	@echo "  make spotless-check  - SQL フォーマット検証"
	@echo ""
	@echo "Dev Container 使用時:"
	@echo "  make devcontainer-up    - Dev Container を起動（VSCode で開く）"
	@echo "  make gradle-check       - Dev Container 内で Spotless check"
	@echo "  make gradle-fix         - Dev Container 内で Spotless fix"

os-check: ## 検出環境を表示
	@echo "Detected OS: $(OS)"
	@echo "Docker: $$(docker --version 2>/dev/null || echo 'Not installed')"
	@echo "Docker Compose: $$(docker compose version 2>/dev/null || docker-compose --version 2>/dev/null || echo 'Not installed')"
	@echo "Make: $$(make --version 2>/dev/null | head -1)"

# -------- ローカル DB 起動 / 停止 --------

up: ## DB を起動 + Flyway で migrate (一発で最新まで適用)
	docker compose -f $(COMPOSE_FILE) up --abort-on-container-exit flyway

migrate: up ## up のエイリアス (意味は同じ)

down: ## コンテナ停止 (data volume は残るので次回 up で続きから)
	docker compose -f $(COMPOSE_FILE) down

reset: ## コンテナ停止 + data volume 削除 (DB を完全初期化)
	docker compose -f $(COMPOSE_FILE) down -v

# -------- Flyway サブコマンド (ローカル compose 用) --------

info: ## 適用済み migration 一覧を表示
	docker compose -f $(COMPOSE_FILE) run --rm flyway info

validate: ## SQL の構文 + checksum 検証 (適用済みファイルが書き換えられていないか)
	docker compose -f $(COMPOSE_FILE) run --rm flyway validate

clean: ## スキーマを全消去 (開発限定、確認なしで実行されるので注意)
	@echo "WARNING: This will DELETE all data in the database!"
	@read -p "Are you sure? Type 'yes' to continue: " confirm; \
	if [ "$$confirm" = "yes" ]; then \
		docker compose -f $(COMPOSE_FILE) run --rm flyway clean; \
	else \
		echo "Cancelled."; \
	fi

# -------- 観測 / 接続 --------

psql: ## DB に psql で接続 (\dt でテーブル一覧、\q で抜ける)
	docker compose -f $(COMPOSE_FILE) exec db psql -U appuser -d appdb

logs: ## DB のログを tail (Ctrl+C で抜ける)
	docker compose -f $(COMPOSE_FILE) logs -f db

status: ## コンテナと volume の状態
	@echo "-- containers --"
	@docker compose -f $(COMPOSE_FILE) ps
	@echo ""
	@echo "-- volumes --"
	@docker volume ls --filter name=ecs-migration || true

# -------- 本番用 (ECR push) のイメージをローカルで build 確認 --------

build: ## docker/Dockerfile で本番用イメージを linux/amd64 で build (push しない)
	docker buildx build --platform linux/amd64 \
	  -f docker/Dockerfile \
	  -t flyway-migration:local-amd64 \
	  --load .

# -------- Spotless (SQL フォーマット・Lint) - ローカル Gradle --------

spotless-check: ## SQL ファイルのフォーマット・Lint チェック (ローカル Gradle)
ifeq ($(shell command -v gradle 2>/dev/null),)
	@echo "⚠️  Gradle がローカルにインストールされていません。"
	@echo "   Dev Container を使用する場合は: make gradle-check"
	@echo "   または docker-compose を使用します..."
	docker compose -f $(DEVCONTAINER_COMPOSE) run --rm gradle gradle spotlessCheck
else
	gradle spotlessCheck
endif

spotless-fix: ## SQL ファイルを自動フォーマット (ローカル Gradle)
ifeq ($(shell command -v gradle 2>/dev/null),)
	@echo "⚠️  Gradle がローカルにインストールされていません。"
	@echo "   Dev Container を使用する場合は: make gradle-fix"
	@echo "   または docker-compose を使用します..."
	docker compose -f $(DEVCONTAINER_COMPOSE) run --rm gradle gradle spotlessApply
else
	gradle spotlessApply
endif

# -------- Dev Container (VSCode) --------

devcontainer-up: ## Dev Container を VSCode で起動
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
	@echo "✅ Dev Container is starting. PostgreSQL + Flyway will initialize automatically."

devcontainer-stop: ## Dev Container を停止
	docker compose -f $(DEVCONTAINER_COMPOSE) down

devcontainer-logs: ## Dev Container のログを表示
	docker compose -f $(DEVCONTAINER_COMPOSE) logs -f

devcontainer-shell: ## Dev Container のシェルに入る
	docker compose -f $(DEVCONTAINER_COMPOSE) exec gradle bash

# -------- Gradle (Dev Container 経由) --------

gradle-check: ## Dev Container 内で SQL フォーマット検証
	@echo "Running Spotless Check in Dev Container..."
	docker compose -f $(DEVCONTAINER_COMPOSE) run --rm gradle gradle spotlessCheck

gradle-fix: ## Dev Container 内で SQL を自動フォーマット
	@echo "Running Spotless Fix in Dev Container..."
	docker compose -f $(DEVCONTAINER_COMPOSE) run --rm gradle gradle spotlessApply

gradle-build: ## Dev Container 内で Gradle ビルド
	docker compose -f $(DEVCONTAINER_COMPOSE) run --rm gradle gradle build

gradle-clean: ## Dev Container 内で Gradle クリーン
	docker compose -f $(DEVCONTAINER_COMPOSE) run --rm gradle gradle clean

# -------- トラブルシューティング --------

clean-gradle-cache: ## Gradle キャッシュを削除（Windows/Mac）
	rm -rf ~/.gradle/caches/
	@echo "✅ Gradle cache cleared"

docker-prune: ## Docker のダングリングコンテナ・イメージを削除
	docker system prune -f
	@echo "✅ Docker system pruned"
