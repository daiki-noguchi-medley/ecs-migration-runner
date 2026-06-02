# 設計書: ECS one-shot タスクによる RDS マイグレーション基盤

## 0. 概要

要件 (requirements.md) を満たす最小構成。CloudFormation 2 スタック + Docker + GitHub Actions ワークフロー。

## 1. スタック構成

### 1.1 `network-data` スタック

| リソース論理 ID | タイプ | 主な設定 |
|----------------|--------|----------|
| `VPC` | `AWS::EC2::VPC` | CIDR `10.0.0.0/16`、`EnableDnsSupport=true`、`EnableDnsHostnames=true` |
| `IGW` | `AWS::EC2::InternetGateway` | VPC にアタッチ |
| `PublicSubnetA` | `AWS::EC2::Subnet` | `10.0.0.0/24` (AZ-a)、`MapPublicIpOnLaunch=true` |
| `PrivateSubnetA` | `AWS::EC2::Subnet` | `10.0.10.0/24` (AZ-a) |
| `PrivateSubnetB` | `AWS::EC2::Subnet` | `10.0.11.0/24` (AZ-b) |
| `NatEip` | `AWS::EC2::EIP` | NAT 用 |
| `NatGateway` | `AWS::EC2::NatGateway` | PublicSubnetA に配置 |
| `PublicRouteTable` | `AWS::EC2::RouteTable` | IGW 経由 default |
| `PrivateRouteTable` | `AWS::EC2::RouteTable` | NAT GW 経由 default |
| `RDSSecurityGroup` | `AWS::EC2::SecurityGroup` | inbound 5432 from `ECSTaskSG`、outbound 全許可 |
| `ECSTaskSG` | `AWS::EC2::SecurityGroup` | inbound なし、outbound 全許可 (RDS, ECR, Secrets, Logs へ) |
| `DBSubnetGroup` | `AWS::RDS::DBSubnetGroup` | PrivateSubnetA/B |
| `DBInstance` | `AWS::RDS::DBInstance` | PG 16、`db.t4g.micro`、20GB GP3、`ManageMasterUserPassword=true` (Secrets Manager 自動生成) |

**Outputs (Export)**:
- `VpcId`, `PrivateSubnetAId`, `PrivateSubnetBId`
- `ECSTaskSGId`
- `DBSecretArn` (`!GetAtt DBInstance.MasterUserSecret.SecretArn`)
- `DBEndpoint`, `DBPort`, `DBName`

### 1.2 `app` スタック

| リソース論理 ID | タイプ | 主な設定 |
|----------------|--------|----------|
| `ECRRepository` | `AWS::ECR::Repository` | `flyway-migration`、`ImageScanningConfiguration.ScanOnPush=true`、LifecyclePolicy (`latest` 以外は最新 10 個まで保持) |
| `LogGroup` | `AWS::Logs::LogGroup` | `/ecs/flyway-migration`、`RetentionInDays=30` |
| `ECSCluster` | `AWS::ECS::Cluster` | `migration-runner`、Container Insights off (コスト) |
| `TaskExecutionRole` | `AWS::IAM::Role` | `AmazonECSTaskExecutionRolePolicy` + Secrets Manager Read (DBSecretArn) |
| `FlywayTaskRole` | `AWS::IAM::Role` | 信頼関係のみ (タスク内部で AWS API 呼ばない) |
| `TaskDefinition` | `AWS::ECS::TaskDefinition` | `RequiresCompatibilities=[FARGATE]`, cpu=`256`, memory=`512`、コンテナ 1 個 |
| `OIDCProvider` | `AWS::IAM::OIDCProvider` | `Condition: CreateOIDCProvider` で切替 |
| `GitHubActionsRole` | `AWS::IAM::Role` | `sts:AssumeRoleWithWebIdentity`、信頼ポリシーで `sub` を `repo:<org>/<repo>:*` に絞る |

**インポート**: network-data の Export を `!ImportValue` で参照

### 1.3 タスク定義の詳細

```yaml
ContainerDefinitions:
  - Name: flyway
    Image: !Sub "${ECRRepository.RepositoryUri}:latest"
    Essential: true
    Command: ["migrate"]
    Environment:
      - { Name: FLYWAY_URL,       Value: !Sub "jdbc:postgresql://${DBEndpoint}:${DBPort}/${DBName}" }
      - { Name: FLYWAY_LOCATIONS, Value: "filesystem:/flyway/sql" }
    Secrets:
      - { Name: FLYWAY_USER,     ValueFrom: !Sub "${DBSecretArn}:username::" }
      - { Name: FLYWAY_PASSWORD, ValueFrom: !Sub "${DBSecretArn}:password::" }
    LogConfiguration:
      LogDriver: awslogs
      Options:
        awslogs-group: !Ref LogGroup
        awslogs-region: !Ref AWS::Region
        awslogs-stream-prefix: flyway
```

**ポイント**:
- `Secrets` の `ValueFrom` で Secrets Manager の JSON フィールドを直接指定 (`:username::`, `:password::`)。`GetSecretValue` + `jq` 等のサイドカーは不要
- `Command: ["migrate"]` で Flyway の動作を固定

## 2. IAM 設計

