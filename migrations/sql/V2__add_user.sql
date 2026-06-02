-- V2__add_user.sql
-- user テーブル作成 (テーブル名は単数形 / CLAUDE.md 規約)
CREATE
		TABLE
				IF NOT EXISTS "user"(
						id UUID NOT NULL DEFAULT gen_random_uuid(),
						email VARCHAR(255) NOT NULL,
						name VARCHAR(100) NOT NULL,
						status VARCHAR(20) NOT NULL DEFAULT 'active',
						created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
						updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
						CONSTRAINT user_pkey PRIMARY KEY(id),
						CONSTRAINT user_email_unique UNIQUE(email),
						CONSTRAINT user_status_check CHECK(
								status IN(
										'active',
										'pending',
										'deleted'
								)
						)
				);

-- status を頻繁に絞り込む想定でインデックス
CREATE
		INDEX IF NOT EXISTS user_status_idx ON
		"user"(status);

COMMENT ON
TABLE
		"user" IS 'アプリ利用者';

COMMENT ON
COLUMN "user".status IS 'active / pending / deleted (CLAUDE.md: enum 相当の列挙)';
