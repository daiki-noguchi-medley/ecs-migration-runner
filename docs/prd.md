# PRD: ECS one-shot タスクによる RDS マイグレーション基盤

## 1. 背景・目的

RDS (PostgreSQL) に対する DB マイグレーションを、安全・再現可能・最小コストで実行する仕組みを構築する。

- **背景**: アプリの ECS タスク内で起動時マイグレーションを行うと、タスク数 × マイグレーション実行で **重複・競合** が発生する。CodePipeline + CodeBuild で組む方式は構築コストが重く、NAT 課金も嵩む。
- **目的**: マイグレーション専用の **ECS Fargate ショット (one-shot) タスク** を、**GitHub Actions から OIDC 認証**で起動し、private subnet 内の RDS に Flyway で適用する。
- **対象外**: アプリ本体のデプロイ・ローリングアップデート (本プロジェクトはマイグレーション基盤のみ)。

## 2. ユーザーストーリー

| # | As a | I want to | So that |
|---|------|-----------|---------|
| US-1 | 開発者 | `migrations/sql/` に SQL を追加して main に push する | スキーマ変更が自動で RDS に反映される |
| US-2 | 開発者 | 失敗したマイグレーションの原因を CloudWatch Logs で見たい | デバッグできる |
| US-3 | 運用者 | 全インフラを `aws cloudformation deploy` で再現できる | 別アカウントへの展開が容易 |
| US-4 | セキュリティ担当 | 長期 IAM アクセスキーを GitHub に置きたくない | 漏洩リスクを下げたい |

## 3. 機能要件

- F-1: `migrations/sql/V*__*.sql` を Flyway 形式で管理する
- F-2: GitHub Actions の `workflow_dispatch` または `push` (main, `migrations/**` 変更時) で起動する
- F-3: GitHub Actions は OIDC で AWS にロール引き受けし、長期キーを使わない
- F-4: GitHub Actions は ECR に Flyway イメージを build & push し、`aws ecs run-task` で one-shot 実行する
- F-5: タスク完了を待ち、終了コードを GitHub Actions の job ステータスに反映する
- F-6: 実行ログは CloudWatch Logs に出力し、Actions のジョブログにも tail を流す

## 4. 非機能要件

- NFR-1: **シンプル** — IaC は CloudFormation 2 スタックに収める (network-data / app)
- NFR-2: **セキュア** — RDS は private subnet、credentials は Secrets Manager、認証は OIDC
- NFR-3: **低コスト** — Fargate 0.25 vCPU / 512 MB、NAT Gateway 1 つ、RDS は `db.t4g.micro` 単一 AZ から
- NFR-4: **再現可能** — `aws cloudformation deploy` 2 回で完全構築
- NFR-5: **観測可能** — CloudWatch Logs に統一、ロググループ名は `/ecs/flyway-migration`

## 5. 成功基準

- main に `migrations/sql/V2__xxx.sql` を追加 → GitHub Actions が 5 分以内に完了 → RDS の `flyway_schema_history` に該当行が追加されている
- AWS Console で IAM ユーザーのアクセスキーが 1 本も存在しない (OIDC ロールのみ)
- スタック削除 → 再作成で同等の動作

## 6. スコープ外 (将来課題)

- マイグレーションの自動ロールバック (Flyway Undo は商用版。OSS 版では「打ち消し migration を追加する」運用)
- マルチ環境 (dev/stg/prod) — 最初は単一環境、後で env プレフィックスで分岐
- アラート (失敗時の Slack 通知) — 必要になったら EventBridge → SNS
