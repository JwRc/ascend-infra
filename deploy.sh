#!/usr/bin/env bash
#
# deploy.sh — orquestra deploy blue-green de backend e/ou frontend.
#
# Uso:
#   ./deploy.sh [--backend] [--frontend]
#
#   Sem flags:            faz deploy de backend E frontend.
#   --backend:             só backend.
#   --frontend:            só frontend.
#   --backend --frontend:  equivalente a nenhuma flag (os dois).
#
# Pré-condição: 'docker compose up -d' já deve ter sido rodado alguma vez
# (backend-a/b, frontend-web/b e nginx precisam estar no ar).
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Setup inicial — roda sempre a partir do próprio diretório,
# independente de onde o script foi chamado.
# ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env"
OBSERVABILITY_ENV_FILE="observability/.env"
NGINX_CONF="nginx/conf.d/default.conf"

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"    # segundos, tempo total de espera pelo health check
HEALTH_INTERVAL="${HEALTH_INTERVAL:-3}"   # segundos, intervalo entre tentativas
WGET_TIMEOUT="${WGET_TIMEOUT:-2}"         # segundos, timeout de cada request individual

# Status agregado do script inteiro: 0 = tudo certo, 1 = pelo menos um
# componente falhou. Um componente falhar NÃO interrompe o outro.
OVERALL_STATUS=0

# ─────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { printf '[%s] [INFO]  %s\n' "$(_ts)" "$*"; }
log_warn()  { printf '[%s] [WARN]  %s\n' "$(_ts)" "$*" >&2; }
log_error() { printf '[%s] [ERROR] %s\n' "$(_ts)" "$*" >&2; }

# ─────────────────────────────────────────────────────────────
# Helpers de docker compose
# ─────────────────────────────────────────────────────────────
dc() {
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

# Roda um comando docker compose com uma env var extra sobrescrita
# *apenas para essa chamada* (export num subshell — não vaza pro resto
# do script nem para o outro componente, que usa uma variável diferente).
dc_with_tag() {
  local var_name="$1" var_value="$2"
  shift 2
  ( export "${var_name}=${var_value}"; dc "$@" )
}

# ─────────────────────────────────────────────────────────────
# Helpers de leitura/escrita de arquivos .env
# ─────────────────────────────────────────────────────────────
read_env_var() {
  local key="$1" file="$2"
  grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d'=' -f2-
}

write_env_var() {
  local key="$1" value="$2" file="$3"
  if grep -qE "^${key}=" "$file"; then
    sed -i -E "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

# ─────────────────────────────────────────────────────────────
# Slack
# ─────────────────────────────────────────────────────────────
notify_slack() {
  local level="$1" message="$2"
  local webhook
  webhook="$(read_env_var 'SLACK_WEBHOOK_URL' "$OBSERVABILITY_ENV_FILE")"

  if [[ -z "$webhook" ]]; then
    log_warn "SLACK_WEBHOOK_URL não configurado em ${OBSERVABILITY_ENV_FILE} — pulando alerta."
    return 0
  fi

  local emoji
  case "$level" in
    success) emoji=":white_check_mark:" ;;
    error)   emoji=":rotating_light:" ;;
    warning) emoji=":warning:" ;;
    *)       emoji=":information_source:" ;;
  esac

  local payload http_code
  payload="$(jq -n --arg text "${emoji} *deploy.sh* [$(hostname)] — ${message}" '{text: $text}')"

  http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    --data "$payload" "$webhook" || echo "000")"

  if [[ "$http_code" != "200" ]]; then
    log_warn "Falha ao enviar alerta pro Slack (HTTP ${http_code})."
  fi
}

# ─────────────────────────────────────────────────────────────
# Toggle idempotente do upstream do nginx (edita o arquivo no HOST,
# que está montado como bind mount :ro dentro do container).
# ─────────────────────────────────────────────────────────────
nginx_toggle() {
  local action="$1" service="$2" port="$3"
  local pattern="server ${service}:${port};"

  case "$action" in
    disable)
      # Comenta a linha só se ela ainda NÃO estiver comentada.
      sed -i -E "s/^([[:space:]]*)(${pattern})\$/\1#\2/" "$NGINX_CONF"
      ;;
    enable)
      # Descomenta a linha só se ela estiver comentada.
      sed -i -E "s/^([[:space:]]*)#(${pattern})\$/\1\2/" "$NGINX_CONF"
      ;;
    *)
      log_error "nginx_toggle: ação inválida '${action}'"
      return 1
      ;;
  esac
}

