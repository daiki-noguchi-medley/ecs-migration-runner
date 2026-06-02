# タスクリスト: ECS one-shot タスクによる RDS マイグレーション基盤

## 凡例

- [ ] 未着手 / [x] 完了 / [-] スキップ

## フェーズ 1: ドキュメント

- [x] PRD (docs/prd.md)
- [x] アーキテクチャ (docs/architecture.md, ASCII + Mermaid)
- [x] 開発ガイド (docs/development-guide.md)
- [x] リポジトリ構成 (docs/repository-structure.md)
- [x] 要件 (.steering/.../requirements.md)
- [x] 設計 (.steering/.../design.md)
- [x] このタスクリスト

## フェーズ 2: 構成図

- [x] draw.io XML を MCP で開く (aws4 アイコン)
- [x] docs/architecture.drawio として保存

## フェーズ 3: インフラ (CloudFormation)

- [x] `infra/network-data.cfn.yaml` を作成
  - [x] VPC + Subnets (Public×1, Private×2)
  - [x] IGW + NAT Gateway + Route Tables
  - [x] Security Groups (RDSSecurityGroup, ECSTaskSG)
  - [x] DB Subnet Group
  - [x] RDS PostgreSQL 16.x + Secrets Manager 統合 (`ManageMasterUserPassword`)
  - [x] Outputs (VPC, Subnets, SG, Secret ARN, DB Endpoint)
- [x] `infra/app.cfn.yaml` を作成
  - [x] ECR Repository + LifecyclePolicy
  - [x] CloudWatch Logs Group (retention 30 日)
  - [x] ECS Cluster
  - [x] IAM TaskExecutionRole
  - [x] IAM FlywayTaskRole
  - [x] OIDC Provider (Condition で切替)
  - [x] IAM GitHubActionsRole + 権限ポリシー
  - [x] ECS Task Definition (Fargate, 0.25 vCPU / 512 MB)

## フェーズ 4: アプリケーション資産

- [x] `docker/Dockerfile` (FROM flyway/flyway:10-alpine + COPY)
- [x] `migrations/sql/V1__init.sql` (サンプル: バージョン管理用テーブル)
- [x] `migrations/sql/V2__add_users.sql` (サンプル: ユーザーテーブル)

## フェーズ 5: CI/CD

- [x] `.github/workflows/migrate.yml`
  - [x] OIDC `permissions`
  - [x] checkout / configure-aws-credentials / ecr-login (SHA pin)
  - [x] docker build & push (SHA タグ + latest)
  - [x] aws ecs run-task
  - [x] tasks-stopped 待ち + exit code 判定
  - [x] CloudWatch Logs tail を job ログに

## フェーズ 6: README

- [x] README.md (概要 + クイックスタート)

## フェーズ 7: 実環境検証 (本ステアリングのスコープ外、別チケットへ)

- [ ] スタック 1 をデプロイ → RDS 作成完了確認
- [ ] スタック 2 をデプロイ → ECR / ECS / IAM 確認
- [ ] GitHub に push してワークフロー成功確認
- [ ] V2 を追加して再 push → 差分のみ適用されることを確認
- [ ] V2 を意図的に壊して再 push → Actions が失敗、ログ確認

## 進捗メモ

- 2026-06-01: requirements/design/tasklist 作成完了。実装フェーズに進む
- 2026-06-01: フェーズ 1〜6 完了、フェーズ 7 は実環境準備でき次第着手
