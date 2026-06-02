# 開発ガイド

## 1. 必要なツール

| ツール | 用途 | 備考 |
|---|---|---|
| AWS CLI v2 | スタックデプロイ・タスク確認 | `aws --version` で確認 |
| Docker | ローカルでイメージビルド確認 | 必須ではない (GitHub Actions で build) |
| psql | RDS への直接確認 | bastion 経由 / SSM Session Manager 推奨 |
| jq | JSON 整形 | デプロイスクリプトで使用 |

ローカルで Flyway を試すなら:
```sh
docker run --rm -v "$(pwd)/migrations/sql:/flyway/sql" flyway/flyway:10 info
```

## 2. 初回セットアップ手順

```sh
# 1) network-data スタック (VPC + RDS + Secrets)
aws cloudformation deploy \
  --stack-name migration-network-data \
  --template-file infra/network-data.cfn.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides DBName=appdb DBUsername=appuser

# 2) app スタック (ECR + ECS + IAM + OIDC)
aws cloudformation deploy \
  --stack-name migration-app \
  --template-file infra/app.cfn.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      NetworkStackName=migration-network-data \
      GitHubOrg=YOUR_ORG \
      GitHubRepo=ecs-migration-runner
```

OIDC Provider が既にアカウントに存在する場合は、`app.cfn.yaml` の `ExistingOIDCProvider=true` を渡してスキップする。

## 3. マイグレーション追加の流れ

1. `migrations/sql/V<次の連番>__<説明>.sql` を作成
   - 例: `V2__add_users_table.sql`
2. ローカルで構文チェック (任意):
   ```sh
   docker run --rm -v "$(pwd)/migrations/sql:/flyway/sql" flyway/flyway:10 validate
   ```
3. ブランチを切ってコミット → PR → main マージ
4. GitHub Actions の `migrate` ワークフローが自動起動
5. Actions の "Run migration on ECS" ステップで成否を確認

## 4. ロールバック方針

Flyway OSS 版は `undo` をサポートしないので、**打ち消しの migration を追加する** 運用にする。

- 例: `V3__drop_users_table.sql` で `V2` を打ち消す
- `flyway repair` は `flyway_schema_history` の修正用 (ハッシュ不一致や FAILED 行のリセット)、ロールバックではない

## 5. ローカル動作確認

`docker-compose.yml` を追加すれば PostgreSQL + Flyway をローカルで再現できる (本リポジトリでは初期は提供しない)。

```yaml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: localpass
  flyway:
    image: flyway/flyway:10
    depends_on: [db]
    volumes: ["./migrations/sql:/flyway/sql"]
    command: -url=jdbc:postgresql://db:5432/postgres -user=postgres -password=localpass migrate
```

## 6. コミット規約

Conventional Commits を踏襲 (CLAUDE.md ルール準拠):

```
feat(migration): add users table
fix(infra): use t4g.micro instead of t3.micro
chore(workflow): pin actions to SHA
```

PR 本文末尾の `🤖 Generated with Claude Code` 定型文と `Co-Authored-By: Claude` は付けない。

## 7. CloudWatch Logs の見方

```sh
aws logs tail /ecs/flyway-migration --follow
```

ECS タスクの ARN から最新ログを引く:
```sh
aws ecs describe-tasks --cluster migration-runner --tasks <task-arn> \
  --query 'tasks[0].containers[0].logStreamName'
```
