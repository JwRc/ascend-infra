#!/usr/bin/env bash
#
# libredesk-db-init.sh — cria o banco/usuário do Libredesk num Postgres que
# JÁ está rodando com dados (volume pgdata não vazio, ex: produção).
#
# O script em ./postgres-init só roda automaticamente na primeira
# inicialização do Postgres (volume vazio) — em produção o volume já existe
# há tempo (era usado pelo Request Tracker), então esse passo precisa ser
# feito manualmente uma vez. Rodar depois de 'docker compose up -d postgres'
# e antes de subir o serviço 'libredesk' pela primeira vez. Idempotente —
# pode rodar de novo sem duplicar nada.
#
# Uso: ./libredesk-db-init.sh   (lê as credenciais de ./.env)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE=".env"
COMPOSE_FILE="docker-compose.yml"

[ -f "$ENV_FILE" ] || { echo "Não encontrei $ENV_FILE em $SCRIPT_DIR." >&2; exit 1; }

read_env() { grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d'=' -f2-; }

POSTGRES_USER="$(read_env POSTGRES_USER)"
POSTGRES_DB="$(read_env POSTGRES_DB)"
LIBREDESK_DB_NAME="$(read_env LIBREDESK_DB_NAME)"
LIBREDESK_DB_USER="$(read_env LIBREDESK_DB_USER)"
LIBREDESK_DB_PASSWORD="$(read_env LIBREDESK_DB_PASSWORD)"

: "${POSTGRES_USER:?POSTGRES_USER vazio em $ENV_FILE}"
: "${POSTGRES_DB:?POSTGRES_DB vazio em $ENV_FILE}"
: "${LIBREDESK_DB_NAME:?LIBREDESK_DB_NAME vazio em $ENV_FILE}"
: "${LIBREDESK_DB_USER:?LIBREDESK_DB_USER vazio em $ENV_FILE}"
: "${LIBREDESK_DB_PASSWORD:?LIBREDESK_DB_PASSWORD vazio em $ENV_FILE — gere uma senha antes de rodar}"

dc() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }

psql_query() {
  dc exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"
}

echo "Verificando usuário '$LIBREDESK_DB_USER'..."
if [ "$(psql_query "SELECT 1 FROM pg_roles WHERE rolname = '$LIBREDESK_DB_USER'")" = "1" ]; then
  echo "Usuário '$LIBREDESK_DB_USER' já existe, pulando."
else
  echo "Criando usuário '$LIBREDESK_DB_USER'..."
  psql_query "CREATE USER \"$LIBREDESK_DB_USER\" WITH PASSWORD '$LIBREDESK_DB_PASSWORD'" > /dev/null
fi

echo "Verificando banco '$LIBREDESK_DB_NAME'..."
if [ "$(psql_query "SELECT 1 FROM pg_database WHERE datname = '$LIBREDESK_DB_NAME'")" = "1" ]; then
  echo "Banco '$LIBREDESK_DB_NAME' já existe, pulando."
else
  echo "Criando banco '$LIBREDESK_DB_NAME'..."
  psql_query "CREATE DATABASE \"$LIBREDESK_DB_NAME\" OWNER \"$LIBREDESK_DB_USER\"" > /dev/null
  psql_query "GRANT ALL PRIVILEGES ON DATABASE \"$LIBREDESK_DB_NAME\" TO \"$LIBREDESK_DB_USER\"" > /dev/null
fi

echo ""
echo "Banco do Libredesk pronto. Agora rode:"
echo "  docker compose up -d libredesk"
echo "  (depois) ../backend/scripts/libredesk-setup.sh via túnel SSH — ver DEPLOY_LIBREDESK.md"
