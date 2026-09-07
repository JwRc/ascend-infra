#!/bin/bash
# Roda automaticamente no primeiro boot do container postgres (volume vazio),
# via /docker-entrypoint-initdb.d — provisiona o banco/usuário do Libredesk
# no mesmo Postgres compartilhado da aplicação.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  CREATE USER "$LIBREDESK_DB_USER" WITH PASSWORD '$LIBREDESK_DB_PASSWORD';
  CREATE DATABASE "$LIBREDESK_DB_NAME" OWNER "$LIBREDESK_DB_USER";
  GRANT ALL PRIVILEGES ON DATABASE "$LIBREDESK_DB_NAME" TO "$LIBREDESK_DB_USER";
EOSQL
