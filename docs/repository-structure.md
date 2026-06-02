# リポジトリ構成

```
ecs-migration-runner/
├── README.md                        ── プロジェクト概要 + クイックスタート
├── docs/                            ── 永続ドキュメント (常に最新)
│   ├── prd.md                       ── プロダクト要求仕様
│   ├── architecture.md              ── アーキテクチャ (ASCII + Mermaid)
│   ├── architecture.drawio          ── draw.io 形式の構成図 (aws4 アイコン)
│   ├── development-guide.md         ── 開発・デプロイ・運用手順
│   └── repository-structure.md      ── このファイル
├── .steering/                       ── 作業単位の計画・追跡 (削除しない)
│   └── 20260601-ecs-migration-runner/
│       ├── requirements.md          ── 初回構築の詳細要件
│       ├── design.md                ── 詳細設計
│       └── tasklist.md              ── 実装タスクとチェックボックス
├── infra/                           ── CloudFormation テンプレート
│   ├── network-data.cfn.yaml        ── VPC / Subnets / SG / RDS / Secrets
│   └── app.cfn.yaml                 ── ECR / ECS / IAM / OIDC Provider
├── migrations/
│   └── sql/                         ── Flyway SQL (V<n>__<name>.sql)
│       ├── V1__init.sql
│       └── V2__add_users.sql
├── docker/
│   └── Dockerfile                   ── flyway/flyway:10 + SQL COPY
└── .github/
    └── workflows/
        └── migrate.yml              ── OIDC → ECR build/push → ecs run-task
```

## 各ディレクトリの責務

| ディレクトリ | 責務 | 変更頻度 |
|---|---|---|
| `docs/` | 永続ドキュメント。仕様変更時に更新義務 | 中 |
| `.steering/` | 作業単位の計画。完了後も参照用に保持 | フェーズ毎 |
| `infra/` | CloudFormation。インフラ変更で更新 | 低 |
| `migrations/sql/` | Flyway SQL。スキーマ変更で **追記のみ** (既存ファイルの編集禁止) | 高 |
| `docker/` | Flyway イメージ定義 | 低 |
| `.github/workflows/` | CI/CD | 低 |

## 命名規則

- CloudFormation テンプレート: `*.cfn.yaml` (拡張子 `.yaml`、`cfn` 中置で識別性)
- Flyway SQL: `V<整数>__<snake_case>.sql` (Flyway 規約準拠)
- ロール名 (IAM): `ecs-migration-<purpose>-role` (kebab-case)
- スタック名: `migration-<layer>` (例: `migration-network-data`, `migration-app`)

DB テーブル名は **単数形** (CLAUDE.md 規約)。`users` ではなく `user` にする。
