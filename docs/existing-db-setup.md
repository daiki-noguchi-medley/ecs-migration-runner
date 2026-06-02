# 既存 DB への Flyway 統合ガイド

既に運用中のデータベースに Flyway を導入する場合のセットアップ手順です。

## シナリオ

### 現状
- PostgreSQL DB が既に存在（V1 で初期化済み）
- テーブル定義はスクリプトではなく、手動で作成されている
- これから Flyway でバージョン管理したい

### 目標
- 既存テーブルを Flyway で管理
- 新規マイグレーション（V2 以降）は Flyway で実行
- 既存テーブルの定義は SQL ファイルとして保存

---

## セットアップ手順

### ステップ 1: 既存スキーマをダンプ

DB にアクセスしたい環境で実行：

```bash
# ローカル Docker Compose の場合
make up              # DB を起動

# 別ターミナルで
make dump-schema    # 既存テーブルを SQL ファイルに出力
```

**出力ファイル**: `migrations/sql/V0__baseline.sql`

**内容**（例）:
```sql
-- スキーマダンプ（自動生成）
CREATE TABLE IF NOT EXISTS "user" (
    id UUID NOT NULL DEFAULT gen_random_uuid(),
    email VARCHAR(255) NOT NULL,
    name VARCHAR(100) NOT NULL,
    ...
);

CREATE INDEX user_status_idx ON "user"(status);

COMMENT ON TABLE "user" IS 'アプリ利用者';
```

### ステップ 2: スキーマダンプを確認・編集

```bash
# 内容を確認
cat migrations/sql/V0__baseline.sql

# 不要な部分を手動削除（拡張機能など）
# 例: COMMENT ON EXTENSION, pg_stat_statements など
```

### ステップ 3: Baseline を初期化

**Baseline** = 「ここまでは既に DB に適用済み」という印

```bash
make baseline-init
# プロンプト: Baseline Version を入力 (デフォルト: 1.0)
# → 1.0 と入力（または空欄で Enter）
```

**何が起きるか**:
- `flyway_schema_history` テーブルに以下のレコードが追加される：
  ```
  version | description                    | installed_on | success
  --------|--------------------------------|--------------|--------
  0       | << Baseline >>                 | (now)        | 1
  ```
- V0__baseline.sql は **実行されない**（既に テーブルが存在するため）

### ステップ 4: 動作検証

```bash
# Flyway 履歴を確認
make info

# 出力例:
# Database: ...
# +---------+---------+-----+--------+
# | Version | Status  | ... | Type   |
# +---------+---------+-----+--------+
# | 0       | Success | ... | Baseline |
# +---------+---------+-----+--------+
```

### ステップ 5: 新規マイグレーションを追加

V1 以降は通常通り：

```bash
# 新規テーブルを追加する場合
cat > migrations/sql/V1__add_post.sql <<'SQL'
CREATE TABLE IF NOT EXISTS "post" (
    id UUID NOT NULL DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES "user"(id),
    body TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
);
SQL

# 適用
make up

# 検証
make info
make psql
# psql> SELECT * FROM "post";
```

---

## Baseline バージョンの決め方

| 環境 | Baseline Version | 理由 |
|-----|------------------|------|
| 新規プロジェクト | 1.0 | 標準 |
| 既存 DB（開発）| 1.0 | V1 = 初期化スクリプト相当 |
| 既存 DB（本番） | 本番バージョン | 本番と同じバージョンに合わせる |

**例**: 本番が V3.2.0 まで運用済みの場合
```bash
make baseline-init
# → Baseline Version: 3.2.0
```

その後、新規機能は V3.3.0 から開始：
```bash
# migrations/sql/V3.3.0__add_new_feature.sql
```

---

## よくあるケース

### ケース 1: 既存テーブルに新規カラムを追加

