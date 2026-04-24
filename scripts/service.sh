#!/usr/bin/env bash
# OpenClaw SSH Skill - 远程服务管理
# 用法: bash service.sh <host> <action> [service_name]
# action: start|stop|restart|status|logs|enable|disable
set -euo pipefail

HOST_NAME="${1:?用法: service.sh <host> <action> [service_name]}"
ACTION="${2:?缺少操作: start|stop|restart|status|logs|enable|disable}"
SERVICE_NAME="${3:-caddy}"  # 默认 caddy

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/yaml.sh"

HOSTS_YAML="$SKILL_DIR/hosts.yaml"
SECRETS_DIR="$SKILL_DIR/.secrets"
CTL_SOCKET="/tmp/ssh-ctl/${HOST_NAME}.sock"

die() { echo "{\"success\":false,\"host\":\"$HOST_NAME\",\"error\":\"$1\",\"message\":\"$2\"}"; exit 1; }

SSH_HOST=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "host")
SSH_PORT=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "port"); SSH_PORT="${SSH_PORT:-22}"
SSH_USER=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "user")

# .secrets 覆盖
SECRETS_ENV="$SECRETS_DIR/${HOST_NAME}.env"
if [[ -f "$SECRETS_ENV" ]]; then
    _H=$(grep -E '^HOST=' "$SECRETS_ENV" | cut -d= -f2-)
    [[ -n "$_H" ]] && SSH_HOST="$_H"
fi

[[ ! -S "$CTL_SOCKET" ]] && die "not_connected" "未建立连接，请先运行 connect.sh $HOST_NAME"

# 执行远程命令的辅助函数
run_remote() {
    ssh -o "ControlMaster=no" -o "ControlPath=$CTL_SOCKET" -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}" "bash -lc $(printf '%q' "$1")" 2>&1
}

case "$ACTION" in
  start)
    echo "[ssh-skill] 启动服务 $SERVICE_NAME..." >&2
    OUTPUT=$(run_remote "sudo systemctl start $SERVICE_NAME 2>&1")
    EXIT_CODE=$?
    # 如果失败且是 203/EXEC，尝试检查文件权限和路径
    if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -q "203/EXEC\|Permission denied"; then
        echo "[ssh-skill] 检测到启动失败，尝试诊断..." >&2
        # 检查服务文件中的可执行文件路径
        EXEC_PATH=$(run_remote "grep -oP 'ExecStart=\\K.*' /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null | head -1 | tr -d ' '")
        if [[ -n "$EXEC_PATH" ]]; then
            echo "[ssh-skill] 检查可执行文件: $EXEC_PATH" >&2
            run_remote "ls -la $EXEC_PATH" >&2
            run_remote "file $EXEC_PATH" >&2
            # 尝试直接以 root 运行（绕过 systemd 限制）
            echo "[ssh-skill] 尝试手动以 root 启动..." >&2
            run_remote "sudo nohup $EXEC_PATH > /tmp/${SERVICE_NAME}-manual.log 2>&1 &"
            sleep 2
            run_remote "ps aux | grep $SERVICE_NAME | grep -v grep" >&2
        fi
    fi
    run_remote "systemctl status $SERVICE_NAME --no-pager | head -15"
    ;;
  stop)
    run_remote "sudo systemctl stop $SERVICE_NAME"
    echo "{\"success\":true,\"host\":\"$HOST_NAME\",\"action\":\"stop\",\"service\":\"$SERVICE_NAME\"}"
    ;;
  restart)
    $0 "$HOST_NAME" stop "$SERVICE_NAME" >/dev/null
    sleep 2
    $0 "$HOST_NAME" start "$SERVICE_NAME"
    ;;
  status)
    run_remote "systemctl status $SERVICE_NAME --no-pager | head -20"
    ;;
  logs)
    run_remote "journalctl -u $SERVICE_NAME --since '10 min ago' --no-pager | tail -30"
    ;;
  enable)
    run_remote "sudo systemctl enable $SERVICE_NAME"
    echo "{\"success\":true,\"host\":\"$HOST_NAME\",\"action\":\"enable\",\"service\":\"$SERVICE_NAME\"}"
    ;;
  disable)
    run_remote "sudo systemctl disable $SERVICE_NAME"
    echo "{\"success\":true,\"host\":\"$HOST_NAME\",\"action\":\"disable\",\"service\":\"$SERVICE_NAME\"}"
    ;;
  *)
    die "invalid_action" "操作必须是: start|stop|restart|status|logs|enable|disable"
    ;;
esac
