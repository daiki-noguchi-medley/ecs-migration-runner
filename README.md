# ecs-migration-runner

ECS Fargate の **one-shot タスク** で RDS PostgreSQL に **Flyway マイグレーション**を実行する基盤。
**GitHub Actions** が **OIDC 認証**で AWS にアクセスし、長期 IAM アクセスキーは使わない。

## アーキテクチャ

詳細は [docs/architecture.md](docs/architecture.md) と [docs/architecture.drawio](docs/architecture.drawio) を参照。

```
Developer ─push→ GitHub ─OIDC→ AWS STS ─→ GitHubActionsRole
                                            │
                                            ├─ ECR (image push)
                                            └─ ECS RunTask (Fargate / one-shot)
                                                    │
                                                    │ Private Subnet
                                                    ├──→ RDS PostgreSQL (Flyway migrate)
                                                    ├──→ Secrets Manager (RDS credentials)
                                                    └──→ CloudWatch Logs
```

### 全体シーケンス

```mermaid
sequenceDiagram
    autonumber
    actor Dev as 開発者
    participant Local as ローカル<br/>(docker compose)
    participant GH as GitHub
    participant GHA as GitHub Actions
    participant ECR as Amazon ECR
    participant ECS as ECS Fargate
    participant RDS as RDS PostgreSQL

    Note over Dev,Local: ① ローカルで SQL を試作・検証
    Dev->>Local: make up
    Local->>Local: postgres + flyway を起動<br/>V1..Vn 適用
    Dev->>Local: make psql でテーブル確認

    Note over Dev,GH: ② PR で main にマージ
    Dev->>GH: git push & gh pr create
    Dev->>GH: PR merge

    Note over GH,GHA: ③ create_git_tag.yml が auto tag
    GH->>GHA: PR merged event
    GHA->>GH: v0.x.0 / v0.0.x tag を push

    Note over Dev,RDS: ④ Actions タブで migrate を手動起動
    Dev->>GHA: workflow_dispatch<br/>(Use workflow from = v0.x.0)
    GHA->>GHA: OIDC で AWS Role 引き受け
    GHA->>ECR: docker build & push<br/>(:v0.x.0 + :latest retag)
    GHA->>ECS: run-task (Fargate, one-shot)
    ECS->>RDS: connect & Flyway migrate
    RDS-->>ECS: flyway_schema_history 更新
    ECS-->>GHA: exit code 0
    GHA-->>Dev: 完了 (CloudWatch Logs を Job log に tail)
```

## 責務分担

| レイヤ | 担当 | タイミング |
|---|---|---|
| **インフラ** (VPC / RDS / ECS Cluster / Task Definition / ECR / IAM) | `infra/*.cfn.yaml` を **手動** で `aws cloudformation deploy` | 初回構築 / 構成変更時のみ |
| **マイグレーション資産** (SQL / Dockerfile) | Git で管理 (`migrations/sql/`, `docker/`) | 機能追加時 |
| **マイグレーション実行** | GitHub Actions (`migrate.yml`) **手動 workflow_dispatch** | リリースごと、PR merge → auto tag → tag 選択して起動 |

GitHub Actions は **インフラを作らない**。`describe-stacks` 等で CFN を読まないので、CFN 構成が変わっても workflow は影響を受けない（GitHub Variables を更新するだけで追従）。

## クイックスタート

### 1. インフラをデプロイ (初回 or 構成変更時のみ、手動)

```sh
# AWS CLI の認証は事前に設定 (aws configure / SSO 等)

# (1) Network + Data 層 (約 10 分、RDS 作成)
aws cloudformation deploy \
  --stack-name migration-network-data \
  --template-file infra/network-data.cfn.yaml \
  --capabilities CAPABILITY_NAMED_IAM

# (2) App 層 (約 2 分、ECR + ECS + IAM)
aws cloudformation deploy \
  --stack-name migration-app \
  --template-file infra/app.cfn.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      GitHubOrg=YOUR_ORG \
      GitHubRepo=ecs-migration-runner
```

> OIDC Provider がアカウントに既にある場合は `CreateOIDCProvider=false` を追加。

### 2. GitHub リポジトリ設定

