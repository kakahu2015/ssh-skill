#!/usr/bin/env bash
# OpenClaw SSH Skill - 远程服务管理
# 用法: bash service.sh <host|host1,host2,...> <action> [service_name] [--confirm]
# action: start|stop|restart|status|logs|enable|disable
set -euo pipefail

HOST_NAMES="${1:?用法: service.sh <host|host1,host2,...> <action> [service_name] [--confirm]}"
ACTION="${2:?缺少操作: start|stop|restart|status|logs|enable|disable}"
SERVICE_NAME="${3:-caddy}"
CONFIRM_FLAG="${4:-}"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/common.sh"

[[ "$SERVICE_NAME" =~ ^[A-Za-z0-9_.@-]+$ ]] || die_json "invalid_service" "服务名包含非法字符: $SERVICE_NAME"

case "$ACTION" in
  start)
    CMD="sudo systemctl start $SERVICE_NAME && systemctl status $SERVICE_NAME --no-pager | head -20"
    ;;
  stop)
    CMD="sudo systemctl stop $SERVICE_NAME"
    ;;
  restart)
    CMD="sudo systemctl restart $SERVICE_NAME && systemctl status $SERVICE_NAME --no-pager | head -20"
    ;;
  status)
    CMD="systemctl status $SERVICE_NAME --no-pager | head -20"
    ;;
  logs)
    CMD="journalctl -u $SERVICE_NAME --since '10 min ago' --no-pager | tail -50"
    ;;
  enable)
    CMD="sudo systemctl enable $SERVICE_NAME"
    ;;
  disable)
    CMD="sudo systemctl disable $SERVICE_NAME"
    ;;
  *)
    die_json "invalid_action" "操作必须是: start|stop|restart|status|logs|enable|disable"
    ;;
esac

HOST_COUNT=$(host_count_from_csv "$HOST_NAMES")
policy_check_command "$CMD" "$HOST_COUNT" "$CONFIRM_FLAG"
RUN_ID="${SSH_SKILL_RUN_ID:-$(make_run_id)}"

set +e
RESULT=$(SSH_SKILL_RUN_ID="$RUN_ID" bash "$SCRIPTS_DIR/exec.sh" "$HOST_NAMES" "$CMD" "$CONFIRM_FLAG")
RC=$?
set -e

SUCCESS=$([ "$RC" -eq 0 ] && echo true || echo false)
cat <<JSON
{
  "success": $SUCCESS,
  "run_id": "$(json_escape "$RUN_ID")",
  "host_target": "$(json_escape "$HOST_NAMES")",
  "action": "$(json_escape "$ACTION")",
  "service": "$(json_escape "$SERVICE_NAME")",
  "result": $RESULT
}
JSON
exit "$RC"
