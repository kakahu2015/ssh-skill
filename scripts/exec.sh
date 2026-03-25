#!/usr/bin/env bash
# OpenClaw SSH Skill - 通过 ControlMaster socket 执行远程命令
# 用法: bash exec.sh <host> "command"
set -euo pipefail

HOST_NAME="${1:?用法: exec.sh <host> <command>}"
REMOTE_CMD="${2:?缺少命令参数}"

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/yaml.sh"

HOSTS_YAML="$SKILL_DIR/hosts.yaml"
CTL_SOCKET="/tmp/ssh-ctl/${HOST_NAME}.sock"

die() { echo "{\"success\":false,\"host\":\"$HOST_NAME\",\"error\":\"$1\",\"message\":\"$2\"}"; exit 1; }

# ── 读取主机配置 ──
SSH_HOST=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "host")
SSH_PORT=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "port"); SSH_PORT="${SSH_PORT:-22}"
SSH_USER=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "user")
DEFAULT_WORKDIR=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "default_workdir")

# ── 检查 ControlMaster socket ──
if [[ ! -S "$CTL_SOCKET" ]]; then
    echo "[ssh-skill] socket 不存在，尝试自动重连..." >&2
    bash "$SCRIPTS_DIR/connect.sh" "$HOST_NAME" >&2 || \
        die "not_connected" "连接不存在且自动重连失败，请先运行 connect.sh $HOST_NAME"
fi

CHECK=$(ssh -o ControlPath="$CTL_SOCKET" -O check placeholder 2>&1 || true)
if ! echo "$CHECK" | grep -q "Master running"; then
    echo "[ssh-skill] socket 已失效，尝试重连..." >&2
    rm -f "$CTL_SOCKET"
    bash "$SCRIPTS_DIR/connect.sh" "$HOST_NAME" >&2 || \
        die "reconnect_failed" "重连失败，请检查网络或主机状态"
fi

# ── 构建最终命令 ──
if [[ -n "$DEFAULT_WORKDIR" ]]; then
    if [[ "$DEFAULT_WORKDIR" == "~"* ]]; then
        # ~ 开头的路径由远程 shell 展开，不转义
        FULL_CMD="cd $DEFAULT_WORKDIR && $REMOTE_CMD"
    else
        FULL_CMD="cd $(printf '%q' "$DEFAULT_WORKDIR") && $REMOTE_CMD"
    fi
else
    FULL_CMD="$REMOTE_CMD"
fi

# ── 执行 ──
STDOUT_FILE=$(mktemp)
STDERR_FILE=$(mktemp)
trap 'rm -f "$STDOUT_FILE" "$STDERR_FILE"' EXIT

ssh \
    -o "ControlMaster=no" \
    -o "ControlPath=$CTL_SOCKET" \
    -o "StrictHostKeyChecking=no" \
    -p "$SSH_PORT" \
    "${SSH_USER}@${SSH_HOST}" \
    "bash -lc $(printf '%q' "$FULL_CMD")" \
    >"$STDOUT_FILE" 2>"$STDERR_FILE"
EXIT_CODE=$?

STDOUT_CONTENT=$(cat "$STDOUT_FILE")
STDERR_CONTENT=$(cat "$STDERR_FILE")

# 脱敏处理
redact() {
    echo "$1" | sed -E 's/(password|passwd|secret|token|api[_-]?key)[[:space:]]*[=:][[:space:]]*[^[:space:]]*/\1=[REDACTED]/gi'
}
STDOUT_CONTENT=$(redact "$STDOUT_CONTENT")
STDERR_CONTENT=$(redact "$STDERR_CONTENT")

# ── 输出 JSON（纯 bash 转义）──
escape_json() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//'
}

echo "{"
echo "  \"success\": $([ $EXIT_CODE -eq 0 ] && echo true || echo false),"
echo "  \"host\": \"$HOST_NAME\","
echo "  \"exit_code\": $EXIT_CODE,"
printf '  "stdout": "'
escape_json "$STDOUT_CONTENT"
echo "\","
printf '  "stderr": "'
escape_json "$STDERR_CONTENT"
echo "\""
echo "}"