```bash
# V1__baseline.sql で既存テーブル定義を復元
# Baseline 1.0 で初期化
# V1.1__add_status_column.sql で新規カラム追加

cat > migrations/sql/V1.1__add_status_column.sql <<'SQL'
ALTER TABLE "user" ADD COLUMN status VARCHAR(20) DEFAULT 'active';
SQL

make up
make info
```

### ケース 2: 既存テーブルをスキップして手動で作成

既存テーブルを Flyway で管理したくない場合：

```bash
# V0__baseline.sql は作成しない
# 代わりに手動で DB を初期化

# その後 Baseline を初期化
make baseline-init
# → Baseline Version: 0.1（Flyway テーブルだけ記録）

# V1 から新規テーブルを Flyway で管理
```

### ケース 3: スキーマダンプに不要な定義が含まれている

```bash
# pg_dump で出力されるが Flyway では不要な内容を削除:
# - COMMENT ON EXTENSION
# - pg_stat_statements
# - 本番環境固有の設定

# 手動で migrations/sql/V0__baseline.sql を編集
vim migrations/sql/V0__baseline.sql

# 検証
make validate
```

---

## Baseline を使わないアプローチ

既存テーブルを Flyway に含めたくない場合：

```bash
# V0__baseline.sql を作成しない
# 代わりに Baseline を空で初期化

make baseline-init
# → Baseline Version: 1.0（テーブル定義なし）

# 既存テーブルは手動で保持
# V1 から新規マイグレーションを開始

cat > migrations/sql/V1__add_new_table.sql <<'SQL'
CREATE TABLE IF NOT EXISTS "post" (...);
SQL
```

**メリット**: シンプル、既存テーブルと新規テーブルを分離  
**デメリット**: 新環境構築時に既存テーブルを別途作成必要

---

## トラブルシューティング

### Q: Baseline 後に checksum エラーが出た

**A**: 既存 SQL を編集してしまった可能性。修復方法：

```bash
# 方法 1: 新規 migration で対応（推奨）
cat > migrations/sql/V0.1__fix_table_definition.sql <<'SQL'
ALTER TABLE ...
SQL
make up

# 方法 2: flyway repair（最後の手段）
make repair
```

### Q: V0__baseline.sql を実行したくない

**A**: Baseline を使用して、実行をスキップ：

```bash
# V0__baseline.sql は作成するが
# Baseline を初期化すると実行されない

make baseline-init
# → Baseline: 0.0（テーブルは既に存在）
# → V1 から新規マイグレーション開始
```

### Q: 本番 DB から既存スキーマをダンプしたい

**A**: 本番環境で dump-schema コマンド実行：

```bash
# 本番環境での実行例
make dump-schema > /tmp/prod_schema.sql

# ローカルで確認
cat /tmp/prod_schema.sql

# Git にコミット
git add migrations/sql/V0__baseline.sql
git commit -m "feat: baseline schema from production"
```

---

## ベストプラクティス

1. **Baseline を使用する**
   - 既存テーブル定義は V0__baseline.sql で保存
   - Baseline 初期化で実行をスキップ
   - V1 以降は通常の Flyway フロー

2. **定期的にスキーマを同期**
   ```bash
   # 本番と開発環境のスキーマを定期同期
   make dump-schema    # ローカルスキーマダンプ
   git diff migrations/sql/V0__baseline.sql    # 差分確認
   ```

3. **新規環境での検証**
   ```bash
   # 新規環境構築時
   make reset          # DB 初期化
   make up             # V0__baseline.sql から V_latest まで適用
   ```

4. **checksum エラー対策**
   - 既存 SQL は編集禁止
   - 変更が必要な場合は新規 migration ファイルで対応

---

## 参考リンク

- [Flyway - Getting Started](https://flywaydb.org/getstarted)
- [Flyway - Baseline](https://flywaydb.org/documentation/command/baseline)
- [PostgreSQL - pg_dump](https://www.postgresql.org/docs/current/app-pgdump.html)