`Settings → Secrets and variables → Actions` で以下を登録:

| 種別 | 名前 | 値 (例) |
|------|------|----|
| **Secret** | `AWS_ROLE_ARN` | `migration-app` スタックの `GitHubActionsRoleArn` 出力 |
| Variable | `AWS_REGION` | `ap-northeast-1` |
| Variable | `ECR_REPOSITORY` | `flyway-migration` |
| Variable | `ECS_CLUSTER` | `migration-runner` |
| Variable | `ECS_TASK_FAMILY` | `flyway-migration` |
| Variable | `ECS_SUBNETS` | `subnet-aaa,subnet-bbb` (private subnet をカンマ区切り) |
| Variable | `ECS_SECURITY_GROUPS` | `sg-xxx` |
| Variable | `ECS_LOG_GROUP` | `/ecs/flyway-migration` |
| Variable | `ECS_LOG_STREAM_PREFIX` | `flyway` (タスク定義の `awslogs-stream-prefix` と一致させる) |

### 3. 運用フロー (PR → auto tag → migrate)

```
[作業ブランチ]
  feature/add-post-table
    └─ migrations/sql/V3__add_post.sql を追加
                ↓ PR
[main]
    └─ merge
                ↓ create_git_tag.yml が自動実行
[tag] v0.2.0 (bugfix/* なら patch、それ以外は minor)
                ↓ Actions タブで migrate workflow を手動起動
                ↓   Use workflow from = v0.2.0
[ECR push + ECS run-task]
    └─ Flyway がその tag 時点の SQL を適用
```

実行コマンド例 (CLI):

```sh
# 1. SQL を追加して PR
git checkout -b feature/add-post-table
cat > migrations/sql/V3__add_post.sql <<'SQL'
CREATE TABLE IF NOT EXISTS "post" (
    id         UUID NOT NULL DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL REFERENCES "user"(id),
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT post_pkey PRIMARY KEY (id)
);
SQL
git add migrations/sql/V3__add_post.sql
git commit -m "feat(migration): add post table"
git push -u origin feature/add-post-table
gh pr create --base main --title "feat: add post table" --body "..."

# 2. PR を merge → create_git_tag.yml が走り、v0.2.0 が打たれる
gh pr merge --squash --delete-branch

# 3. 新タグで migrate を起動
gh workflow run migrate.yml --ref v0.2.0
gh run watch
```

## ローカル開発

ローカル開発には **2 つのモード** があります。どちらでも動作確認できます。

### 必要なもの

| 項目 | macOS | Windows | Linux |
|-----|-------|---------|-------|
| Docker Desktop | ✅ | ✅ | Docker CE |
| make | ✅ (標準) | ⚠️ WSL2 推奨 | ✅ (標準) |
| VSCode | オプション | オプション | オプション |

**Windows での make コマンド:**
- **推奨**: WSL2 + Ubuntu で実行
- または Git Bash（`make` をインストール）
- または `docker compose` コマンド直接実行

#### 環境自動判定

Makefile が OS を自動判定します：

```bash
make os-check  # 検出環境を表示
```

### モード A: ローカル Compose（シンプル）

`docker-compose.yml` を使用。PostgreSQL + Flyway のみで、Gradle はローカル環境に依存。

```bash
make up                # PostgreSQL + Flyway 起動
make spotless-fix      # SQL フォーマット（ローカル Gradle があれば）
make psql              # DB 接続
make down              # コンテナ停止
```

**利点**: シンプル、低リソース  
**欠点**: Gradle のインストール必要（Windows では手間）

---

### モード B: Dev Container（推奨・クロスプラットフォーム）

VSCode で `.devcontainer/` を使用。Java + Gradle + PostgreSQL + Flyway を完全統合。

```bash
# VSCode で以下のいずれかを実行
make devcontainer-up        # Dev Container を開く（推奨）
# または手動で "Dev Containers: Open Folder in Container" コマンド実行
```

#### Dev Container 内での開発フロー

```bash
# PostgreSQL + Flyway が自動起動されます（初回は数十秒待機）

# SQL をフォーマット
make gradle-fix              # Dev Container 内で Spotless Apply

# DB の状態確認
make info                    # マイグレーション一覧
make psql                    # psql で接続

# テーブル確認
make psql
# psql> \dt
# psql> SELECT * FROM "user";
# psql> \q
```