nginx_reload() {
  if ! dc exec -T nginx nginx -t >/dev/null 2>&1; then
    log_error "nginx -t falhou depois da edição do upstream — configuração inválida, NÃO recarregando."
    return 1
  fi
  dc exec -T nginx nginx -s reload
}

nginx_remove_instance() {
  local service="$1" port="$2"
  log_info "Removendo ${service} do upstream do nginx..."
  nginx_toggle disable "$service" "$port"
  nginx_reload
}

nginx_restore_instance() {
  local service="$1" port="$2"
  log_info "Restaurando ${service} no upstream do nginx..."
  nginx_toggle enable "$service" "$port"
  nginx_reload
}

# ─────────────────────────────────────────────────────────────
# Health check via wget dentro do próprio container (node:22-alpine e
# nginx:alpine têm wget do BusyBox; curl não é garantido no backend).
# BusyBox wget sai com código != 0 em respostas não-2xx, então basta
# checar o exit code do 'docker compose exec'.
# ─────────────────────────────────────────────────────────────
wait_for_health() {
  local service="$1" port="$2" path="$3"
  local start=$SECONDS

  log_info "Aguardando health check de ${service} (GET ${path}, timeout ${HEALTH_TIMEOUT}s)..."
  while (( SECONDS - start < HEALTH_TIMEOUT )); do
    if dc exec -T "$service" wget -qO- --timeout="$WGET_TIMEOUT" \
        "http://127.0.0.1:${port}${path}" >/dev/null 2>&1; then
      log_info "${service} respondeu OK em ${path}."
      return 0
    fi
    sleep "$HEALTH_INTERVAL"
  done

  log_error "${service} não ficou saudável dentro de ${HEALTH_TIMEOUT}s."
  return 1
}

