#!/usr/bin/env bash
# Provisiona no Request Tracker de produção tudo que o módulo support/ do
# backend precisa para funcionar: fila, custom field de tenant, usuário de
# serviço e as permissões dele. Idempotente — pode ser rodado várias vezes
# sem duplicar nada (ex: depois de um redeploy do zero).
#
# Rodar a partir do próprio host de produção (ou via túnel SSH), depois que
# 'docker compose up -d' já subiu o serviço request-tracker — o RT só fica
# acessível em 127.0.0.1:${REQUEST_TRACKER_PORT}, não é exposto publicamente.
#
# Uso (lendo as mesmas credenciais já geradas em infra/.env):
#   set -a && source .env && set +a
#   RT_BASE_URL="http://localhost:${REQUEST_TRACKER_PORT:-8080}" \
#   RT_ROOT_USER=root RT_ROOT_PASSWORD="$RT_ROOT_PASSWORD" \
#   RT_QUEUE="$RT_QUEUE" RT_TENANT_CUSTOM_FIELD="$RT_TENANT_CUSTOM_FIELD" \
#   RT_API_USER="$RT_API_USER" RT_API_PASSWORD="$RT_API_PASSWORD" \
#   ./rt-setup.sh

set -euo pipefail

command -v curl >/dev/null || { echo "Este script precisa de curl instalado." >&2; exit 1; }
command -v jq >/dev/null || { echo "Este script precisa de jq instalado." >&2; exit 1; }

: "${RT_BASE_URL:=http://localhost:8080}"
: "${RT_ROOT_USER:=root}"
: "${RT_ROOT_PASSWORD:?defina RT_ROOT_PASSWORD (mesma senha configurada em RT_ROOT_PASSWORD no .env)}"
: "${RT_QUEUE:=Support}"
: "${RT_TENANT_CUSTOM_FIELD:=Tenant}"
: "${RT_API_USER:=ascentio-backend}"
: "${RT_API_PASSWORD:?defina RT_API_PASSWORD com a senha do usuário de serviço do backend}"

ROOT_AUTH="$RT_ROOT_USER:$RT_ROOT_PASSWORD"
QUEUE_RIGHTS="ShowTicket CreateTicket ReplyToTicket ModifyTicket SeeQueue Watch"
CF_RIGHTS="SeeCustomField ModifyCustomField"

echo "Aguardando RT ficar acessível em $RT_BASE_URL..."
for i in $(seq 1 30); do
  if curl -sf -o /dev/null "$RT_BASE_URL/"; then break; fi
  [ "$i" -eq 30 ] && { echo "RT não respondeu a tempo." >&2; exit 1; }
  sleep 2
done

# rt <method> <path> [body] — imprime "<status>\n<body>". Aborta o script
# (exit 1) em erro de autenticação ou 5xx; 404/409 "esperados" ficam a
# cargo de cada chamador tratar a partir do status retornado.
rt() {
  local method=$1 path=$2 body=${3:-} resp status resp_body
  resp=$(curl -sS -u "$ROOT_AUTH" -w '\n%{http_code}' -X "$method" "$RT_BASE_URL$path" \
    -H "Content-Type: application/json" ${body:+-d "$body"})
  status=${resp##*$'\n'}
  resp_body=${resp%$'\n'*}
  case "$status" in
    401|403) echo "Autenticação falhou em $method $path (HTTP $status) — confira RT_ROOT_USER/RT_ROOT_PASSWORD." >&2; exit 1 ;;
    5*) echo "Erro do RT em $method $path (HTTP $status): $resp_body" >&2; exit 1 ;;
  esac
  printf '%s\n%s' "$status" "$resp_body"
}

rt_status() { head -n1 <<< "$1"; }
rt_body() { tail -n +2 <<< "$1"; }

# ── Verifica credenciais de root antes de seguir ────────────────────
rt GET /REST/2.0/queue/1 > /dev/null

# ── Fila ──────────────────────────────────────────────────────────
resp=$(rt GET "/REST/2.0/queue/$RT_QUEUE?fields=Name,TicketCustomFields")
if [ "$(rt_status "$resp")" = "404" ]; then
  echo "Criando fila '$RT_QUEUE'..."
  resp=$(rt POST /REST/2.0/queue \
    "$(jq -n --arg n "$RT_QUEUE" '{Name: $n, Description: "Tickets de suporte do app ASCENTIO"}')")
  queue_id=$(rt_body "$resp" | jq -r '.id')
  cf_applied_id=""
else
  queue_id=$(rt_body "$resp" | jq -r '.id')
  cf_applied_id=$(rt_body "$resp" | jq -r --arg n "$RT_TENANT_CUSTOM_FIELD" '.TicketCustomFields[]? | select(.name == $n) | .id')
  echo "Fila '$RT_QUEUE' já existe (id=$queue_id)."
fi

# ── Custom Field de tenant ──────────────────────────────────────────
if [ -n "$cf_applied_id" ]; then
  cf_id=$cf_applied_id
  echo "Custom field '$RT_TENANT_CUSTOM_FIELD' já existe e já está aplicado na fila (id=$cf_id)."
else
  echo "Criando custom field '$RT_TENANT_CUSTOM_FIELD'..."
  resp=$(rt POST /REST/2.0/customfield \
    "$(jq -n --arg n "$RT_TENANT_CUSTOM_FIELD" '{Name: $n, Type: "FreeformSingle", LookupType: "RT::Queue-RT::Ticket", MaxValues: 1}')")
  cf_id=$(rt_body "$resp" | jq -r '.id')
  echo "Aplicando custom field '$RT_TENANT_CUSTOM_FIELD' na fila '$RT_QUEUE'..."
  rt POST "/REST/2.0/customfield/$cf_id/appliesto" "$(jq -n --arg id "$queue_id" '{ObjectId: $id}')" > /dev/null
fi

# ── Usuário de serviço do backend ───────────────────────────────────
resp=$(rt GET "/REST/2.0/user/$RT_API_USER")
if [ "$(rt_status "$resp")" = "404" ]; then
  echo "Criando usuário de serviço '$RT_API_USER'..."
  rt POST /REST/2.0/user "$(jq -n --arg n "$RT_API_USER" --arg p "$RT_API_PASSWORD" \
    '{Name: $n, EmailAddress: ($n + "@ascentio.local"), RealName: "ASCENTIO Backend", Password: $p}')" > /dev/null
else
  echo "Usuário de serviço '$RT_API_USER' já existe."
fi

# ── Permissões — RT recusa (409) concessão duplicada sem duplicar nada,
# então basta tentar conceder todas a cada execução. ─────────────────
for right in $QUEUE_RIGHTS; do
  rt POST "/REST/2.0/queue/$queue_id/rights" \
    "$(jq -n --arg u "$RT_API_USER" --arg r "$right" '{User: $u, Right: $r}')" > /dev/null
done
for right in $CF_RIGHTS; do
  rt POST "/REST/2.0/customfield/$cf_id/rights" \
    "$(jq -n --arg u "$RT_API_USER" --arg r "$right" '{User: $u, Right: $r}')" > /dev/null
done
echo "Permissões de '$RT_API_USER' confirmadas na fila '$RT_QUEUE' e no custom field '$RT_TENANT_CUSTOM_FIELD'."

echo ""
echo "RT provisionado. Confirme que estes valores batem com o infra/.env:"
echo "  RT_QUEUE=$RT_QUEUE"
echo "  RT_TENANT_CUSTOM_FIELD=$RT_TENANT_CUSTOM_FIELD"
echo "  RT_API_USER=$RT_API_USER"
echo "  RT_API_PASSWORD=<a senha que você passou>"