**利点（モード B）**:
- ✅ ローカルは Docker Desktop のみ（Java / Gradle / PostgreSQL 不要）
- ✅ Mac / Windows / Linux で 100% 同じ環境
- ✅ VSCode の Gradle プラグインが Docker 内で動作
- ✅ PostgreSQL + Flyway が自動で同時起動
- ✅ CI/CD と同じ環境で開発・検証可能
- ✅ チーム全員が同じ `.devcontainer/` で再現性 100%

**選択基準**:
- Windows ユーザー → **モード B 推奨**（Gradle インストール不要）
- Mac / Linux → **どちらでも OK**（好みで選択）

### クイックスタート

```sh
make up        # postgres 起動 + Flyway で migration 適用
make info      # 適用済み migration 一覧
make psql      # DB に対話接続 (\dt でテーブル確認、\q で抜ける)
make reset     # 完全初期化 (data volume も削除)
```

### Makefile ターゲット一覧

#### 環境確認
| ターゲット | 内容 |
|---|---|
| `make help` | ターゲット一覧を表示 |
| `make os-check` | 検出環境（OS、Docker、make）を表示 |

#### モード A: ローカル Compose
| ターゲット | 内容 |
|---|---|
| `make up` (= `make migrate`) | DB 起動 + Flyway migrate |
| `make info` | 適用済み migration 一覧 |
| `make validate` | SQL の構文 + checksum 検証 |
| `make clean` | スキーマ全消去 (開発限定) |
| `make psql` | DB に psql で対話接続 |
| `make logs` | DB のログを tail |
| `make status` | コンテナ / volume の状態 |
| `make down` | 停止 (data volume 維持) |
| `make reset` | 停止 + data volume 削除 (DB 初期化) |
| `make spotless-check` | SQL フォーマット検証（ローカル Gradle） |
| `make spotless-fix` | SQL 自動フォーマット（ローカル Gradle） |

#### モード B: Dev Container
| ターゲット | 内容 |
|---|---|
| `make devcontainer-up` | Dev Container を VSCode で起動 |
| `make devcontainer-stop` | Dev Container を停止 |
| `make devcontainer-logs` | Dev Container のログを表示 |
| `make devcontainer-shell` | Dev Container のシェルに入る |
| `make gradle-check` | Dev Container 内で SQL フォーマット検証 |
| `make gradle-fix` | Dev Container 内で SQL 自動フォーマット |
| `make gradle-build` | Dev Container 内で Gradle ビルド |
| `make gradle-clean` | Dev Container 内で Gradle クリーン |

#### その他
| ターゲット | 内容 |
|---|---|
| `make build` | 本番用 `docker/Dockerfile` を `linux/amd64` で build |
| `make clean-gradle-cache` | Gradle キャッシュ削除 |
| `make docker-prune` | Docker ダングリング削除 |

### ローカル起動シーケンス

```mermaid
sequenceDiagram
    autonumber
    actor Dev as 開発者
    participant Make as make /<br/>docker compose
    participant DB as db<br/>(postgres:16-alpine)
    participant FW as flyway<br/>(flyway:10-alpine)

    Dev->>Make: make up
    Make->>DB: docker compose up db
    DB->>DB: 起動 + pg_isready (healthcheck)
    Note over Make,DB: healthy になるまで待機
    Make->>FW: docker compose up flyway<br/>(depends_on: db healthy)
    FW->>DB: connect jdbc:postgresql://db:5432/appdb
    FW->>DB: CREATE TABLE flyway_schema_history
    FW->>DB: apply V1__init.sql, V2__add_user.sql
    FW-->>Make: exit 0
    Dev->>Make: make psql
    Make->>DB: psql -U appuser -d appdb
    DB-->>Dev: \dt / SELECT で確認

    Note over Dev,DB: ── SQL を追加して再実行 ──
    Dev->>Dev: migrations/sql/V3__... を追加
    Dev->>Make: make up
    Make->>FW: 再起動
    FW->>DB: 既適用は skip<br/>V3 のみ apply (冪等)
```

