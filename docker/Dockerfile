# Flyway one-shot migration runner
#
# - upstream: flyway/flyway:10-alpine (Java 17 + Flyway 10.x)
# - migrations/sql 配下の SQL を /flyway/sql に COPY
# - ENTRYPOINT は upstream の `flyway` バイナリ
# - CMD はタスク定義の `Command: ["migrate"]` で上書きする
FROM flyway/flyway:10-alpine

# SQL ディレクトリのみ COPY (テストは含めない)
COPY migrations/sql /flyway/sql

# デフォルトは migrate (タスク定義側で上書き可)
CMD ["migrate"]