### 2.1 GitHubActionsRole (信頼ポリシー)

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<acct>:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:<org>/<repo>:*" }
    }
  }]
}
```

### 2.2 GitHubActionsRole (権限ポリシー)

```yaml
- ecr:GetAuthorizationToken          (Resource: "*")
- ecr:BatchCheckLayerAvailability    (Resource: <ECRArn>)
- ecr:InitiateLayerUpload            (Resource: <ECRArn>)
- ecr:UploadLayerPart                (Resource: <ECRArn>)
- ecr:CompleteLayerUpload            (Resource: <ECRArn>)
- ecr:PutImage                       (Resource: <ECRArn>)
- ecr:BatchGetImage                  (Resource: <ECRArn>)
- ecs:RunTask                        (Resource: TaskDefinition ARN)
- ecs:DescribeTasks                  (Resource: <task ARN pattern>)
- iam:PassRole                       (Resource: [TaskExecutionRole.Arn, FlywayTaskRole.Arn])
- logs:GetLogEvents                  (Resource: LogGroup ARN + ":log-stream:*")
- logs:DescribeLogStreams            (Resource: LogGroup ARN)
```

### 2.3 TaskExecutionRole

- マネージド: `arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy`
- インライン:
  ```yaml
  - secretsmanager:GetSecretValue   (Resource: DBSecretArn)
  ```

### 2.4 FlywayTaskRole

信頼ポリシーのみ (`ecs-tasks.amazonaws.com`)。権限ポリシーなし。

## 3. ネットワーク設計

```
VPC 10.0.0.0/16
├── Public  10.0.0.0/24   AZ-a   ─ IGW へ default ─┬─ NAT Gateway
├── Private 10.0.10.0/24  AZ-a   ─ NAT 経由 default ─┐
└── Private 10.0.11.0/24  AZ-b   ─ NAT 経由 default ─┘
   ├ ECS Task ──5432──► RDS
   └ ECS Task ──443──► ECR / Secrets Manager / CloudWatch Logs (NAT 経由)
```

**SG ルール**:
- `ECSTaskSG`: outbound `0.0.0.0/0:*` (シンプル化、最初は緩く)
- `RDSSecurityGroup`: inbound `5432` from `ECSTaskSG` のみ

## 4. Docker イメージ設計

```Dockerfile
# docker/Dockerfile
FROM flyway/flyway:10-alpine
COPY migrations/sql /flyway/sql
# ENTRYPOINT は upstream の `flyway` を踏襲
# CMD はタスク定義側の Command で上書き
```

- ビルドコンテキストはリポジトリルート
- `flyway/flyway:10-alpine` (約 100MB) を選定。`-alpine` で軽量化

## 5. GitHub Actions ワークフロー設計

`.github/workflows/migrate.yml`:

```
on:
  push:
    branches: [main]
    paths: ["migrations/**", "docker/**", ".github/workflows/migrate.yml"]
  workflow_dispatch:
permissions:
  id-token: write
  contents: read
jobs:
  migrate:
    runs-on: ubuntu-latest
    steps:
      1. actions/checkout
      2. aws-actions/configure-aws-credentials (OIDC, role-to-assume)
      3. aws-actions/amazon-ecr-login
      4. docker build -t $ECR:$SHA -t $ECR:latest -f docker/Dockerfile .
      5. docker push $ECR:$SHA && docker push $ECR:latest
      6. aws ecs run-task → task ARN
      7. aws ecs wait tasks-stopped --tasks <ARN>
      8. aws ecs describe-tasks → exit code
      9. aws logs get-log-events → 出力 tail
     10. exit code が 0 以外なら job 失敗
```

すべての action は **SHA pin** (`uses: aws-actions/configure-aws-credentials@<sha>`)。

## 6. パラメータ一覧

### network-data スタック

| Name | Type | Default | 用途 |
|------|------|---------|------|
| `DBName` | String | `appdb` | データベース名 |
| `DBUsername` | String | `appuser` | マスターユーザー名 |
| `DBInstanceClass` | String | `db.t4g.micro` | RDS インスタンスクラス |

### app スタック

| Name | Type | Default | 用途 |
|------|------|---------|------|
| `NetworkStackName` | String | `migration-network-data` | Export 参照元 |
| `GitHubOrg` | String | (必須) | GitHub Organization |
| `GitHubRepo` | String | (必須) | GitHub Repository |
| `CreateOIDCProvider` | String (`true`/`false`) | `true` | 既に存在なら false |

## 7. デプロイ順

1. `network-data` スタックをデプロイ (約 10 分、RDS 作成待ち)
2. `app` スタックをデプロイ (約 2 分)
3. GitHub Actions の Secrets に `AWS_ROLE_ARN` (= GitHubActionsRole ARN) と `AWS_REGION` を設定
4. リポジトリで GitHub Environment を作る場合は信頼ポリシーに `environment:<name>` を追加

## 8. 失敗時の挙動

| 失敗箇所 | 挙動 |
|---------|------|
| ECR push 失敗 | Actions step 失敗、job 失敗 |
| run-task 失敗 (API エラー) | step 失敗 |
| run-task は成功するがタスクが起動失敗 | `wait tasks-stopped` で帰ってきた後 `containers[].exitCode` 非 0 → step 失敗 |
| Flyway 失敗 (SQL エラー) | exitCode 1、ログに詳細、Actions 失敗 |

## 9. 採用した記事の良いところ・捨てたところ

### 採用
- Zenn (hisamitsu): **`override-container-command` で migrate 注入する考え方** → 本構成では Container Override の代わりに Task Definition の `Command` を直接 `["migrate"]` 固定。シンプル化
- Zenn: **「ECS 起動時マイグレーションは重複する」という問題提起** → one-shot タスクで解決
- Sios (Flyway 解説): **Flyway の `V<n>__<name>.sql` 規約と SQL 直書きの分かりやすさ** → 採用

### 捨てた
- Zenn: **`noelzubin/aws-ecs-run-task` サードパーティ Action** → AWS 公式 CLI で十分。依存を減らす
- Zenn: **CodePipeline 状態監視ループ** → 本構成では Amplify/CodePipeline を使わないので不要
- Zenn: **長期 IAM アクセスキー方式** → OIDC に置き換え
- Zenn: **`actions/checkout@v2`、バージョン pin なし** → SHA pin に