### ローカルと本番の違い

| 項目 | ローカル (compose) | 本番 (ECS) |
|---|---|---|
| イメージ | `flyway/flyway:10-alpine` を直接利用 | `docker/Dockerfile` で SQL を COPY したカスタム image (ECR) |
| SQL の渡し方 | volume mount (`./migrations/sql:/flyway/sql:ro`) | image に COPY 済み |
| DB | コンテナ (`postgres:16-alpine`) | RDS PostgreSQL 16 (private subnet) |
| credentials | ベタ書きの `localpass` (ローカル限定) | Secrets Manager → ECS task definition の `secrets` で注入 |
| 起動 | `make up` | `gh workflow run migrate.yml --ref v0.x.0` |
| port 公開 | `localhost:5432` (psql 直接接続可) | 非公開 (VPC 内のみ) |
| クリーンアップ | `make reset` で data volume 削除 | `bash infra/teardown.sh` で CFN ごと削除 |

## ディレクトリ構成

詳細は [docs/repository-structure.md](docs/repository-structure.md) を参照。

```
.
├── docs/                  ── 永続ドキュメント
├── infra/                 ── CloudFormation (network-data / app) + teardown.sh
├── migrations/sql/        ── Flyway SQL (V<n>__<name>.sql, 追記のみ)
├── docker/                ── 本番用 Flyway イメージ定義 (ECR push 用)
├── .devcontainer/         ── VSCode Dev Container 設定 (Java + Gradle)
├── docker-compose.yml     ── ローカル用 (PG + Flyway)
├── spotless.gradle.kts    ── Spotless SQL フォーマット設定
├── Makefile               ── ローカル用ショートカット (make help)
└── .github/workflows/     ── migrate / create_git_tag / lint (GitHub Actions)
```

## SQL フォーマット・Lint ルール（Spotless）

Spotless を使用して、SQL ファイルのフォーマットを統一・検証します。

```bash
# ローカルでチェック
make spotless-check

# 自動修正
make spotless-fix
```

**ルール**:
- インデント: タブ (2 スペース相当)
- フォーマッター: DBeaver SQL フォーマッター
- 末尾: 改行で終了

PR 時に GitHub Actions (`lint.yml`) が自動実行され、フォーマット違反があるとコメントされます。

## マイグレーション運用ルール

- **V<n>__<name>.sql の連番ファイル**を追加する
- **既存ファイルの編集は禁止** (Flyway の checksum と不一致になる)
- ロールバックは「打ち消し migration を追加」で行う (OSS Flyway は undo 非対応)
- テーブル名は **単数形** (`user`, `post`)、複数件を表すコードは `~List` サフィックス (CLAUDE.md 規約)
- **SQL フォーマット**: `make spotless-fix` で統一（PR 前に実行推奨）

## トラブルシュート

| 症状 | 確認ポイント |
|------|------------|
| Actions が `AccessDenied` で落ちる | `AWS_ROLE_ARN` 設定 / OIDC 信頼ポリシーの `repo:org/repo:*` 一致 |
| Flyway が DB に繋がらない | RDS SG の inbound 5432 / private subnet のルートテーブル / Secrets Manager の権限 |
| ECR push が遅い | NAT 経由なら数十秒〜。気になるなら ECR の VPC エンドポイントを後付け |
| `flyway_schema_history` の checksum 不一致 | 既存 SQL を編集した可能性。`flyway repair` で修復 (新規 migration で置き換え推奨) |

## 元ネタ

本構成は以下の記事を参考にし、シンプル化・OIDC 対応・最新化を加えた:

- [GitHub Actions で RDS マイグレーション (zenn / hisamitsu)](https://zenn.dev/hisamitsu/articles/a1ff756a194961) — one-shot タスクで重複回避するアイデア
- [Flyway 入門 (tech-lab.sios.jp)](https://tech-lab.sios.jp/archives/35525) — Flyway の SQL バージョン管理規約
- AWS 公式: [Running an application as an Amazon ECS task](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/standalone-task-create.html)
- GitHub 公式: [Configuring OpenID Connect in Amazon Web Services](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)

## ライセンス

社内利用想定。MIT 相当で OK。
