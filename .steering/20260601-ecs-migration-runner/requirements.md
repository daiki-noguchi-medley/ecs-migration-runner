# 要件定義: ECS one-shot タスクによる RDS マイグレーション基盤 (初回構築)

## 0. ステアリング ID

`20260601-ecs-migration-runner`

## 1. 目的

GitHub Actions から OIDC 認証で AWS にアクセスし、ECS Fargate の one-shot タスクで RDS PostgreSQL に Flyway マイグレーションを適用する基盤を、CloudFormation で再現可能な形で初回構築する。

## 2. 機能要件 (Functional)

### FR-1: Flyway マイグレーション資産の管理
- `migrations/sql/V<n>__<name>.sql` の形式で SQL を管理する
- ファイル名の規約は Flyway 標準に従う

### FR-2: GitHub Actions のトリガー
- `push` 時、対象は `main` ブランチかつ `migrations/**` または `docker/**` 配下の変更があったとき
- `workflow_dispatch` (手動実行) もサポート

### FR-3: AWS 認証
- 長期 IAM アクセスキーは使用しない
- GitHub OIDC Provider を経由した `sts:AssumeRoleWithWebIdentity` を使う
- 信頼ポリシーは `repo:<org>/<repo>:ref:refs/heads/main` および `repo:<org>/<repo>:environment:*` 相当に絞る

### FR-4: ビルド・プッシュ
- GitHub Actions が Docker イメージをビルドし、ECR にプッシュ
- タグは `git sha` (短縮) と `latest` の 2 つ

### FR-5: ECS run-task によるマイグレーション実行
- `aws ecs run-task` で one-shot 実行 (`count=1`, `launch-type=FARGATE`)
- private subnet に配置、`assignPublicIp=DISABLED`
- 環境変数 (DB URL/ユーザ/パスワード) は Secrets Manager から `secrets` で注入

### FR-6: タスク完了待機とログ取得
- `aws ecs wait tasks-stopped` で終了を待つ
- `describe-tasks` でコンテナ exit code を取得し、0 以外なら GitHub Actions の job を失敗にする
- CloudWatch Logs からログを取り、Actions のジョブログに出力

## 3. 非機能要件 (Non-Functional)

### NFR-1: シンプル性
- CloudFormation スタックは **2 つまで** (`network-data` / `app`)
- VPC Endpoints は初期は **使わない** (NAT 経由)
- パラメータは最低限 (5 個以下)

### NFR-2: セキュリティ
- RDS は **private subnet** に配置、外部から直接アクセス不可
- DB credentials は **Secrets Manager** で管理、CloudFormation の `ManageMasterUserPassword: true` を使う
- IAM ロールは **最小権限の原則**
  - GitHubActionsRole: ECR push / ECS RunTask / iam:PassRole (対象を `Resource` 指定で絞る) / logs:GetLogEvents
  - ECSTaskExecutionRole: AWS マネージドポリシー `AmazonECSTaskExecutionRolePolicy` + Secrets Manager Read
  - FlywayTaskRole: 空 (信頼関係のみ)

### NFR-3: コスト
- Fargate タスクサイズ: **0.25 vCPU / 512 MB** (最小)
- RDS: **db.t4g.micro** / GP3 20GB / Multi-AZ off
- NAT Gateway は **1 つ** (シングル AZ、コスト最適化)
- ECR: ライフサイクルポリシーで `latest` 以外は 10 個以上を削除

### NFR-4: 再現可能性
- すべて CloudFormation でデプロイ可能
- 手動操作は不要 (OIDC Provider の重複時の `ExistingOIDCProvider` パラメータ切り替えのみ例外)

### NFR-5: 観測性
- CloudWatch Logs ロググループ: `/ecs/flyway-migration`
- リテンション: 30 日

## 4. 制約

- AWS リージョン: 環境変数 / パラメータで切替可能。デフォルト `ap-northeast-1`
- RDS バージョン: PostgreSQL **16.x** (最新マイナー)
- Flyway バージョン: **10.x** (`flyway/flyway:10` 系)
- GitHub Actions ランナー: `ubuntu-latest`

## 5. 受け入れ基準 (Acceptance Criteria)

| ID | Given | When | Then |
|----|-------|------|------|
| AC-1 | 2 つのスタックが正常デプロイされている | `migrations/sql/V2__add_users.sql` を main に push | GitHub Actions が 5 分以内に成功し、RDS の `flyway_schema_history` に V2 行が追加されている |
| AC-2 | 既に V2 が適用済み | 同じ V2 を再 push | Flyway は no-op で成功終了、`schema_history` に重複行は追加されない |
| AC-3 | V2 の SQL に構文エラーがある | push | Actions が失敗、CloudWatch Logs にエラー詳細、ジョブログにも tail される |
| AC-4 | IAM ユーザーのアクセスキーを GitHub Secrets に登録していない | Actions 実行 | OIDC で成功 |
| AC-5 | `aws cloudformation delete-stack` で app スタックを削除 | network-data スタックは残る | RDS と SQL 適用履歴は失われない |

## 6. リスクと緩和策

| リスク | 影響 | 緩和策 |
|--------|------|--------|
| OIDC Provider がアカウントに既に存在 | デプロイ失敗 | `ExistingOIDCProvider` パラメータで条件分岐 |
| RDS への接続が SG/Routing で塞がれる | マイグレーション失敗 | private subnet 同士の SG ルールで 5432 を許可、ルートテーブル確認 |
| ECR への push が `iam:PassRole` 不足で失敗 | デプロイ後の初回実行で失敗 | 信頼ポリシーで `iam:PassRole` を `ECSTaskExecutionRole` と `FlywayTaskRole` ARN 限定で付与 |
| Flyway の checksum 不一致 | 既存 SQL を変更したケース | 「既存ファイルの編集禁止」を development-guide.md に明記 |

## 7. スコープ外 (本ステアリングでは扱わない)

- マルチ環境 (dev/stg/prod 分離)
- アラート連携 (SNS / Slack)
- アプリケーション本体のデプロイ
- bastion / SSM Session Manager の構築 (運用フェーズで追加)
