#!/bin/bash
# Roda automaticamente no primeiro boot do container postgres (volume vazio),
# via /docker-entrypoint-initdb.d — provisiona o banco/usuário do Request
# Tracker no mesmo Postgres compartilhado da aplicação.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  CREATE USER "$RT_DB_USER" WITH PASSWORD '$RT_DB_PASSWORD';
  CREATE DATABASE "$RT_DB_NAME" OWNER "$RT_DB_USER";
  GRANT ALL PRIVILEGES ON DATABASE "$RT_DB_NAME" TO "$RT_DB_USER";
EOSQL