# ─────────────────────────────────────────────────────────────
# Deploy blue-green de um componente (backend ou frontend).
#
# Args:
#   $1 name         nome amigável ("backend" | "frontend"), só para logs/Slack
#   $2 service_a
#   $3 service_b
#   $4 port
#   $5 health_path
#   $6 tag_var      nome da variável de tag no .env
#                    (BACKEND_IMAGE_TAG | FRONTEND_IMAGE_TAG)
# ─────────────────────────────────────────────────────────────
deploy_component() {
  local name="$1" service_a="$2" service_b="$3" port="$4" health_path="$5" tag_var="$6"

  log_info "=== Iniciando deploy blue-green: ${name} ==="

  local container_a
  container_a="$(dc ps -q "$service_a")"
  if [[ -z "$container_a" ]]; then
    log_error "${service_a} não está rodando — rode 'docker compose up -d' antes de fazer deploy."
    OVERALL_STATUS=1
    return 1
  fi

  # 1. ID real da imagem atualmente em uso pela instância A (não a tag —
  #    a tag pode já ter sido movida por outro deploy).
  local old_image_id old_tag new_tag
  old_image_id="$(docker inspect --format='{{.Image}}' "$container_a")"
  old_tag="$(read_env_var "$tag_var" "$ENV_FILE")"
  new_tag="$(date +%Y%m%d%H%M%S)"

  log_info "${name}: imagem_atual=${old_image_id} tag_atual=${old_tag} tag_nova=${new_tag}"

  # 2. Remove a instância A do nginx.
  nginx_remove_instance "$service_a" "$port"

  # 3. Builda a imagem nova. Falha de build => restaura A (nunca foi
  #    tocada além do nginx) e aborta SÓ este componente.
  log_info "${name}: buildando imagem nova (${tag_var}=${new_tag})..."
  if ! dc_with_tag "$tag_var" "$new_tag" build "$service_a"; then
    log_error "${name}: build falhou. Restaurando ${service_a} no nginx."
    nginx_restore_instance "$service_a" "$port"
    notify_slack error "*${name}*: build da imagem nova falhou. Deploy abortado, nenhuma instância foi trocada."
    OVERALL_STATUS=1
    return 1
  fi

  # 4. Sobe a instância A com a imagem nova.
  log_info "${name}: subindo ${service_a} com a imagem nova..."
  if ! dc_with_tag "$tag_var" "$new_tag" up -d --no-deps --force-recreate "$service_a"; then
    log_warn "${name}: 'docker compose up' de ${service_a} retornou erro — será tratado como falha de health check."
  fi

  # 5. Espera o health check de A.
  if ! wait_for_health "$service_a" "$port" "$health_path"; then
    log_error "${name}: ${service_a} falhou no health check. Rollback para a imagem antiga."
    dc_with_tag "$tag_var" "$old_tag" up -d --no-deps --force-recreate "$service_a" \
      || log_warn "${name}: 'docker compose up' de rollback para ${service_a} retornou erro."
    nginx_restore_instance "$service_a" "$port"
    notify_slack error "*${name}*: ${service_a} falhou no health check com a imagem nova (tag ${new_tag}). Rollback para tag ${old_tag} concluído, tráfego não foi afetado."
    OVERALL_STATUS=1
    return 1
  fi

  # 6. Adiciona A de volta e SÓ DEPOIS remove B — nunca fica com zero
  #    instâncias servindo tráfego.
  nginx_restore_instance "$service_a" "$port"
  nginx_remove_instance "$service_b" "$port"

  # 7. Sobe a instância B com a MESMA imagem nova (sem rebuildar).
  log_info "${name}: subindo ${service_b} com a imagem nova..."
  if ! dc_with_tag "$tag_var" "$new_tag" up -d --no-deps --force-recreate "$service_b"; then
    log_warn "${name}: 'docker compose up' de ${service_b} retornou erro — será tratado como falha de health check."
  fi

  # 7.5 Espera o health check de B — mesmo tratamento de rollback, mas
  #     simétrico: A já está na imagem nova e servindo, não é tocada.
  if ! wait_for_health "$service_b" "$port" "$health_path"; then
    log_error "${name}: ${service_b} falhou no health check. Rollback de B para a imagem antiga (A permanece na nova)."
    dc_with_tag "$tag_var" "$old_tag" up -d --no-deps --force-recreate "$service_b" \
      || log_warn "${name}: 'docker compose up' de rollback para ${service_b} retornou erro."
    nginx_restore_instance "$service_b" "$port"
    notify_slack error "*${name}*: ${service_b} falhou no health check com a imagem nova (tag ${new_tag}). Rollback de ${service_b} para tag ${old_tag} concluído. ${service_a} já está rodando a imagem nova e servindo tráfego normalmente."
    OVERALL_STATUS=1
    return 1
  fi

  # 8. Adiciona B de volta.
  nginx_restore_instance "$service_b" "$port"

  # 9. Limpeza: remove a imagem antiga (se ainda existir e for
  #    diferente da nova) e persiste a tag nova no .env.
  local new_image_id
  new_image_id="$(docker inspect --format='{{.Image}}' "$(dc ps -q "$service_a")")"

  if [[ -n "$old_image_id" && "$old_image_id" != "$new_image_id" ]] \
      && docker image inspect "$old_image_id" >/dev/null 2>&1; then
    if docker rmi "$old_image_id" >/dev/null 2>&1; then
      log_info "${name}: imagem antiga (${old_image_id}) removida."
    else
      log_warn "${name}: não foi possível remover a imagem antiga (${old_image_id}) — pode estar em uso por outra tag/container."
    fi
  fi

  write_env_var "$tag_var" "$new_tag" "$ENV_FILE"
  log_info "${name}: ${tag_var}=${new_tag} persistido em ${ENV_FILE}."

  notify_slack success "*${name}*: deploy concluído com sucesso. Nova tag: ${new_tag} (imagem antiga: ${old_image_id})."
  log_info "=== Deploy blue-green de ${name} concluído com sucesso ==="
  return 0
}

# ─────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Uso: $0 [--backend] [--frontend]

  --backend    Faz deploy blue-green apenas do backend.
  --frontend   Faz deploy blue-green apenas do frontend.
  (nenhuma)    Faz deploy blue-green de backend E frontend.
EOF
}

main() {
  local do_backend=0 do_frontend=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend) do_backend=1 ;;
      --frontend) do_frontend=1 ;;
      -h|--help) usage; exit 0 ;;
      *)
        log_error "Argumento desconhecido: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done

  # Sem flags => faz os dois.
  if [[ "$do_backend" -eq 0 && "$do_frontend" -eq 0 ]]; then
    do_backend=1
    do_frontend=1
  fi

  if [[ "$do_backend" -eq 1 ]]; then
    if ! deploy_component "backend" "backend-a" "backend-b" "3000" "/ready" "BACKEND_IMAGE_TAG"; then
      log_error "Deploy do backend terminou com falha (veja logs/Slack acima)."
    fi
  fi

  if [[ "$do_frontend" -eq 1 ]]; then
    if ! deploy_component "frontend" "frontend-web" "frontend-web-b" "80" "/" "FRONTEND_IMAGE_TAG"; then
      log_error "Deploy do frontend terminou com falha (veja logs/Slack acima)."
    fi
  fi

  if [[ "$OVERALL_STATUS" -eq 0 ]]; then
    log_info "Deploy finalizado com sucesso."
  else
    log_error "Deploy finalizado com pelo menos uma falha."
  fi

  exit "$OVERALL_STATUS"
}

main "$@"
