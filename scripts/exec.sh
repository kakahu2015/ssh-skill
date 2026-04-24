#!/usr/bin/env bash
# OpenClaw SSH Skill - 通过 ControlMaster socket 执行远程命令
# 用法: bash exec.sh <host> "command"
set -euo pipefail

HOST_NAMES="${1:?用法: exec.sh <host|host1,host2,...> <command>}"
REMOTE_CMD="${2:?缺少命令参数}"

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/yaml.sh"

# 如果是多个主机（逗号分隔），循环执行
if echo "$HOST_NAMES" | grep -q ','; then
    IFS=',' read -ra HOSTS <<< "$HOST_NAMES"
    for HOST_NAME in "${HOSTS[@]}"; do
        echo "[ssh-skill] 在主机 $HOST_NAME 执行..." >&2
        bash "$0" "$HOST_NAME" "$REMOTE_CMD"
    done
    exit 0
fi

HOST_NAME="$HOST_NAMES"

HOSTS_YAML="$SKILL_DIR/hosts.yaml"
SECRETS_DIR="$SKILL_DIR/.secrets"
CTL_SOCKET="/tmp/ssh-ctl/${HOST_NAME}.sock"

die() { echo "{\"success\":false,\"host\":\"$HOST_NAME\",\"error\":\"$1\",\"message\":\"$2\"}"; exit 1; }

# ── 读取主机配置 ──
SSH_HOST=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "host")
SSH_PORT=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "port"); SSH_PORT="${SSH_PORT:-22}"
SSH_USER=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "user")
DEFAULT_WORKDIR=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "default_workdir")

# .secrets/<host>.env 覆盖（IP/密钥路径不走 YAML）
# 解析 alias：如果 hosts.yaml 里 host 字段指向另一个主机名，用那个名字找 secrets
REAL_HOST="$SSH_HOST"
SECRETS_ENV="$SECRETS_DIR/${REAL_HOST}.env"
if [[ ! -f "$SECRETS_ENV" ]]; then
    SECRETS_ENV="$SECRETS_DIR/${HOST_NAME}.env"
fi
if [[ -f "$SECRETS_ENV" ]]; then
    _H=$(grep -E '^HOST=' "$SECRETS_ENV" | cut -d= -f2-)
    [[ -n "$_H" ]] && SSH_HOST="$_H"
fi

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

run_ssh() {
    local cmd="$1"
    >"$STDOUT_FILE" >"$STDERR_FILE"
    ssh \
        -o "ControlMaster=no" \
        -o "ControlPath=$CTL_SOCKET" \
        -o "StrictHostKeyChecking=accept-new" \
        -p "$SSH_PORT" \
        "${SSH_USER}@${SSH_HOST}" \
        "bash -lc $(printf '%q' "$cmd")" \
        >"$STDOUT_FILE" 2>"$STDERR_FILE"
    return $?
}

set +e
run_ssh "$FULL_CMD"
EXIT_CODE=$?
set -e

STDOUT_CONTENT=$(cat "$STDOUT_FILE")
STDERR_CONTENT=$(cat "$STDERR_FILE")

# 权限自动适配：如果失败且是 Permission denied，尝试 sudo
if [[ $EXIT_CODE -ne 0 ]] && echo "$STDERR_CONTENT" | grep -q "Permission denied"; then
    echo "[ssh-skill] 检测到权限不足，尝试 sudo 重新执行..." >&2
    # 构造 sudo 命令：在原命令前加 sudo
    SUDO_CMD="sudo bash -lc $(printf '%q' "$FULL_CMD")"
    set +e
    run_ssh "$SUDO_CMD"
    EXIT_CODE=$?
set -e
    if [[ $EXIT_CODE -eq 0 ]]; then
        # sudo 成功，更新输出
        STDOUT_CONTENT=$(cat "$STDOUT_FILE")
        STDERR_CONTENT=$(cat "$STDERR_FILE")
        echo "[ssh-skill] sudo 执行成功" >&2
    else
        echo "[ssh-skill] sudo 重试后仍然失败" >&2
    fi
fi

# 脱敏处理
redact() {
    echo "$1" | sed -E \
        -e 's/(password|passwd|secret|token|api[_-]?key)[[:space:]]*[=:][[:space:]]*[^[:space:]]*/\1=[REDACTED]/gi' \
        -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[REDACTED_IP]/g'
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
