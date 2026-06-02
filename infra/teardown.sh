#!/usr/bin/env bash
# 一時利用したリソースを全削除する
# 使い方: AWS 認証済みの状態で  bash infra/teardown.sh
#
# 削除順:
#   1) app スタック  (ECR / ECS / IAM)
#   2) network-data スタック (VPC / RDS は Snapshot を残して削除)
#   3) (任意) RDS Snapshot 削除
#   4) (任意) ECR イメージ削除
#
# 既存の GitHub OIDC Provider は他システムで使われている可能性があるので
# このスクリプトでは削除しない (CreateOIDCProvider=false で作ったため)

set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
NETWORK_STACK="${NETWORK_STACK:-migration-network-data}"
APP_STACK="${APP_STACK:-migration-app}"
ECR_REPO="${ECR_REPO:-flyway-migration}"

echo "==============================================="
echo " ECS migration runner - teardown"
echo "   region        : $REGION"
echo "   app stack     : $APP_STACK"
echo "   network stack : $NETWORK_STACK"
echo "==============================================="

confirm() {
    local msg="$1"
    read -r -p "$msg [y/N]: " ans
    case "$ans" in
        [yY] | [yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

stack_exists() {
    aws cloudformation describe-stacks --stack-name "$1" --region "$REGION" \
        >/dev/null 2>&1
}

# ===== 1) app スタック削除 =====
if stack_exists "$APP_STACK"; then
    if confirm "app スタック '$APP_STACK' を削除しますか？"; then
        # ECR Repository は image が残っていると CFN delete に失敗する。
        # `aws ecr delete-repository --force` で image ごと一発で削除しておく。
        # (CFN delete は Repository が既に無くても "削除済み扱い" で OK)
        if aws ecr describe-repositories --repository-names "$ECR_REPO" \
             --region "$REGION" >/dev/null 2>&1; then
            echo "ECR Repository ($ECR_REPO) を image ごと強制削除..."
            aws ecr delete-repository \
                --repository-name "$ECR_REPO" \
                --region "$REGION" \
                --force >/dev/null
            echo "ECR Repository 削除完了"
        fi

        echo "app スタック削除を開始..."
        aws cloudformation delete-stack --stack-name "$APP_STACK" --region "$REGION"
        aws cloudformation wait stack-delete-complete \
            --stack-name "$APP_STACK" --region "$REGION"
        echo "app スタック削除完了"
    fi
else
    echo "app スタックは存在しないのでスキップ"
fi

# ===== 2) network-data スタック削除 =====
if stack_exists "$NETWORK_STACK"; then
    if confirm "network-data スタック '$NETWORK_STACK' を削除しますか？ (RDS は Snapshot が残ります)"; then
        echo "network-data スタック削除を開始..."
        aws cloudformation delete-stack --stack-name "$NETWORK_STACK" --region "$REGION"
        aws cloudformation wait stack-delete-complete \
            --stack-name "$NETWORK_STACK" --region "$REGION"
        echo "network-data スタック削除完了"
    fi
else
    echo "network-data スタックは存在しないのでスキップ"
fi

# ===== 3) (任意) RDS Snapshot 削除 =====
echo ""
echo "残存している手動以外の DB Snapshot を一覧表示:"
aws rds describe-db-snapshots --region "$REGION" \
    --query 'DBSnapshots[?contains(DBSnapshotIdentifier, `migration`)].[DBSnapshotIdentifier,SnapshotCreateTime,Status]' \
    --output table || true

if confirm "上記の Snapshot を全削除しますか？"; then
    for snap in $(aws rds describe-db-snapshots --region "$REGION" \
        --query 'DBSnapshots[?contains(DBSnapshotIdentifier, `migration`)].DBSnapshotIdentifier' \
        --output text); do
        echo "削除: $snap"
        aws rds delete-db-snapshot --db-snapshot-identifier "$snap" --region "$REGION" \
            >/dev/null 2>&1 || echo "  (manual ではなく automated snapshot のためここでは消せない、下で対応)"
    done
fi

# ===== 4) (任意) 自動バックアップ (rds:xxx) を削除 =====
# DB instance を消しても automated snapshot (rds: プレフィックス) は retention 内は残る。
# delete-db-snapshot では消せず、delete-db-instance-automated-backup を使う必要がある。
echo ""
echo "残存している自動バックアップを一覧表示:"
aws rds describe-db-instance-automated-backups --region "$REGION" \
    --query 'DBInstanceAutomatedBackups[?contains(DBInstanceIdentifier, `migration`)].[DBInstanceIdentifier,DbiResourceId,Status]' \
    --output table || true

if confirm "自動バックアップも全削除しますか？ (放置でも retention 経過で自動削除される)"; then
    for rid in $(aws rds describe-db-instance-automated-backups --region "$REGION" \
        --query 'DBInstanceAutomatedBackups[?contains(DBInstanceIdentifier, `migration`)].DbiResourceId' \
        --output text); do
        echo "削除: $rid"
        aws rds delete-db-instance-automated-backup \
            --region "$REGION" --dbi-resource-id "$rid" >/dev/null
    done
    echo "自動バックアップ削除完了"
fi

echo ""
echo "==============================================="
echo " teardown 完了"
echo "==============================================="
