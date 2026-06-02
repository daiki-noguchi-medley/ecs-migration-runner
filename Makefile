# ローカル開発用ショートカット (docker compose のラッパー)
#
# `make` だけで利用可能なターゲット一覧が出る。
# `make help` でも同じ。

.PHONY: help up migrate down reset info validate clean psql logs status build

.DEFAULT_GOAL := help

# -------- ヘルプ --------

help: ## このヘルプを表示
	@echo "ターゲット一覧:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk -F ':.*?## ' '{printf "  \033[36m%-10s\033[0m  %s\n", $$1, $$2}'

# -------- 起動 / 停止 --------

up: ## DB を起動 + Flyway で migrate (一発で最新まで適用)
	docker compose up --abort-on-container-exit flyway

migrate: up ## up のエイリアス (意味は同じ)

down: ## コンテナ停止 (data volume は残るので次回 up で続きから)
	docker compose down

reset: ## コンテナ停止 + data volume 削除 (DB を完全初期化)
	docker compose down -v

# -------- Flyway サブコマンド --------

info: ## 適用済み migration 一覧を表示
	docker compose run --rm flyway info

validate: ## SQL の構文 + checksum 検証 (適用済みファイルが書き換えられていないか)
	docker compose run --rm flyway validate

clean: ## スキーマを全消去 (開発限定、確認なしで実行されるので注意)
	docker compose run --rm flyway clean

# -------- 観測 / 接続 --------

psql: ## DB に psql で接続 (\dt でテーブル一覧、\q で抜ける)
	docker compose exec db psql -U appuser -d appdb

logs: ## DB のログを tail (Ctrl+C で抜ける)
	docker compose logs -f db

status: ## コンテナと volume の状態
	@echo "-- containers --"
	@docker compose ps
	@echo ""
	@echo "-- volumes --"
	@docker volume ls --filter name=ecs-migration || true

# -------- 本番用 (ECR push) のイメージをローカルで build 確認 --------

build: ## docker/Dockerfile で本番用イメージを linux/amd64 で build (push しない)
	docker buildx build --platform linux/amd64 \
	  -f docker/Dockerfile \
	  -t flyway-migration:local-amd64 \
	  --load .
