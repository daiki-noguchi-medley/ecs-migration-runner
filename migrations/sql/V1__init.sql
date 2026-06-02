-- V1__init.sql
-- 初期セットアップ: PostgreSQL 拡張機能の有効化
-- 既存テーブルがあっても安全に流せる SQL のみを置く

-- UUID 自動生成用 (gen_random_uuid() を組込みで使うので不要だが、互換性のため)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- pgcrypto: digest() / crypt() 等が必要なら有効化
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Flyway 内部の flyway_schema_history テーブルはここで作らない
-- (Flyway 自身が自動で作成する)
